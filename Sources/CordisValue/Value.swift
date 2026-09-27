// Shared data model for everything that crosses the plugin boundary.
// No Foundation: this file also compiles in Embedded Swift plugins.

public enum Value: Equatable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case bytes([UInt8])
  case array([Value])
  case object([(String, Value)])

  public static func == (lhs: Value, rhs: Value) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): return true
    case let (.bool(a), .bool(b)): return a == b
    case let (.int(a), .int(b)): return a == b
    case let (.double(a), .double(b)): return a == b
    case let (.string(a), .string(b)): return a == b
    case let (.bytes(a), .bytes(b)): return a == b
    case let (.array(a), .array(b)): return a == b
    case let (.object(a), .object(b)):
      guard a.count == b.count else { return false }
      for i in 0..<a.count where a[i].0 != b[i].0 || a[i].1 != b[i].1 { return false }
      return true
    default: return false
    }
  }

  public subscript(key: String) -> Value {
    guard case let .object(pairs) = self else { return .null }
    for (k, v) in pairs where k == key { return v }
    return .null
  }

  public subscript(index: Int) -> Value {
    guard case let .array(items) = self, index >= 0, index < items.count else { return .null }
    return items[index]
  }

  public var string: String? { if case let .string(s) = self { return s } else { return nil } }
  public var int: Int64? { if case let .int(i) = self { return i } else { return nil } }
  public var double: Double? {
    switch self {
    case let .double(d): return d
    case let .int(i): return Double(i)
    default: return nil
    }
  }
  public var bool: Bool? { if case let .bool(b) = self { return b } else { return nil } }
  public var array: [Value]? { if case let .array(a) = self { return a } else { return nil } }
  public var isNull: Bool { if case .null = self { return true } else { return false } }
}

extension Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int64) { self = .int(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(arrayLiteral elements: Value...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, Value)...) { self = .object(elements) }
  public init(nilLiteral: ()) { self = .null }
}
