// Ergonomic wrappers over the cordis_host function table.
// Swift closures are boxed, passed as userdata, and invoked from static @convention(c) trampolines.

#if !hasFeature(Embedded)
  import CordisValue
#endif
import CCordis

public typealias Handle = cordis_handle

public enum LogLevel: Int32 {
  case debug = 0, info = 1, warn = 2, error = 3
}

// MARK: - Boxes

class CallbackBox {
  var handle: cordis_handle = 0
}

final class EventBox: CallbackBox {
  let fn: (Value) -> Void
  init(_ fn: @escaping (Value) -> Void) { self.fn = fn }
}

final class TimerBox: CallbackBox {
  let fn: () -> Void
  let repeats: Bool
  init(_ fn: @escaping () -> Void, repeats: Bool) {
    self.fn = fn
    self.repeats = repeats
  }
}

final class ServiceBox: CallbackBox {
  let fn: (String, Value) -> Value
  init(_ fn: @escaping (String, Value) -> Value) { self.fn = fn }
}

// MARK: - Per-plugin runtime state (main thread only)

enum Runtime {
  nonisolated(unsafe) static var host: UnsafePointer<cordis_host>? = nil
  nonisolated(unsafe) static var pluginID: String = ""
  /// Keeps every live callback box alive; userdata pointers are unretained views of these.
  nonisolated(unsafe) static var boxes: [cordis_handle: CallbackBox] = [:]

  static func keep(_ box: CallbackBox, _ handle: cordis_handle) -> cordis_handle {
    if handle != 0 {
      box.handle = handle
      boxes[handle] = box
    }
    return handle
  }

  static func releaseAll() { boxes.removeAll() }
}

// MARK: - Trampolines

let eventTrampoline: cordis_event_fn = { userdata, payload in
  guard let userdata else { return }
  let box = Unmanaged<EventBox>.fromOpaque(userdata).takeUnretainedValue()
  box.fn(Bytes.value(payload))
}

let timerTrampoline: cordis_event_fn = { userdata, _ in
  guard let userdata else { return }
  let box = Unmanaged<TimerBox>.fromOpaque(userdata).takeUnretainedValue()
  box.fn()
  // The host drops one-shot timers after they fire; drop our box too.
  if !box.repeats { Runtime.boxes[box.handle] = nil }
}

let serviceTrampoline: cordis_service_fn = { userdata, method, args in
  guard let userdata else { return Bytes.owned(Value.object([("error", "no service")])) }
  let box = Unmanaged<ServiceBox>.fromOpaque(userdata).takeUnretainedValue()
  return Bytes.owned(box.fn(Bytes.string(method), Bytes.value(args)))
}

// MARK: - Context

/// The plugin's view of the host. Cheap to copy; valid between `apply` and `dispose`.
public struct Context {
  init() {}

  /// The plugin id given to `cordis-build --id`.
  public var pluginID: String { Runtime.pluginID }

  public func log(_ message: String, level: LogLevel = .info) {
    guard let h = Runtime.host else { return }
    Bytes.borrow(message) { h.pointee.log(h.pointee.host_ctx, level.rawValue, $0) }
  }

  /// Calls `method` on a service provided by the host or another plugin.
  /// Failures come back as `{"error": "<message>"}`.
  public func call(_ service: String, _ method: String, _ args: Value = .null) -> Value {
    guard let h = Runtime.host else { return .object([("error", "plugin not applied")]) }
    let encoded = Codec.encode(args)
    return Bytes.borrow(service) { s in
      Bytes.borrow(method) { m in
        Bytes.borrow(encoded) { a in Bytes.take(h.pointee.call(h.pointee.host_ctx, s, m, a)) }
      }
    }
  }

  @discardableResult
  public func on(_ event: String, _ handler: @escaping (Value) -> Void) -> Handle {
    guard let h = Runtime.host else { return 0 }
    let box = EventBox(handler)
    let ud = Unmanaged.passUnretained(box).toOpaque()
    let handle = Bytes.borrow(event) { h.pointee.on(h.pointee.host_ctx, $0, eventTrampoline, ud) }
    return Runtime.keep(box, handle)
  }

  public func emit(_ event: String, _ payload: Value = .null) {
    guard let h = Runtime.host else { return }
    let encoded = Codec.encode(payload)
    Bytes.borrow(event) { e in Bytes.borrow(encoded) { p in h.pointee.emit(h.pointee.host_ctx, e, p) } }
  }

  /// Provides `service`. The handler receives the method name and decoded arguments.
  @discardableResult
  public func provide(_ service: String, _ handler: @escaping (String, Value) -> Value) -> Handle {
    guard let h = Runtime.host else { return 0 }
    let box = ServiceBox(handler)
    let ud = Unmanaged.passUnretained(box).toOpaque()
    let handle = Bytes.borrow(service) { h.pointee.provide(h.pointee.host_ctx, $0, serviceTrampoline, ud) }
    return Runtime.keep(box, handle)
  }

  /// Runs `handler` on the main queue after `milliseconds`, optionally repeating.
  @discardableResult
  public func timer(milliseconds: UInt64, repeats: Bool = false, _ handler: @escaping () -> Void) -> Handle {
    guard let h = Runtime.host else { return 0 }
    let box = TimerBox(handler, repeats: repeats)
    let ud = Unmanaged.passUnretained(box).toOpaque()
    let handle = h.pointee.timer(h.pointee.host_ctx, milliseconds, repeats, timerTrampoline, ud)
    return Runtime.keep(box, handle)
  }

  /// Disposes one registration early.
  public func dispose(_ handle: Handle) {
    guard let h = Runtime.host, handle != 0 else { return }
    h.pointee.dispose(h.pointee.host_ctx, handle)
    Runtime.boxes[handle] = nil
  }
}
