// The wire between a host and an out-of-process plugin (cordis-plugin-helper): framed CordisValue
// messages over one Unix stream socket. Foundation-free so the helper stays small.
//
// Frame: 4-byte little-endian length, then the CordisValue encoding of an array
// `[kind, seq, fields...]`. Both sides read and write the socket non-blocking: while a side waits to
// write (the peer's buffer is full) it keeps reading, so two sides sending large messages to each
// other at once never deadlock.
//
// Every request carries a sequence number that is unique per sender; the answer is
// `[reply, seq, value]`. While a side waits for an answer it serves the other side's requests, so
// calls can nest in both directions (host -> plugin -> host -> plugin ...).
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import CordisValue

public enum WireKind: Int64, Sendable {
  // helper -> host, once, before anything else: [hello, 0, manifest]
  case hello = 1
  // either way: [reply, seq, value]
  case reply = 2
  // host -> helper requests
  case apply = 3  // [apply, seq] -> rc
  case dispose = 4  // [dispose, seq] -> null
  case service = 5  // [service, seq, token, method, args(bytes)] -> result(bytes)
  case event = 6  // [event, seq, token, payload(bytes)] -> null (the host doesn't wait)
  case timer = 7  // [timer, seq, token] -> null (the host doesn't wait)
  case exit = 8  // [exit, 0]: leave now
  // helper -> host requests
  case call = 10  // [call, seq, service, method, args(bytes)] -> result(bytes)
  case on = 11  // [on, seq, event, token] -> handle
  case provide = 12  // [provide, seq, service, token] -> handle
  case timerAdd = 13  // [timerAdd, seq, ms, repeats, token] -> handle
  // helper -> host, one way (seq 0)
  case emit = 14  // [emit, 0, event, payload(bytes)]
  case log = 15  // [log, 0, level, message]
  case disposeHandle = 16  // [disposeHandle, 0, handle]
}

public enum WireReceive {
  case message([Value])
  case timeout
  case closed
}

public final class WireConnection {
  public let fd: Int32
  private var input: [UInt8] = []
  private var inputStart = 0
  private let chunkSize = 64 * 1024
  private let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
  public private(set) var isClosed = false

  public init(fd: Int32) {
    self.fd = fd
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var size: Int32 = 1 << 20
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    #if canImport(Darwin)
      var one: Int32 = 1
      _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
  }

  deinit { chunk.deallocate() }

  public func close() {
    guard !isClosed else { return }
    isClosed = true
    _ = Darwin.close(fd)
  }

  /// A connected socket pair: [0] for the host, [1] for the helper.
  public static func pair() -> (Int32, Int32)? {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
    return (fds[0], fds[1])
  }

  // MARK: Sending

  /// Sends one message. Returns false when the peer is gone.
  @discardableResult
  public func send(_ fields: [Value]) -> Bool {
    let v = Value.array(fields)
    let n = Codec.encodedSize(v)
    var frame = [UInt8](repeating: 0, count: 4 + n)
    frame[0] = UInt8(truncatingIfNeeded: n)
    frame[1] = UInt8(truncatingIfNeeded: n >> 8)
    frame[2] = UInt8(truncatingIfNeeded: n >> 16)
    frame[3] = UInt8(truncatingIfNeeded: n >> 24)
    frame.withUnsafeMutableBufferPointer { _ = Codec.encode(v, into: $0.baseAddress! + 4) }
    return writeAll(frame)
  }

  private func writeAll(_ bytes: [UInt8]) -> Bool {
    guard !isClosed else { return false }
    var offset = 0
    while offset < bytes.count {
      let w = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
      if w > 0 {
        offset += w
        continue
      }
      if w < 0 && errno == EINTR { continue }
      if w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        // The peer's buffer is full: keep reading what it sends while waiting, so it can drain.
        var p = pollfd(fd: fd, events: Int16(POLLOUT | POLLIN), revents: 0)
        _ = poll(&p, 1, -1)
        if p.revents & Int16(POLLIN) != 0 && !fill() { return false }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && p.revents & Int16(POLLOUT) == 0 { return false }
        continue
      }
      return false
    }
    return true
  }

  // MARK: Receiving

  /// Reads whatever is available into the buffer. False when the peer closed or errored.
  private func fill() -> Bool {
    let chunk = self.chunk
    while true {
      let r = read(fd, chunk, chunkSize)
      if r > 0 {
        if inputStart > 0 && inputStart == input.count {
          input.removeAll(keepingCapacity: true)
          inputStart = 0
        }
        input.append(contentsOf: UnsafeBufferPointer(start: chunk, count: r))
        if r < chunkSize { return true }
        continue
      }
      if r == 0 { return false }
      if errno == EINTR { continue }
      return errno == EAGAIN || errno == EWOULDBLOCK
    }
  }

  /// A complete buffered message, if there is one.
  private func next() -> [Value]? {
    let available = input.count - inputStart
    guard available >= 4 else { return nil }
    let s = inputStart
    let n = Int(input[s]) | Int(input[s + 1]) << 8 | Int(input[s + 2]) << 16 | Int(input[s + 3]) << 24
    guard available >= 4 + n else { return nil }
    let v = input.withUnsafeBytes { Codec.decode(UnsafeRawBufferPointer(rebasing: $0[(s + 4)..<(s + 4 + n)])) }
    inputStart += 4 + n
    if inputStart == input.count {
      input.removeAll(keepingCapacity: true)
      inputStart = 0
    } else if inputStart > 1 << 20 {
      input.removeFirst(inputStart)
      inputStart = 0
    }
    return v?.array ?? []
  }

  /// The next message, waiting up to `timeoutMs` (-1: forever, 0: don't wait).
  public func receive(timeoutMs: Int32) -> WireReceive {
    if let m = next() { return .message(m) }
    if isClosed { return .closed }
    var deadline: UInt64 = 0
    if timeoutMs > 0 { deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(timeoutMs) * 1_000_000 }
    while true {
      var wait = timeoutMs
      if timeoutMs > 0 {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if now >= deadline { return .timeout }
        wait = Int32(max(1, (deadline - now) / 1_000_000))
      }
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let r = poll(&p, 1, wait)
      if r < 0 && errno == EINTR { continue }
      if r == 0 { return .timeout }
      if !fill() {
        if let m = next() { return .message(m) }
        return .closed
      }
      if let m = next() { return .message(m) }
      if timeoutMs == 0 { return .timeout }
    }
  }
}

extension Value {
  /// Wraps an already-encoded value (passed through without decoding).
  public static func encoded(_ bytes: UnsafeRawBufferPointer) -> Value { .bytes(Array(bytes)) }
}
