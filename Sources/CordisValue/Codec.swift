// Binary encoding of Value. Little-endian, no Foundation.
//
// tag 0 null | 1 false | 2 true | 3 int: i64 | 4 double: f64 bits
// 5 string: u32 length + UTF-8 | 6 bytes: u32 length + raw
// 7 array: u32 count + values | 8 object: u32 count + (u32 key length + UTF-8 key, value)*
//
// Encoding is two-pass (size, then write into one exact allocation) and decoding reads straight
// from the caller's memory, so a call across the plugin boundary copies each payload once.

public enum Codec {
  public static func encode(_ value: Value) -> [UInt8] {
    let n = encodedSize(value)
    return [UInt8](unsafeUninitializedCapacity: n) { buf, count in
      count = encode(value, into: buf.baseAddress!)
    }
  }

  /// Exact number of bytes `encode(_:into:)` will write.
  public static func encodedSize(_ value: Value) -> Int {
    switch value {
    case .null, .bool: return 1
    case .int, .double: return 9
    case let .string(s): return 5 + s.utf8.count
    case let .bytes(b): return 5 + b.count
    case let .array(items):
      var n = 5
      for item in items { n += encodedSize(item) }
      return n
    case let .object(pairs):
      var n = 5
      for (k, v) in pairs { n += 4 + k.utf8.count + encodedSize(v) }
      return n
    }
  }

  /// Writes the encoding of `value` to `out`, which must hold `encodedSize(value)` bytes.
  /// Returns the number of bytes written.
  @discardableResult
  public static func encode(_ value: Value, into out: UnsafeMutablePointer<UInt8>) -> Int {
    var w = Writer(p: out, i: 0)
    w.write(value)
    return w.i
  }

  public static func decode(_ bytes: [UInt8]) -> Value? {
    bytes.withUnsafeBytes { decode($0) }
  }

  public static func decode(_ ptr: UnsafeRawBufferPointer) -> Value? {
    guard let base = ptr.baseAddress else { return nil }
    var r = Reader(p: base.assumingMemoryBound(to: UInt8.self), n: ptr.count, i: 0)
    guard let v = r.read(), r.i == r.n else { return nil }
    return v
  }

  private struct Writer {
    let p: UnsafeMutablePointer<UInt8>
    var i: Int

    @inline(__always) mutating func byte(_ b: UInt8) {
      p[i] = b
      i += 1
    }

    mutating func u32(_ v: UInt32) {
      byte(UInt8(truncatingIfNeeded: v))
      byte(UInt8(truncatingIfNeeded: v >> 8))
      byte(UInt8(truncatingIfNeeded: v >> 16))
      byte(UInt8(truncatingIfNeeded: v >> 24))
    }

    mutating func u64(_ v: UInt64) {
      var x = v
      for _ in 0..<8 {
        byte(UInt8(truncatingIfNeeded: x))
        x >>= 8
      }
    }

    mutating func string(_ s: String) {
      u32(UInt32(s.utf8.count))
      for b in s.utf8 { byte(b) }
    }

    mutating func write(_ value: Value) {
      switch value {
      case .null: byte(0)
      case let .bool(b): byte(b ? 2 : 1)
      case let .int(v): byte(3); u64(UInt64(bitPattern: v))
      case let .double(d): byte(4); u64(d.bitPattern)
      case let .string(s): byte(5); string(s)
      case let .bytes(b):
        byte(6); u32(UInt32(b.count))
        for x in b { byte(x) }
      case let .array(items):
        byte(7); u32(UInt32(items.count))
        for item in items { write(item) }
      case let .object(pairs):
        byte(8); u32(UInt32(pairs.count))
        for (k, v) in pairs { string(k); write(v) }
      }
    }
  }

  private struct Reader {
    let p: UnsafePointer<UInt8>
    let n: Int
    var i: Int

    mutating func u32() -> UInt32? {
      guard i + 4 <= n else { return nil }
      let v = UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
      i += 4
      return v
    }

    mutating func u64() -> UInt64? {
      guard i + 8 <= n else { return nil }
      var v: UInt64 = 0
      for k in 0..<8 { v |= UInt64(p[i + k]) << (8 * UInt64(k)) }
      i += 8
      return v
    }

    mutating func string() -> String? {
      guard let len = u32(), i + Int(len) <= n else { return nil }
      let s = String(decoding: UnsafeBufferPointer(start: p + i, count: Int(len)), as: UTF8.self)
      i += Int(len)
      return s
    }

    mutating func read() -> Value? {
      guard i < n else { return nil }
      let tag = p[i]
      i += 1
      switch tag {
      case 0: return .null
      case 1: return .bool(false)
      case 2: return .bool(true)
      case 3: return u64().map { .int(Int64(bitPattern: $0)) }
      case 4: return u64().map { .double(Double(bitPattern: $0)) }
      case 5: return string().map { .string($0) }
      case 6:
        guard let len = u32(), i + Int(len) <= n else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: p + i, count: Int(len)))
        i += Int(len)
        return .bytes(bytes)
      case 7:
        guard let count = u32(), Int(count) <= n - i else { return nil }  // each value is >= 1 byte
        var items: [Value] = []
        items.reserveCapacity(Int(count))
        for _ in 0..<count {
          guard let v = read() else { return nil }
          items.append(v)
        }
        return .array(items)
      case 8:
        guard let count = u32(), Int(count) <= (n - i) / 5 else { return nil }  // each pair is >= 5 bytes
        var pairs: [(String, Value)] = []
        pairs.reserveCapacity(Int(count))
        for _ in 0..<count {
          guard let k = string(), let v = read() else { return nil }
          pairs.append((k, v))
        }
        return .object(pairs)
      default: return nil
      }
    }
  }
}
