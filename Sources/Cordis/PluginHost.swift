import CCordis
import CCordisHost
import CryptoKit
import Foundation
import MachO

/// The cordis runtime: service registry, event bus, timers, dependency resolution, and the
/// loader for Embedded Swift plugin dylibs. Main thread only.
@MainActor
public final class PluginHost {
  // MARK: Registrations

  enum ListenerTarget {
    case host((Value) -> Void)
    case plugin(cordis_event_fn, UnsafeMutableRawPointer?)
    /// A callback in an out-of-process plugin, by its helper-side token.
    case remote(RemotePlugin, Int64)
  }

  enum ServiceTarget {
    case host((String, Value) -> Value)
    case plugin(cordis_service_fn, UnsafeMutableRawPointer?)
    case remote(RemotePlugin, Int64)
  }

  struct Listener {
    let handle: CordisHandle
    let owner: PluginRecord?
    let target: ListenerTarget
  }

  struct Service {
    let handle: CordisHandle
    let owner: PluginRecord?
    let target: ServiceTarget
  }

  enum Registration {
    case listener(event: String)
    case service(name: String)
    case timer(DispatchSourceTimer, ListenerTarget)
  }

  private var nextHandle: CordisHandle = 1
  private var registrations: [CordisHandle: (owner: PluginRecord?, kind: Registration)] = [:]
  private var listeners: [String: [Listener]] = [:]
  private var services: [String: Service] = [:]

  // MARK: Plugins

  private var records: [String: PluginRecord] = [:]
  private var order: [String] = []
  private var reconciling = false
  private var dirty = false

  // Reusable argument buffer for host -> plugin calls.
  private var scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
  private var scratchCapacity = 256
  private var callDepth = 0

  // Crash recovery: calls into plugin code on the stack, and plugins that faulted and still have
  // to be torn down (done as soon as no plugin code is on the stack).
  private var pluginFrames = 0
  private var pendingCrashes: [PluginRecord] = []

  // MARK: Configuration

  /// Receives lifecycle events and plugin log lines. When nil, logs go to stderr.
  public var onEvent: ((HostEvent) -> Void)?

  /// The plugin that crashed the previous run, if any. Its build stays disabled until a new build
  /// (different hash) of the same plugin id is loaded, which also clears this record.
  public private(set) var lastCrash: CrashRecord?

  public let crashMarkerPath: String?
  public let cacheDirectory: String

  /// Called after the host recovered from a plugin fault (also reported as `HostEvent.crashed`).
  public var onCrash: ((CrashReport) -> Void)?

  /// The plugin on whose behalf the host is running right now: set while a host service handles a
  /// plugin's call and while a host listener handles a plugin's event; nil for host-initiated work.
  /// Host services use it to enforce per-plugin permissions without trusting an argument.
  public private(set) var caller: String?

  /// Recover from faults in plugin code (process-wide; see `cordis_guard_*` in CCordisHost):
  /// a plugin that traps or segfaults is fenced off and unloaded and the call returns an error,
  /// instead of the whole process crashing. On by default.
  public static var crashRecovery: Bool {
    get { cordis_guard_enabled() }
    set { cordis_guard_set_enabled(newValue) }
  }
  private var watchers: [String: FileWatcher] = [:]
  /// How each path was loaded last (reloads and watches keep it).
  private var isolationByPath: [String: PluginIsolation] = [:]

  /// The executable that hosts out-of-process plugins (`PluginIsolation.process`). Defaults to
  /// `cordis-plugin-helper` next to the main executable, else in `Contents/Helpers` of the app.
  public var helperExecutable: String = PluginHost.defaultHelperExecutable

  public static var defaultHelperExecutable: String {
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let dir = exe.deletingLastPathComponent()
    let sibling = dir.appendingPathComponent("cordis-plugin-helper").path
    if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
    return dir.deletingLastPathComponent().appendingPathComponent("Helpers/cordis-plugin-helper").path
  }

  /// Seconds an out-of-process plugin may take to answer (a call, an event, a timer tick) before
  /// its helper is killed as hung and the plugin is reported as crashed.
  public var helperTimeout: Double = 5

  public static var defaultCacheDirectory: String {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return caches.appendingPathComponent("cordis-swift/\(ProcessInfo.processInfo.processName)/images").path
  }

  /// Deletes cached dylib copies that are not currently loaded.
  public func pruneCache() {
    let live = Set(records.values.compactMap { $0.isLoaded ? $0.cachePath : nil })
    let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory)) ?? []
    for f in files where f.hasSuffix(".dylib") {
      let p = (cacheDirectory as NSString).appendingPathComponent(f)
      if !live.contains(p) { try? FileManager.default.removeItem(atPath: p) }
    }
  }

  public static var defaultCrashMarkerPath: String {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let name = ProcessInfo.processInfo.processName
    return caches.appendingPathComponent("cordis-swift/\(name).crash").path
  }

  /// - Parameters:
  ///   - crashMarkerPath: where crash attribution is persisted; nil disables the signal handlers.
  ///   - cacheDirectory: where content-addressed copies of loaded dylibs live
  ///     (default: `~/Library/Caches/cordis-swift/<process>/images`). Reusing it across launches
  ///     matters: macOS checks every new dylib file on its first dlopen, which is slow.
  ///   - recoverCrashes: install the fault handlers even without a crash marker, so faults in
  ///     plugin code are recovered (`crashRecovery`). With a marker they are always installed.
  public init(crashMarkerPath: String? = PluginHost.defaultCrashMarkerPath, cacheDirectory: String? = nil, recoverCrashes: Bool = true) {
    self.crashMarkerPath = crashMarkerPath
    let cache = cacheDirectory ?? Self.defaultCacheDirectory
    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    self.cacheDirectory = (cache as NSString).resolvingSymlinksInPath
    if let marker = crashMarkerPath {
      try? FileManager.default.createDirectory(
        atPath: (marker as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      lastCrash = Self.readCrashMarker(marker)
      cordis_crash_install(marker)
    } else if recoverCrashes {
      cordis_crash_install(nil)
    }
  }

  isolated deinit {
    for w in watchers.values { w.cancel() }
    watchers.removeAll()
    unloadAll()
    scratch.deallocate()
  }

  // MARK: - Public host API

  /// Provides a service implemented by the host app. Plugins injecting `name` become applicable.
  /// Returns 0 if the service name is already taken.
  @discardableResult
  public func provide(_ name: String, _ handler: @escaping (_ method: String, _ args: Value) -> Value) -> CordisHandle {
    addService(owner: nil, name: name, target: .host(handler))
  }

  /// Calls a service provided by the host or a plugin. Errors come back as `{"error": "..."}`.
  @discardableResult
  public func call(_ service: String, _ method: String, _ args: Value = .null) -> Value {
    guard let s = services[service] else { return Self.error("service '\(service)' is not available") }
    switch s.target {
    case let .host(fn):
      return enter(nil) { fn(method, args) }
    case let .plugin(fn, ud):
      // Hot path: method + args are written into one reusable buffer (a fresh one when re-entered),
      // the plugin's malloc'd result is decoded in place and freed. No closures, one copy each way.
      let methodLen = method.utf8.count
      let argsLen = Codec.encodedSize(args)
      let total = methodLen + argsLen
      let reuse = callDepth == 0
      let buf: UnsafeMutablePointer<UInt8>
      if reuse {
        if scratchCapacity < total {
          scratch.deallocate()
          scratchCapacity = max(total, scratchCapacity * 2)
          scratch = .allocate(capacity: scratchCapacity)
        }
        buf = scratch
      } else {
        buf = .allocate(capacity: max(total, 1))
      }
      var i = 0
      for b in method.utf8 {
        buf[i] = b
        i += 1
      }
      Codec.encode(args, into: buf + methodLen)
      guard let owner = s.owner else { return Self.error("service '\(service)' has no owner") }
      if owner.crash != nil { return Self.crashedError(owner) }
      callDepth += 1
      var result = cordis_bytes(data: nil, len: 0)
      let ok = guarded(owner) { tag, image in
        cordis_guard_service(fn, ud, cordis_bytes(data: buf, len: methodLen), cordis_bytes(data: buf + methodLen, len: argsLen), tag, image, &result)
      }
      callDepth -= 1
      if !reuse { buf.deallocate() }
      return ok ? CBytes.take(result) : Self.crashedError(owner)
    case let .remote(rp, token):
      guard let owner = s.owner else { return Self.error("service '\(service)' has no owner") }
      if owner.crash != nil { return Self.crashedError(owner) }
      var out: Value?
      guarded(owner) { _, _ in
        out = rp.request(.service, [.int(token), .string(method), .bytes(Codec.encode(args))])
        return out == nil ? rp.failure : 0
      }
      guard let out else { return Self.crashedError(owner) }
      return Codec.decode(out.bytesOrEmpty) ?? .null
    }
  }

  /// Listens to an event emitted by the host or any plugin.
  @discardableResult
  public func on(_ event: String, _ handler: @escaping (Value) -> Void) -> CordisHandle {
    addListener(owner: nil, event: event, target: .host(handler))
  }

  /// True when the host or any plugin listens to `event`.
  public func hasListeners(_ event: String) -> Bool {
    listeners[event]?.contains { registrations[$0.handle] != nil } ?? false
  }

  public func emit(_ event: String, _ payload: Value = .null) {
    guard let ls = listeners[event], !ls.isEmpty else { return }
    var encoded: [UInt8]?
    for l in ls where registrations[l.handle] != nil {
      switch l.target {
      case let .host(fn): enter(nil) { fn(payload) }
      case let .plugin(fn, ud):
        guard let owner = l.owner, owner.crash == nil else { continue }
        if encoded == nil { encoded = Codec.encode(payload) }
        let bytes = encoded!
        guarded(owner) { tag, image in CBytes.borrow(bytes) { cordis_guard_event(fn, ud, $0, tag, image) } }
      case let .remote(rp, token):
        guard let owner = l.owner, owner.crash == nil else { continue }
        if encoded == nil { encoded = Codec.encode(payload) }
        rp.post(.event, [.int(token), .bytes(encoded!)])
      }
    }
  }

  /// Runs `handler` on the main queue after `milliseconds`, optionally repeating.
  @discardableResult
  public func timer(milliseconds: UInt64, repeats: Bool = false, _ handler: @escaping () -> Void) -> CordisHandle {
    addTimer(owner: nil, milliseconds: milliseconds, repeats: repeats, target: .host { _ in handler() })
  }

  /// Removes a host registration (or any registration, from the host's side).
  public func dispose(_ handle: CordisHandle) { dispose(handle, requestedBy: nil) }

  public var serviceNames: [String] { services.keys.sorted() }

  public var plugins: [PluginInfo] { order.compactMap { records[$0].map(info) } }

  public func plugin(_ id: String) -> PluginInfo? { records[id].map(info) }

  // MARK: - Loading

  /// Loads a plugin dylib. It is applied as soon as every injected service exists.
  /// - Parameter isolation: where the plugin runs; nil keeps what this path was loaded with before
  ///   (`.inProcess` the first time).
  @discardableResult
  public func load(_ path: String, isolation: PluginIsolation? = nil) throws(PluginHostError) -> PluginInfo {
    let isolation = isolation ?? isolationByPath[path] ?? .inProcess
    isolationByPath[path] = isolation
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
      throw .unreadable(path: path, reason: error.localizedDescription)
    }
    let hash = Self.hash(data)
    if let crash = lastCrash, crash.buildHash == hash {
      if records[crash.pluginID] == nil || records[crash.pluginID]?.isLoaded == false {
        setDisabled(id: crash.pluginID, path: path, hash: hash, reason: PluginHostError.crashedBuild(id: crash.pluginID, buildHash: hash).description)
      }
      throw .crashedBuild(id: crash.pluginID, buildHash: hash)
    }

    // A private, content-addressed copy: dyld never confuses two builds, the source file can be
    // rebuilt freely, and macOS only pays its first-dlopen code check once per build.
    let copy = (cacheDirectory as NSString).appendingPathComponent("\(hash).dylib")
    if (try? FileManager.default.attributesOfItem(atPath: copy)[.size] as? Int) != data.count {
      do { try data.write(to: URL(fileURLWithPath: copy), options: .atomic) } catch {
        throw .unreadable(path: copy, reason: error.localizedDescription)
      }
    }

    if case let .process(sandbox) = isolation {
      return try loadRemote(path: path, copy: copy, hash: hash, sandbox: sandbox)
    }

    guard let dl = dlopen(copy, RTLD_NOW | RTLD_LOCAL) else {
      let msg = dlerror().map { String(cString: $0) } ?? "unknown error"
      throw .dlopenFailed(msg)
    }
    func fail(_ e: PluginHostError) -> PluginHostError {
      dlclose(dl)
      return e
    }
    guard let mSym = dlsym(dl, "cordis_plugin_manifest") else { throw fail(.missingExport("cordis_plugin_manifest")) }
    guard let aSym = dlsym(dl, "cordis_plugin_apply") else { throw fail(.missingExport("cordis_plugin_apply")) }
    guard let dSym = dlsym(dl, "cordis_plugin_dispose") else { throw fail(.missingExport("cordis_plugin_dispose")) }
    let manifestFn = unsafeBitCast(mSym, to: cordis_plugin_manifest_fn.self)

    let manifestTag = strdup("?\t\(hash)")!
    var manifestBytes = cordis_bytes(data: nil, len: 0)
    pluginFrames += 1
    let manifestSignal = cordis_guard_manifest(manifestFn, manifestTag, cordis_guard_image_of(mSym), &manifestBytes)
    pluginFrames -= 1
    free(manifestTag)
    // Nothing of this image is registered yet: closing it is all the cleanup a fault needs.
    if manifestSignal != 0 { throw fail(.crashedWhileLoading(path: path, signal: manifestSignal)) }
    let manifest = CBytes.take(manifestBytes)

    guard let id = manifest["id"].string, !id.isEmpty else { throw fail(.badManifest("missing id")) }
    if let abi = manifest["abi"].int, abi != Int64(CORDIS_ABI_VERSION) { throw fail(.abiMismatch(abi)) }
    if let existing = records[id], existing.dl != nil { throw fail(.duplicate(id: id)) }

    var imagePath = copy
    var dlinfo = Dl_info()
    if dladdr(mSym, &dlinfo) != 0, let fname = dlinfo.dli_fname { imagePath = String(cString: fname) }

    if let crash = lastCrash, crash.pluginID == id {
      clearCrashRecord()  // a new build replaced the one that crashed
    }

    let record = PluginRecord(
      host: self, id: id, name: manifest["name"].string ?? id, version: manifest["version"].string ?? "0.0.0",
      inject: manifest["inject"].array?.compactMap(\.string) ?? [],
      provides: manifest["provides"].array?.compactMap(\.string) ?? [],
      path: path, buildHash: hash, imagePath: imagePath, cachePath: copy, dl: dl,
      applyFn: unsafeBitCast(aSym, to: cordis_plugin_apply_fn.self),
      disposeFn: unsafeBitCast(dSym, to: cordis_plugin_dispose_fn.self),
      probeAddress: UnsafeRawPointer(mSym))
    if !order.contains(id) { order.append(id) }
    records[id] = record
    reconcile()
    return info(records[id] ?? record)
  }

  /// Disposes the plugin (cascading to dependents), closes its image, and checks it was unmapped.
  @discardableResult
  public func unload(_ id: String) throws(PluginHostError) -> UnloadReport {
    guard let r = records[id] else { throw .notLoaded(id: id) }
    let report = teardown(r)
    records[id] = nil
    order.removeAll { $0 == id }
    reconcile()
    return report
  }

  public func unloadAll() {
    for id in order.reversed() { _ = try? unload(id) }
  }

  public enum ReloadResult: Equatable, Sendable {
    case unchanged
    case reloaded(PluginInfo, previous: UnloadReport?)
    case failed(reason: String, previous: UnloadReport?)
  }

  /// Replaces the plugin loaded from `path` with the file's current contents. On failure the
  /// plugin stays disabled and the reason is reported.
  @discardableResult
  public func reload(path: String) -> ReloadResult {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
      return .failed(reason: "cannot read \(path)", previous: nil)
    }
    let hash = Self.hash(data)
    let current = records.values.first { $0.path == path }
    if let current, current.buildHash == hash, current.isLoaded { return .unchanged }

    var previous: UnloadReport?
    if let current {
      previous = teardown(current)
      records[current.id] = nil
    }
    do {
      let info = try load(path)
      if let current, current.id != info.id { order.removeAll { $0 == current.id } }
      emitHostEvent(.reloaded(id: info.id, buildHash: info.buildHash))
      return .reloaded(info, previous: previous)
    } catch {
      let reason = error.description
      if let current, records[current.id] == nil {
        setDisabled(id: current.id, path: path, hash: hash, reason: reason)
      }
      emitHostEvent(.reloadFailed(path: path, reason: reason))
      return .failed(reason: reason, previous: previous)
    }
  }

  // MARK: - Hot reload

  /// Loads `path` (if not loaded yet) and reloads it whenever the file changes on disk.
  public func watch(_ path: String, isolation: PluginIsolation? = nil) {
    if let isolation { isolationByPath[path] = isolation }
    guard watchers[path] == nil else { return }
    if !records.values.contains(where: { $0.path == path }) {
      do { try load(path) } catch { emitHostEvent(.reloadFailed(path: path, reason: error.description)) }
    }
    watchers[path] = FileWatcher(path: path) { [weak self] in
      MainActor.assumeIsolated { _ = self?.reload(path: path) }
    }
  }

  public func unwatch(_ path: String) {
    watchers.removeValue(forKey: path)?.cancel()
  }

  // MARK: - Crash attribution

  public func clearCrashRecord() {
    lastCrash = nil
    if let m = crashMarkerPath { try? FileManager.default.removeItem(atPath: m) }
  }

  static func readCrashMarker(_ path: String) -> CrashRecord? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
    guard parts.count == 3, let sig = Int32(parts[2]) else { return nil }
    return CrashRecord(pluginID: parts[0], buildHash: parts[1], signal: sig)
  }

  // MARK: - Internals: out-of-process plugins

  private func loadRemote(path: String, copy: String, hash: String, sandbox: Bool) throws(PluginHostError) -> PluginInfo {
    let (rp, manifest) = try RemotePlugin.spawn(helper: helperExecutable, dylib: copy, sandbox: sandbox, host: self)
    guard let id = manifest["id"].string, !id.isEmpty else {
      rp.terminate()
      throw .badManifest("missing id")
    }
    if let abi = manifest["abi"].int, abi != Int64(CORDIS_ABI_VERSION) {
      rp.terminate()
      throw .abiMismatch(abi)
    }
    if let existing = records[id], existing.isLoaded {
      rp.terminate()
      throw .duplicate(id: id)
    }
    if let crash = lastCrash, crash.pluginID == id { clearCrashRecord() }
    let record = PluginRecord(
      host: self, id: id, name: manifest["name"].string ?? id, version: manifest["version"].string ?? "0.0.0",
      inject: manifest["inject"].array?.compactMap(\.string) ?? [],
      provides: manifest["provides"].array?.compactMap(\.string) ?? [],
      path: path, buildHash: hash, imagePath: "helper:\(rp.pid)", cachePath: copy, dl: nil,
      applyFn: nil, disposeFn: nil, probeAddress: nil)
    record.remote = rp
    record.isolation = .process(sandbox: sandbox)
    rp.record = record
    if !order.contains(id) { order.append(id) }
    records[id] = record
    reconcile()
    return info(records[id] ?? record)
  }

  /// A call from an out-of-process plugin: the same routing as an in-process plugin's call.
  func remoteCall(from r: PluginRecord, service: String, method: String, args: [UInt8]) -> [UInt8] {
    var m = method
    let result = m.withUTF8 { mb in
      args.withUnsafeBufferPointer { ab in
        rawCall(
          from: r, service: service, method: cordis_bytes(data: mb.baseAddress, len: mb.count),
          args: cordis_bytes(data: ab.baseAddress, len: ab.count))
      }
    }
    defer { if let d = result.data { free(UnsafeMutableRawPointer(mutating: d)) } }
    return result.data.map { Array(UnsafeBufferPointer(start: $0, count: result.len)) } ?? []
  }

  func remoteEmit(from r: PluginRecord, event: String, payload: [UInt8]) {
    payload.withUnsafeBufferPointer { rawEmit(from: r, event: event, payload: cordis_bytes(data: $0.baseAddress, len: $0.count)) }
  }

  /// The helper of `rp` died or was killed as hung: handled exactly like an in-process fault.
  func remoteDied(_ rp: RemotePlugin, signal: Int32, reason: String?) {
    guard let r = rp.record, r.crash == nil else { return }
    r.crash = signal == 0 ? SIGKILL : signal
    pendingCrashes.append(r)
    emitHostEvent(.log(pluginID: r.id, level: .error, message: "helper \(reason ?? "exited") (\(signalName(r.crash ?? 0))); unloading it"))
    if pluginFrames == 0 { finishCrashes() }
  }

  /// The helper's physical footprint for an out-of-process plugin (bytes; nil when in-process or gone).
  public func helperFootprint(_ id: String) -> UInt64? { records[id]?.remote.map(\.footprint) }

  // MARK: - Internals: crash recovery

  /// One call into plugin code through a `cordis_guard_*` function. Returns false when the plugin
  /// faulted: it is fenced off at once (nothing calls into it again) and torn down as soon as no
  /// plugin code is left on the stack, so no frame of it (or of anything it disposes) is still live.
  @discardableResult
  @inline(__always)
  private func guarded(_ r: PluginRecord, _ body: (UnsafePointer<CChar>, cordis_guard_image) -> Int32) -> Bool {
    r.frames += 1
    pluginFrames += 1
    let signal = body(UnsafePointer(r.tag), r.image)
    r.frames -= 1
    pluginFrames -= 1
    if signal != 0, r.crash == nil {
      r.crash = signal
      pendingCrashes.append(r)
      emitHostEvent(.log(pluginID: r.id, level: .error, message: "crashed (\(signalName(signal))); unloading it"))
    }
    if pluginFrames == 0, !pendingCrashes.isEmpty { finishCrashes() }
    return signal == 0
  }

  private func finishCrashes() {
    while !pendingCrashes.isEmpty {
      let r = pendingCrashes.removeFirst()
      guard records[r.id] === r, r.isLoaded else { continue }
      let outer = reconciling
      reconciling = true
      // Dependents are disposed normally (their dispose runs); the crashed plugin's isn't called.
      var cascaded: [String] = []
      if r.phase == .active {
        cascaded = deactivate(r)
      }
      for h in r.handles { removeRegistration(h) }
      let report = closeImage(r, cascaded: cascaded)
      r.phase = .disabled("crashed (\(signalName(r.crash ?? 0)))")
      reconciling = outer
      let crash = CrashReport(
        id: r.id, buildHash: r.buildHash, signal: r.crash ?? 0, path: r.path, cascaded: cascaded, unmapped: report.unmapped)
      emitHostEvent(.unloaded(report))
      emitHostEvent(.crashed(crash))
      onCrash?(crash)
    }
    if !reconciling { reconcile() }
  }

  private static func crashedError(_ r: PluginRecord) -> Value {
    error("plugin '\(r.id)' crashed (\(signalName(r.crash ?? 0)))")
  }

  // MARK: - Internals: execution context

  @inline(__always)
  func enter<R>(_ owner: PluginRecord?, _ body: () -> R) -> R {
    let prev = cordis_crash_swap_current(owner.map { UnsafePointer($0.tag) })
    defer { _ = cordis_crash_swap_current(prev) }
    return body()
  }

  private func emitHostEvent(_ e: HostEvent) {
    if let onEvent {
      onEvent(e)
    } else if case let .log(id, level, message) = e {
      FileHandle.standardError.write(Data("[\(id)] \(level): \(message)\n".utf8))
    }
  }

  private static func error(_ message: String) -> Value { .object([("error", .string(message))]) }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private func info(_ r: PluginRecord) -> PluginInfo {
    var i = r.info(missing: r.inject.filter { services[$0] == nil })
    i.isolation = r.isolation
    i.helperPID = r.remote?.pid
    return i
  }

  private func setDisabled(id: String, path: String, hash: String, reason: String) {
    let r = PluginRecord(
      host: self, id: id, name: id, version: "", inject: [], provides: [], path: path, buildHash: hash,
      imagePath: "", cachePath: nil, dl: nil, applyFn: nil, disposeFn: nil, probeAddress: nil,
      phase: .disabled(reason))
    if records[id] == nil, !order.contains(id) { order.append(id) }
    records[id] = r
  }

  // MARK: - Internals: registrations (called from HostTable too)

  private func newHandle() -> CordisHandle {
    defer { nextHandle += 1 }
    return nextHandle
  }

  func pluginLog(_ r: PluginRecord, level: Int32, message: String) {
    emitHostEvent(.log(pluginID: r.id, level: LogLevel(rawValue: level) ?? .info, message: message))
  }

  func addListener(owner: PluginRecord?, event: String, target: ListenerTarget) -> CordisHandle {
    let h = newHandle()
    registrations[h] = (owner, .listener(event: event))
    listeners[event, default: []].append(Listener(handle: h, owner: owner, target: target))
    owner?.handles.insert(h)
    return h
  }

  func addService(owner: PluginRecord?, name: String, target: ServiceTarget) -> CordisHandle {
    if services[name] != nil {
      emitHostEvent(.log(pluginID: owner?.id ?? "host", level: .error, message: "service '\(name)' is already provided"))
      return 0
    }
    let h = newHandle()
    registrations[h] = (owner, .service(name: name))
    services[name] = Service(handle: h, owner: owner, target: target)
    owner?.handles.insert(h)
    reconcile()
    return h
  }

  func addTimer(owner: PluginRecord?, milliseconds: UInt64, repeats: Bool, target: ListenerTarget) -> CordisHandle {
    let h = newHandle()
    let t = DispatchSource.makeTimerSource(queue: .main)
    let interval = DispatchTimeInterval.milliseconds(Int(clamping: milliseconds))
    t.schedule(deadline: .now() + interval, repeating: repeats ? interval : .never)
    t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fireTimer(h, repeats: repeats) } }
    registrations[h] = (owner, .timer(t, target))
    owner?.handles.insert(h)
    t.resume()
    return h
  }

  private func fireTimer(_ h: CordisHandle, repeats: Bool) {
    guard let reg = registrations[h], case let .timer(_, target) = reg.kind else { return }
    switch target {
    case let .host(fn): enter(nil) { fn(.null) }
    case let .plugin(fn, ud):
      guard let owner = reg.owner, owner.crash == nil else { return }
      guarded(owner) { tag, image in cordis_guard_event(fn, ud, cordis_bytes(data: nil, len: 0), tag, image) }
    case let .remote(rp, token):
      guard let owner = reg.owner, owner.crash == nil else { return }
      rp.post(.timer, [.int(token)])
    }
    if !repeats { removeRegistration(h) }
  }

  func rawCall(from r: PluginRecord, service: String, method: cordis_bytes, args: cordis_bytes) -> cordis_bytes {
    guard let s = services[service] else {
      return CBytes.owned(Self.error("service '\(service)' is not available"))
    }
    switch s.target {
    case let .plugin(fn, ud):
      // Plugin to plugin: bytes pass straight through, no decode/encode on the host.
      guard let owner = s.owner else { return CBytes.owned(Self.error("service '\(service)' has no owner")) }
      if owner.crash != nil { return CBytes.owned(Self.crashedError(owner)) }
      var result = cordis_bytes(data: nil, len: 0)
      let ok = guarded(owner) { tag, image in cordis_guard_service(fn, ud, method, args, tag, image, &result) }
      return ok ? result : CBytes.owned(Self.crashedError(owner))
    case let .remote(rp, token):
      guard let owner = s.owner else { return CBytes.owned(Self.error("service '\(service)' has no owner")) }
      if owner.crash != nil { return CBytes.owned(Self.crashedError(owner)) }
      let argBytes: [UInt8] = args.data.map { Array(UnsafeBufferPointer(start: $0, count: args.len)) } ?? []
      var out: Value?
      guarded(owner) { _, _ in
        out = rp.request(.service, [.int(token), .string(CBytes.string(method)), .bytes(argBytes)])
        return out == nil ? rp.failure : 0
      }
      guard let out else { return CBytes.owned(Self.crashedError(owner)) }
      return CBytes.owned(out.bytesOrEmpty)
    case let .host(fn):
      let m = CBytes.string(method), a = CBytes.value(args)
      return CBytes.owned(asCaller(r.id) { enter(nil) { fn(m, a) } })
    }
  }

  /// Runs host code on behalf of plugin `id` (see `caller`).
  @inline(__always)
  func asCaller<R>(_ id: String?, _ body: () -> R) -> R {
    let previous = caller
    caller = id
    defer { caller = previous }
    return body()
  }

  func rawEmit(from r: PluginRecord, event: String, payload: cordis_bytes) {
    guard let ls = listeners[event], !ls.isEmpty else { return }
    var decoded: Value?
    for l in ls where registrations[l.handle] != nil {
      switch l.target {
      case let .plugin(fn, ud):
        guard let owner = l.owner, owner.crash == nil else { continue }
        guarded(owner) { tag, image in cordis_guard_event(fn, ud, payload, tag, image) }
      case let .remote(rp, token):
        guard let owner = l.owner, owner.crash == nil else { continue }
        let bytes: [UInt8] = payload.data.map { Array(UnsafeBufferPointer(start: $0, count: payload.len)) } ?? []
        rp.post(.event, [.int(token), .bytes(bytes)])
      case let .host(fn):
        if decoded == nil { decoded = CBytes.value(payload) }
        let v = decoded!
        asCaller(r.id) { enter(nil) { fn(v) } }
      }
    }
  }

  func dispose(_ handle: CordisHandle, requestedBy requester: PluginRecord?) {
    guard let reg = registrations[handle] else { return }
    if let requester, reg.owner !== requester { return }  // plugins may only dispose their own
    removeRegistration(handle)
  }

  private func removeRegistration(_ h: CordisHandle) {
    guard let reg = registrations.removeValue(forKey: h) else { return }
    reg.owner?.handles.remove(h)
    switch reg.kind {
    case let .listener(event):
      listeners[event]?.removeAll { $0.handle == h }
      if listeners[event]?.isEmpty == true { listeners[event] = nil }
    case let .timer(t, _):
      t.setEventHandler {}
      t.cancel()
    case let .service(name):
      guard services[name]?.handle == h else { return }
      // Dependents are disposed while the provider is still intact, then the service goes away.
      for d in activeDependents(of: name) { deactivate(d) }
      services[name] = nil
      reconcile()
    }
  }

  // MARK: - Internals: dependency resolution

  private func activeDependents(of service: String) -> [PluginRecord] {
    order.compactMap { records[$0] }.filter { $0.phase == .active && $0.inject.contains(service) }
  }

  /// Applies every pending plugin whose injected services all exist, until nothing changes.
  private func reconcile() {
    if reconciling {
      dirty = true
      return
    }
    reconciling = true
    defer { reconciling = false }
    repeat {
      dirty = false
      for id in order {
        guard let r = records[id], r.phase == .pending, r.isLoaded,
          r.inject.allSatisfy({ services[$0] != nil })
        else { continue }
        apply(r)
      }
    } while dirty
  }

  private func apply(_ r: PluginRecord) {
    var rc: Int32 = -1
    if let rp = r.remote {
      r.phase = .active
      guarded(r) { _, _ in
        guard let v = rp.request(.apply, []) else { return rp.failure }
        rc = Int32(truncatingIfNeeded: v.int ?? -1)
        return 0
      }
    } else {
      guard let applyFn = r.applyFn else { return }
      r.phase = .active
      let table = UnsafePointer(r.table)
      guarded(r) { tag, image in cordis_guard_apply(applyFn, table, tag, image, &rc) }
    }
    if r.crash != nil { return }  // torn down as a crash (now, or once the stack unwinds)
    if rc == 0 {
      emitHostEvent(.applied(id: r.id))
      return
    }
    // Failed: drop anything it registered, close the image, keep the record as disabled.
    r.phase = .disposing
    for h in r.handles { removeRegistration(h) }
    let reason = "cordis_plugin_apply returned \(rc)"
    let report = closeImage(r, cascaded: [])
    records[r.id] = PluginRecord(
      host: self, id: r.id, name: r.name, version: r.version, inject: r.inject, provides: r.provides,
      path: r.path, buildHash: r.buildHash, imagePath: r.imagePath, cachePath: nil, dl: nil, applyFn: nil,
      disposeFn: nil, probeAddress: nil, phase: .disabled(reason))
    emitHostEvent(.applyFailed(id: r.id, reason: reason))
    emitHostEvent(.unloaded(report))
    dirty = true
  }

  /// Disposes dependents first, then the plugin itself, then every handle it still holds.
  @discardableResult
  private func deactivate(_ r: PluginRecord) -> [String] {
    guard r.phase == .active else { return [] }
    r.phase = .disposing
    var cascaded: [String] = []
    for h in r.handles {
      guard let reg = registrations[h], case let .service(name) = reg.kind else { continue }
      for d in activeDependents(of: name) {
        cascaded.append(d.id)
        cascaded += deactivate(d)
      }
    }
    // A plugin that faulted is never called again, not even to dispose.
    if let rp = r.remote, r.crash == nil {
      guarded(r) { _, _ in rp.request(.dispose, []) == nil ? rp.failure : 0 }
    } else if let disposeFn = r.disposeFn, r.crash == nil {
      guarded(r) { tag, image in cordis_guard_dispose(disposeFn, tag, image) }
    }
    for h in r.handles { removeRegistration(h) }
    if r.crash != nil { return cascaded }
    r.phase = .pending
    emitHostEvent(.disposed(id: r.id))
    return cascaded
  }

  private func teardown(_ r: PluginRecord) -> UnloadReport {
    // Nothing is applied until `r` is completely gone: while its handles are removed one by one,
    // its services are still registered but it may already be disposed, so a dependent applied
    // now could call into a dead plugin. Nested reconciles only mark the host dirty; `unload`
    // and `reload` reconcile once `r` is out.
    let outer = reconciling
    reconciling = true
    defer { reconciling = outer }
    let cascaded = deactivate(r)
    r.phase = .disposing
    for h in r.handles { removeRegistration(h) }
    let report = closeImage(r, cascaded: cascaded)
    r.phase = .disabled("unloaded")
    emitHostEvent(.unloaded(report))
    return report
  }

  private func closeImage(_ r: PluginRecord, cascaded: [String]) -> UnloadReport {
    if let rp = r.remote {
      rp.terminate()
      r.remote = nil
      let n = Int(_dyld_image_count())
      return UnloadReport(
        id: r.id, imagePath: r.imagePath, imageCountBefore: n, imageCountAfter: n, unmapped: !rp.isAlive, cascaded: cascaded)
    }
    let before = Int(_dyld_image_count())
    if let dl = r.dl {
      dlclose(dl)
      r.dl = nil
    }
    let after = Int(_dyld_image_count())
    let listed = Self.loadedImagePaths().contains(r.imagePath)
    var stillResolves = false
    if let addr = r.probeAddress {
      var dlinfo = Dl_info()
      stillResolves = dladdr(addr, &dlinfo) != 0 && dlinfo.dli_fname != nil
    }
    return UnloadReport(
      id: r.id, imagePath: r.imagePath, imageCountBefore: before, imageCountAfter: after,
      unmapped: !listed && !stillResolves, cascaded: cascaded)
  }

  static func loadedImagePaths() -> Set<String> {
    var paths = Set<String>()
    for i in 0..<_dyld_image_count() {
      if let name = _dyld_get_image_name(i) { paths.insert(String(cString: name)) }
    }
    return paths
  }
}
