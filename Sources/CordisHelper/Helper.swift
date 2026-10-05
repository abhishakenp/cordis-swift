// The process side of an out-of-process plugin. `cordisHelperMain()` loads one plugin dylib and
// serves it to the host over the socket on fd 3 (see CordisWire). The plugin sees the ordinary
// cordis_host table; every entry forwards to the host. The helper is passive: it only runs plugin
// code in answer to a host message (apply, dispose, a service call, an event, a timer), so a plugin
// never runs concurrently with itself, exactly like in-process plugins on the main thread.
//
//   cordis-plugin-helper <plugin.dylib> [--sandbox]
//
// fd 3: the socket to the host. fd 4 (optional): the read end of the host's lifeline pipe.
//
// With --sandbox the process enters the pure-computation sandbox right after loading the dylib:
// the plugin can't open files, sockets or other processes; it reaches the world only through the
// host's services, which the host gates per plugin.
import CCordis
import CCordisHelper
import CordisValue
import CordisWire

#if canImport(Darwin)
  import Darwin
#endif

enum HelperState {
  nonisolated(unsafe) static var wire: WireConnection!
  nonisolated(unsafe) static var seq: Int64 = 0
  /// Plugin callbacks the host refers to by token (index): (function pointer, userdata).
  nonisolated(unsafe) static var callbacks: [(UnsafeRawPointer, UnsafeMutableRawPointer?)] = []
  nonisolated(unsafe) static var applyFn: cordis_plugin_apply_fn?
  nonisolated(unsafe) static var disposeFn: cordis_plugin_dispose_fn?
  nonisolated(unsafe) static var table = cordis_host()
}

private func fail(_ message: String) -> Never {
  HelperState.wire?.send([.int(WireKind.hello.rawValue), 0, ["error": .string(message)]])
  exit(1)
}

private func bytesValue(_ b: cordis_bytes) -> Value {
  guard let data = b.data, b.len > 0 else { return .bytes([]) }
  return .bytes(Array(UnsafeBufferPointer(start: data, count: b.len)))
}

private func string(_ b: cordis_bytes) -> String {
  guard let data = b.data, b.len > 0 else { return "" }
  return String(decoding: UnsafeBufferPointer(start: data, count: b.len), as: UTF8.self)
}

/// A malloc'd copy, which the plugin will free.
private func owned(_ bytes: [UInt8]) -> cordis_bytes {
  let p = malloc(max(bytes.count, 1))!.assumingMemoryBound(to: UInt8.self)
  bytes.withUnsafeBufferPointer { if let b = $0.baseAddress { p.update(from: b, count: $0.count) } }
  return cordis_bytes(data: UnsafePointer(p), len: bytes.count)
}

private func borrow<R>(_ v: Value, _ body: (cordis_bytes) -> R) -> R {
  let bytes: [UInt8] = if case let .bytes(b) = v { b } else { [] }
  return bytes.withUnsafeBufferPointer { body(cordis_bytes(data: $0.baseAddress, len: $0.count)) }
}

private func token(_ fn: UnsafeRawPointer, _ ud: UnsafeMutableRawPointer?) -> Value {
  HelperState.callbacks.append((fn, ud))
  return .int(Int64(HelperState.callbacks.count - 1))
}

/// Sends a request to the host and serves host requests until its answer arrives.
private func request(_ kind: WireKind, _ fields: [Value]) -> Value {
  HelperState.seq += 1
  let seq = HelperState.seq
  guard HelperState.wire.send([.int(kind.rawValue), .int(seq)] + fields) else { exit(0) }
  while true {
    switch HelperState.wire.receive(timeoutMs: -1) {
    case .closed, .timeout: exit(0)  // the host is gone
    case let .message(m):
      if m.first?.int == WireKind.reply.rawValue && m.count > 2 && m[1].int == seq { return m[2] }
      serve(m)
    }
  }
}

private func post(_ kind: WireKind, _ fields: [Value]) {
  guard HelperState.wire.send([.int(kind.rawValue), 0] + fields) else { exit(0) }
}

private func reply(_ seq: Value, _ value: Value) {
  guard HelperState.wire.send([.int(WireKind.reply.rawValue), seq, value]) else { exit(0) }
}

/// One host request.
private func serve(_ m: [Value]) {
  guard let k = m.first?.int, let kind = WireKind(rawValue: k), m.count >= 2 else { return }
  let seq = m[1]
  func callback(_ i: Int) -> (UnsafeRawPointer, UnsafeMutableRawPointer?)? {
    guard let t = m[i].int, t >= 0, Int(t) < HelperState.callbacks.count else { return nil }
    return HelperState.callbacks[Int(t)]
  }
  switch kind {
  case .apply:
    guard let apply = HelperState.applyFn else { return reply(seq, .int(-1)) }
    let rc = withUnsafePointer(to: &HelperState.table) { apply($0) }
    reply(seq, .int(Int64(rc)))
  case .dispose:
    HelperState.disposeFn?()
    reply(seq, .null)
  case .service:
    guard m.count >= 5, let (fn, ud) = callback(2) else { return reply(seq, .null) }
    let service = unsafeBitCast(fn, to: cordis_service_fn.self)
    let method = m[3].string ?? ""
    var name = method
    let result = name.withUTF8 { mb in
      borrow(m[4]) { args in service(ud, cordis_bytes(data: mb.baseAddress, len: mb.count), args) }
    }
    let out = bytesValue(result)
    if let d = result.data { free(UnsafeMutableRawPointer(mutating: d)) }
    reply(seq, out)
  case .event:
    guard m.count >= 4, let (fn, ud) = callback(2) else { return reply(seq, .null) }
    let event = unsafeBitCast(fn, to: cordis_event_fn.self)
    borrow(m[3]) { event(ud, $0) }
    reply(seq, .null)
  case .timer:
    guard m.count >= 3, let (fn, ud) = callback(2) else { return reply(seq, .null) }
    unsafeBitCast(fn, to: cordis_event_fn.self)(ud, cordis_bytes(data: nil, len: 0))
    reply(seq, .null)
  case .exit:
    exit(0)
  default:
    break
  }
}

private func makeTable() -> cordis_host {
  cordis_host(
    abi_version: UInt32(CORDIS_ABI_VERSION),
    host_ctx: nil,
    log: { _, level, msg in post(.log, [.int(Int64(level)), .string(string(msg))]) },
    call: { _, service, method, args in
      let r = request(.call, [.string(string(service)), .string(string(method)), bytesValue(args)])
      if case let .bytes(b) = r { return owned(b) }
      return owned(Codec.encode(["error": "host: bad reply"]))
    },
    on: { _, event, fn, ud in
      guard let fn else { return 0 }
      let t = token(unsafeBitCast(fn, to: UnsafeRawPointer.self), ud)
      return UInt64(request(.on, [.string(string(event)), t]).int ?? 0)
    },
    emit: { _, event, payload in post(.emit, [.string(string(event)), bytesValue(payload)]) },
    provide: { _, service, fn, ud in
      guard let fn else { return 0 }
      let t = token(unsafeBitCast(fn, to: UnsafeRawPointer.self), ud)
      return UInt64(request(.provide, [.string(string(service)), t]).int ?? 0)
    },
    timer: { _, ms, repeats, fn, ud in
      guard let fn else { return 0 }
      let t = token(unsafeBitCast(fn, to: UnsafeRawPointer.self), ud)
      return UInt64(request(.timerAdd, [.int(Int64(clamping: ms)), .bool(repeats), t]).int ?? 0)
    },
    dispose: { _, handle in post(.disposeHandle, [.int(Int64(bitPattern: handle))]) }
  )
}

/// Ends the helper as soon as the host is gone, even while plugin code is busy (a plugin stuck in
/// a loop never reads the socket again). fd 4 is the read end of a pipe whose only write end the
/// host holds and never writes to: a second thread blocks in read() (no wakeups) until the host's
/// end closes, which happens however the host ends.
private func exitWhenTheHostIsGone(_ lifeline: Int32) {
  var thread: pthread_t?
  let arg = UnsafeMutableRawPointer(bitPattern: Int(lifeline) + 1)!
  pthread_create(
    &thread, nil,
    { raw in
      let fd = Int32(Int(bitPattern: raw) - 1)
      var byte: UInt8 = 0
      while true {
        let r = read(fd, &byte, 1)
        if r < 0 && errno == EINTR { continue }
        if r <= 0 { _exit(0) }  // EOF: the host is gone (or the lifeline is broken)
      }
    }, arg)
}

/// Entry point of cordis-plugin-helper. Never returns.
public func cordisHelperMain(_ arguments: [String]) -> Never {
  signal(SIGPIPE, SIG_IGN)
  HelperState.wire = WireConnection(fd: 3)
  if fcntl(4, F_GETFD) != -1 { exitWhenTheHostIsGone(4) }
  guard arguments.count >= 2 else { fail("usage: cordis-plugin-helper <plugin.dylib> [--sandbox]") }
  let path = arguments[1]
  guard let dl = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
    fail("dlopen failed: " + (dlerror().map { String(cString: $0) } ?? "unknown error"))
  }
  guard let m = dlsym(dl, "cordis_plugin_manifest") else { fail("plugin does not export cordis_plugin_manifest") }
  guard let a = dlsym(dl, "cordis_plugin_apply") else { fail("plugin does not export cordis_plugin_apply") }
  guard let d = dlsym(dl, "cordis_plugin_dispose") else { fail("plugin does not export cordis_plugin_dispose") }
  HelperState.applyFn = unsafeBitCast(a, to: cordis_plugin_apply_fn.self)
  HelperState.disposeFn = unsafeBitCast(d, to: cordis_plugin_dispose_fn.self)
  HelperState.table = makeTable()

  let manifest = unsafeBitCast(m, to: cordis_plugin_manifest_fn.self)()
  let mv = bytesValue(manifest)
  if let data = manifest.data { free(UnsafeMutableRawPointer(mutating: data)) }

  if arguments.contains("--sandbox") {
    var err = [CChar](repeating: 0, count: 512)
    if cordis_helper_sandbox(&err, 512) != 0 {
      fail("sandbox: " + String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
  }
  HelperState.wire.send([.int(WireKind.hello.rawValue), 0, mv])
  while true {
    switch HelperState.wire.receive(timeoutMs: -1) {
    case .closed, .timeout: exit(0)
    case let .message(msg): serve(msg)
    }
  }
}
