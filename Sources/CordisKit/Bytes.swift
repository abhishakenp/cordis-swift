// Helpers for moving bytes across the C ABI. Foundation-free; compiles as Embedded Swift.

#if !hasFeature(Embedded)
  import CordisValue
#endif
import CCordis

enum Bytes {
  /// Calls `body` with a borrowed `cordis_bytes` view of `array`.
  @inline(__always)
  static func borrow<R>(_ array: [UInt8], _ body: (cordis_bytes) -> R) -> R {
    array.withUnsafeBufferPointer { buf in body(cordis_bytes(data: buf.baseAddress, len: buf.count)) }
  }

  /// Calls `body` with a borrowed UTF-8 view of `string`.
  @inline(__always)
  static func borrow<R>(_ string: String, _ body: (cordis_bytes) -> R) -> R {
    var s = string
    return s.withUTF8 { buf in body(cordis_bytes(data: buf.baseAddress, len: buf.count)) }
  }

  /// Copies `array` into a malloc'd buffer the receiver will free().
  static func owned(_ array: [UInt8]) -> cordis_bytes {
    guard let p = malloc(max(array.count, 1))?.assumingMemoryBound(to: UInt8.self) else {
      return cordis_bytes(data: nil, len: 0)
    }
    array.withUnsafeBufferPointer { buf in
      if let base = buf.baseAddress { p.update(from: base, count: buf.count) }
    }
    return cordis_bytes(data: UnsafePointer(p), len: array.count)
  }

  /// Encodes `value` straight into a malloc'd buffer the receiver will free().
  static func owned(_ value: Value) -> cordis_bytes {
    let n = Codec.encodedSize(value)
    guard let p = malloc(n)?.assumingMemoryBound(to: UInt8.self) else { return cordis_bytes(data: nil, len: 0) }
    Codec.encode(value, into: p)
    return cordis_bytes(data: UnsafePointer(p), len: n)
  }

  static func string(_ b: cordis_bytes) -> String {
    guard let data = b.data, b.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: data, count: b.len), as: UTF8.self)
  }

  static func value(_ b: cordis_bytes) -> Value {
    guard let data = b.data, b.len > 0 else { return .null }
    return Codec.decode(UnsafeRawBufferPointer(start: data, count: b.len)) ?? .null
  }

  /// Decodes a malloc'd buffer received from the host, then frees it.
  static func take(_ b: cordis_bytes) -> Value {
    let v = value(b)
    if let data = b.data { free(UnsafeMutableRawPointer(mutating: data)) }
    return v
  }
}
