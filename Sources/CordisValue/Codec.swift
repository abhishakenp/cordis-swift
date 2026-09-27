// Binary encoding of Value. Little-endian, no Foundation.
//
// tag 0 null | 1 false | 2 true | 3 int: i64 | 4 double: f64 bits
// 5 string: u32 length + UTF-8 | 6 bytes: u32 length + raw
// 7 array: u32 count + values | 8 object: u32 count + (u32 key length + UTF-8 key, value)*

public enum Codec {
  public static func encode(_ value: Value) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(64)
    write(value, into: &out)
    return out
  }

  public static func decode(_ bytes: [UInt8]) -> Value? {
    var i = 0
    guard let v = read(bytes, &i), i == bytes.count else { return nil }
    return v
  }

  public static func decode(_ ptr: UnsafeRawBufferPointer) -> Value? {
    decode(Array(ptr.bindMemory(to: UInt8.self)))
  }

  private static func writeU32(_ v: UInt32, _ out: inout [UInt8]) {
    out.append(UInt8(truncatingIfNeeded: v))
    out.append(UInt8(truncatingIfNeeded: v >> 8))
    out.append(UInt8(truncatingIfNeeded: v >> 16))
    out.append(UInt8(truncatingIfNeeded: v >> 24))
  }

  private static func writeU64(_ v: UInt64, _ out: inout [UInt8]) {
    var x = v
    for _ in 0..<8 {
      out.append(UInt8(truncatingIfNeeded: x))
      x >>= 8
    }
  }

  private static func writeString(_ s: String, _ out: inout [UInt8]) {
    let utf8 = Array(s.utf8)
    writeU32(UInt32(utf8.count), &out)
    out.append(contentsOf: utf8)
  }

  private static func write(_ value: Value, into out: inout [UInt8]) {
    switch value {
    case .null: out.append(0)
    case let .bool(b): out.append(b ? 2 : 1)
    case let .int(i): out.append(3); writeU64(UInt64(bitPattern: i), &out)
    case let .double(d): out.append(4); writeU64(d.bitPattern, &out)
    case let .string(s): out.append(5); writeString(s, &out)
    case let .bytes(b): out.append(6); writeU32(UInt32(b.count), &out); out.append(contentsOf: b)
    case let .array(items):
      out.append(7); writeU32(UInt32(items.count), &out)
      for item in items { write(item, into: &out) }
    case let .object(pairs):
      out.append(8); writeU32(UInt32(pairs.count), &out)
      for (k, v) in pairs { writeString(k, &out); write(v, into: &out) }
    }
  }

  private static func readU32(_ b: [UInt8], _ i: inout Int) -> UInt32? {
    guard i + 4 <= b.count else { return nil }
    let v = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    i += 4
    return v
  }

  private static func readU64(_ b: [UInt8], _ i: inout Int) -> UInt64? {
    guard i + 8 <= b.count else { return nil }
    var v: UInt64 = 0
    for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
    i += 8
    return v
  }

  private static func readString(_ b: [UInt8], _ i: inout Int) -> String? {
    guard let n = readU32(b, &i), i + Int(n) <= b.count else { return nil }
    let s = String(decoding: b[i..<(i + Int(n))], as: UTF8.self)
    i += Int(n)
    return s
  }

  private static func read(_ b: [UInt8], _ i: inout Int) -> Value? {
    guard i < b.count else { return nil }
    let tag = b[i]
    i += 1
    switch tag {
    case 0: return .null
    case 1: return .bool(false)
    case 2: return .bool(true)
    case 3: return readU64(b, &i).map { .int(Int64(bitPattern: $0)) }
    case 4: return readU64(b, &i).map { .double(Double(bitPattern: $0)) }
    case 5: return readString(b, &i).map { .string($0) }
    case 6:
      guard let n = readU32(b, &i), i + Int(n) <= b.count else { return nil }
      let bytes = Array(b[i..<(i + Int(n))])
      i += Int(n)
      return .bytes(bytes)
    case 7:
      guard let n = readU32(b, &i) else { return nil }
      var items: [Value] = []
      for _ in 0..<n {
        guard let v = read(b, &i) else { return nil }
        items.append(v)
      }
      return .array(items)
    case 8:
      guard let n = readU32(b, &i) else { return nil }
      var pairs: [(String, Value)] = []
      for _ in 0..<n {
        guard let k = readString(b, &i), let v = read(b, &i) else { return nil }
        pairs.append((k, v))
      }
      return .object(pairs)
    default: return nil
    }
  }
}
