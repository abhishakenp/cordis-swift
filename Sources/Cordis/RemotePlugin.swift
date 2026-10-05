import CCordisHelper
import CordisWire
import Foundation

/// How a plugin runs.
public enum PluginIsolation: Equatable, Sendable {
  /// In the host process: a call is a C function call (~0.2 µs). Faults in the plugin's own code
  /// are recovered (`PluginHost.crashRecovery`), but the plugin can read and write anything the
  /// process can.
  case inProcess
  /// In its own helper process (`PluginHost.helperExecutable`), reached over a socket. A crash or
  /// hang only ends the helper. With `sandbox`, the helper can't touch files, the network or other
  /// processes: everything goes through the host's services, which the host gates per plugin.
  case process(sandbox: Bool)
}

/// The host's end of one out-of-process plugin: its helper process and the socket to it.
/// Main thread only, like everything in `PluginHost`.
@MainActor
final class RemotePlugin {
  let pid: pid_t
  let wire: WireConnection
  unowned(unsafe) let host: PluginHost
  /// The record this helper serves (set once the manifest is read).
  weak var record: PluginRecord?
  private var seq: Int64 = 0
  private var source: DispatchSourceRead?
  /// Events and timer ticks sent without waiting: seq -> nothing (the helper answers each).
  private var outstanding: Set<Int64> = []
  /// Set once the helper is gone: (signal it died from, or SIGKILL when it was killed for a hang).
  private(set) var exitSignal: Int32?
  private var reaped = false

  /// How long a synchronous request (apply, dispose, a service call) may take before the helper is
  /// considered hung and killed; events and timer ticks get the same budget to be answered.
  var timeoutMs: Int32 { Int32(max(0.01, host.helperTimeout) * 1000) }

  private init(pid: pid_t, fd: Int32, host: PluginHost) {
    self.pid = pid
    wire = WireConnection(fd: fd)
    self.host = host
  }

  /// Starts a helper for `dylib` and waits for its manifest.
  static func spawn(helper: String, dylib: String, sandbox: Bool, host: PluginHost) throws(PluginHostError) -> (RemotePlugin, Value) {
    guard FileManager.default.isExecutableFile(atPath: helper) else {
      throw .helperFailed("no plugin helper at \(helper)")
    }
    guard let (mine, theirs) = WireConnection.pair() else { throw .helperFailed("socketpair: \(String(cString: strerror(errno)))") }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, 2, 1)  // plugin output goes to the host's stderr
    posix_spawn_file_actions_adddup2(&actions, 2, 2)
    posix_spawn_file_actions_adddup2(&actions, theirs, 3)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    // Close everything else the host has open: the helper inherits only fds 0-3.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    var args = [helper, dylib]
    if sandbox { args.append("--sandbox") }
    let argv = args.map { strdup($0) } + [nil]
    defer { for a in argv { free(a) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, helper, &actions, &attr, argv, environ)
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    close(theirs)
    guard rc == 0 else {
      close(mine)
      throw .helperFailed("posix_spawn \(helper): \(String(cString: strerror(rc)))")
    }
    let remote = RemotePlugin(pid: pid, fd: mine, host: host)
    // The first dlopen of a new file is checked by macOS (measured: up to ~700 ms); be generous.
    switch remote.wire.receive(timeoutMs: max(remote.timeoutMs, 10_000)) {
    case let .message(m) where m.first?.int == WireKind.hello.rawValue && m.count >= 3:
      if let error = m[2]["error"].string {
        remote.terminate()
        throw .helperFailed(error)
      }
      guard case let .bytes(b) = m[2], let manifest = Codec.decode(b) else {
        remote.terminate()
        throw .helperFailed("bad manifest from helper")
      }
      remote.listen()
      return (remote, manifest)
    case .closed:
      let sig = remote.terminate()
      throw .helperFailed("helper exited before reading the plugin (\(signalName(sig)))")
    default:
      remote.terminate()
      throw .helperFailed("helper did not answer")
    }
  }

  /// Serves the helper's requests while the host is idle (events it handles asynchronously).
  private func listen() {
    let s = DispatchSource.makeReadSource(fileDescriptor: wire.fd, queue: .main)
    s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
    s.resume()
    source = s
  }

  private func drain() {
    while exitSignal == nil {
      switch wire.receive(timeoutMs: 0) {
      case .timeout: return
      case .closed:
        died()
        return
      case let .message(m): handle(m)
      }
    }
  }

  // MARK: Host -> helper

  /// A synchronous request: serves the helper's own requests until the answer arrives.
  /// nil when the helper died or hung (it is then killed and reported as crashed).
  func request(_ kind: WireKind, _ fields: [Value]) -> Value? {
    guard exitSignal == nil else { return nil }
    seq += 1
    let mine = seq
    guard wire.send([.int(kind.rawValue), .int(mine)] + fields) else {
      died()
      return nil
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
    while exitSignal == nil {
      let now = DispatchTime.now().uptimeNanoseconds
      if now >= deadline {
        hung()
        return nil
      }
      switch wire.receive(timeoutMs: Int32(max(1, (deadline - now) / 1_000_000))) {
      case .timeout: continue
      case .closed:
        died()
        return nil
      case let .message(m):
        if m.first?.int == WireKind.reply.rawValue && m.count >= 3 && m[1].int == mine { return m[2] }
        handle(m)
      }
    }
    return nil
  }

  /// An event or timer tick: sent without waiting. The helper must answer it within the timeout.
  func post(_ kind: WireKind, _ fields: [Value]) {
    guard exitSignal == nil else { return }
    seq += 1
    let mine = seq
    outstanding.insert(mine)
    guard wire.send([.int(kind.rawValue), .int(mine)] + fields) else {
      died()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.outstanding.contains(mine), self.exitSignal == nil else { return }
        self.hung()
      }
    }
  }

  // MARK: Helper -> host

  private func handle(_ m: [Value]) {
    guard let k = m.first?.int, let kind = WireKind(rawValue: k), m.count >= 2 else { return }
    let seq = m[1]
    guard let r = record else { return }
    func reply(_ v: Value) { wire.send([.int(WireKind.reply.rawValue), seq, v]) }
    switch kind {
    case .reply:
      if let s = seq.int { outstanding.remove(s) }
    case .call:
      guard m.count >= 5 else { return reply(.bytes(Codec.encode(["error": "bad call"]))) }
      reply(.bytes(host.remoteCall(from: r, service: m[2].string ?? "", method: m[3].string ?? "", args: m[4].bytesOrEmpty)))
    case .on:
      reply(.int(Int64(bitPattern: host.addListener(owner: r, event: m[2].string ?? "", target: .remote(self, m[3].int ?? -1)))))
    case .provide:
      reply(.int(Int64(bitPattern: host.addService(owner: r, name: m[2].string ?? "", target: .remote(self, m[3].int ?? -1)))))
    case .timerAdd:
      let h = host.addTimer(
        owner: r, milliseconds: UInt64(max(0, m[2].int ?? 0)), repeats: m[3].bool ?? false, target: .remote(self, m[4].int ?? -1))
      reply(.int(Int64(bitPattern: h)))
    case .emit:
      host.remoteEmit(from: r, event: m[2].string ?? "", payload: m[3].bytesOrEmpty)
    case .log:
      host.pluginLog(r, level: Int32(truncatingIfNeeded: m[2].int ?? 1), message: m[3].string ?? "")
    case .disposeHandle:
      if let h = m[2].int { host.dispose(CordisHandle(bitPattern: h), requestedBy: r) }
    default:
      break
    }
  }

  // MARK: Lifecycle

  private func hung() {
    guard exitSignal == nil else { return }
    kill(pid, SIGKILL)
    reap()
    exitSignal = SIGKILL
    host.remoteDied(self, signal: SIGKILL, reason: "not responding")
  }

  private func died() {
    guard exitSignal == nil else { return }
    let sig = reap()
    exitSignal = sig
    host.remoteDied(self, signal: sig, reason: nil)
  }

  /// Waits for the helper to be gone and returns the signal it died from (0: it exited).
  @discardableResult
  private func reap() -> Int32 {
    source?.cancel()
    source = nil
    wire.close()
    guard !reaped else { return exitSignal ?? 0 }
    reaped = true
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let low = status & 0x7f
    return low != 0 && low != 0x7f ? low : 0
  }

  /// Ends the helper (unload, reload). Returns the signal it ended with.
  @discardableResult
  func terminate() -> Int32 {
    if exitSignal == nil {
      kill(pid, SIGKILL)
      exitSignal = reap()
    }
    return exitSignal ?? 0
  }

  var isAlive: Bool { exitSignal == nil }

  /// The signal to report for a failed request: what the helper died from, SIGKILL otherwise.
  var failure: Int32 { exitSignal.flatMap { $0 == 0 ? nil : $0 } ?? SIGKILL }

  /// The helper's physical footprint in bytes (0 when it's gone).
  var footprint: UInt64 { exitSignal == nil ? cordis_helper_footprint(pid) : 0 }
}

extension Value {
  var bytesOrEmpty: [UInt8] { if case let .bytes(b) = self { b } else { [] } }
}
