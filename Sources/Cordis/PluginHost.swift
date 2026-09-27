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
  }

  enum ServiceTarget {
    case host((String, Value) -> Value)
    case plugin(cordis_service_fn, UnsafeMutableRawPointer?)
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

  // MARK: Configuration

  /// Receives lifecycle events and plugin log lines. When nil, logs go to stderr.
  public var onEvent: ((HostEvent) -> Void)?

  /// The plugin that crashed the previous run, if any. Its build stays disabled until a new build
  /// (different hash) of the same plugin id is loaded, which also clears this record.
  public private(set) var lastCrash: CrashRecord?

  public let crashMarkerPath: String?
  public let cacheDirectory: String
  private var watchers: [String: FileWatcher] = [:]

  public static var defaultCacheDirectory: String {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return caches.appendingPathComponent("cordis-swift/\(ProcessInfo.processInfo.processName)/images").path
  }

  /// Deletes cached dylib copies that are not currently loaded.
  public func pruneCache() {
    let live = Set(records.values.compactMap { $0.dl != nil ? $0.cachePath : nil })
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
  public init(crashMarkerPath: String? = PluginHost.defaultCrashMarkerPath, cacheDirectory: String? = nil) {
    self.crashMarkerPath = crashMarkerPath
    let cache = cacheDirectory ?? Self.defaultCacheDirectory
    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    self.cacheDirectory = (cache as NSString).resolvingSymlinksInPath
    if let marker = crashMarkerPath {
      try? FileManager.default.createDirectory(
        atPath: (marker as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      lastCrash = Self.readCrashMarker(marker)
      cordis_crash_install(marker)
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
      callDepth += 1
      let prev = cordis_crash_swap_current(s.owner.map { UnsafePointer($0.tag) })
      let result = fn(ud, cordis_bytes(data: buf, len: methodLen), cordis_bytes(data: buf + methodLen, len: argsLen))
      _ = cordis_crash_swap_current(prev)
      callDepth -= 1
      if !reuse { buf.deallocate() }
      return CBytes.take(result)
    }
  }

  /// Listens to an event emitted by the host or any plugin.
  @discardableResult
  public func on(_ event: String, _ handler: @escaping (Value) -> Void) -> CordisHandle {
    addListener(owner: nil, event: event, target: .host(handler))
  }

  public func emit(_ event: String, _ payload: Value = .null) {
    guard let ls = listeners[event], !ls.isEmpty else { return }
    var encoded: [UInt8]?
    for l in ls where registrations[l.handle] != nil {
      switch l.target {
      case let .host(fn): enter(nil) { fn(payload) }
      case let .plugin(fn, ud):
        if encoded == nil { encoded = Codec.encode(payload) }
        enter(l.owner) { CBytes.borrow(encoded!) { fn(ud, $0) } }
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
  @discardableResult
  public func load(_ path: String) throws(PluginHostError) -> PluginInfo {
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
      throw .unreadable(path: path, reason: error.localizedDescription)
    }
    let hash = Self.hash(data)
    if let crash = lastCrash, crash.buildHash == hash {
      if records[crash.pluginID] == nil || records[crash.pluginID]?.dl == nil {
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

    let manifestTag = strdup("?\t\(hash)")
    let prev = cordis_crash_swap_current(manifestTag)
    let manifest = CBytes.take(manifestFn())
    _ = cordis_crash_swap_current(prev)
    free(manifestTag)

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
    if let current, current.buildHash == hash, current.dl != nil { return .unchanged }

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
  public func watch(_ path: String) {
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
    r.info(missing: r.inject.filter { services[$0] == nil })
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
    case let .plugin(fn, ud): enter(reg.owner) { fn(ud, cordis_bytes(data: nil, len: 0)) }
    }
    if !repeats { removeRegistration(h) }
  }

  func rawCall(service: String, method: cordis_bytes, args: cordis_bytes) -> cordis_bytes {
    guard let s = services[service] else {
      return CBytes.owned(Self.error("service '\(service)' is not available"))
    }
    switch s.target {
    case let .plugin(fn, ud):
      // Plugin to plugin: bytes pass straight through, no decode/encode on the host.
      return enter(s.owner) { fn(ud, method, args) }
    case let .host(fn):
      let m = CBytes.string(method), a = CBytes.value(args)
      return CBytes.owned(enter(nil) { fn(m, a) })
    }
  }

  func rawEmit(event: String, payload: cordis_bytes) {
    guard let ls = listeners[event], !ls.isEmpty else { return }
    var decoded: Value?
    for l in ls where registrations[l.handle] != nil {
      switch l.target {
      case let .plugin(fn, ud): enter(l.owner) { fn(ud, payload) }
      case let .host(fn):
        if decoded == nil { decoded = CBytes.value(payload) }
        enter(nil) { fn(decoded!) }
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
        guard let r = records[id], r.phase == .pending, r.dl != nil,
          r.inject.allSatisfy({ services[$0] != nil })
        else { continue }
        apply(r)
      }
    } while dirty
  }

  private func apply(_ r: PluginRecord) {
    guard let applyFn = r.applyFn else { return }
    r.phase = .active
    let rc = enter(r) { applyFn(UnsafePointer(r.table)) }
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
    if let disposeFn = r.disposeFn { enter(r) { disposeFn() } }
    for h in r.handles { removeRegistration(h) }
    r.phase = .pending
    emitHostEvent(.disposed(id: r.id))
    return cascaded
  }

  private func teardown(_ r: PluginRecord) -> UnloadReport {
    let cascaded = deactivate(r)
    r.phase = .disposing
    for h in r.handles { removeRegistration(h) }
    let report = closeImage(r, cascaded: cascaded)
    r.phase = .disabled("unloaded")
    emitHostEvent(.unloaded(report))
    return report
  }

  private func closeImage(_ r: PluginRecord, cascaded: [String]) -> UnloadReport {
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
