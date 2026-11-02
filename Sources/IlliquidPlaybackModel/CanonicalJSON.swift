import Foundation

/// Deterministic JSON for `Encodable` values, readable by `JSONDecoder`.
///
/// Output is byte-identical across processes for equal values. Object keys are
/// sorted by UTF-8 bytes. `Set` elements and the key/value pairs of
/// dictionaries encoded as arrays (non-`String`/`Int` keys) are sorted by
/// their own canonical bytes, so hash-seeded iteration order never reaches
/// evidence. Every other array keeps its order. Strings and object keys are
/// written in Unicode NFC, so canonically equivalent strings (equal in Swift)
/// produce equal bytes, and negative zero is written as zero; both decode to
/// values equal to the originals. Non-finite floating-point values are
/// rejected rather than given a lossy spelling.
public enum CanonicalJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
    Array(try encodeValue(value).rendered.utf8)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
    try JSONDecoder().decode(type, from: Data(bytes))
  }

  static func encodeValue<T: Encodable>(_ value: T) throws -> Node {
    let encoder = CanonicalEncoder(codingPath: [])
    try value.encode(to: encoder)
    var node = encoder.root.finish()
    if value is any CanonicalUnorderedElements, case .array(let elements) = node {
      node = .array(elements.sorted { $0.rendered.utf8.lexicographicallyPrecedes($1.rendered.utf8) })
    } else if value is any CanonicalUnorderedPairs, case .array(let elements) = node {
      guard elements.count.isMultiple(of: 2) else {
        throw EncodingError.invalidValue(
          value, .init(codingPath: [], debugDescription: "unpaired dictionary encoding"))
      }
      let pairs = stride(from: 0, to: elements.count, by: 2).map { (elements[$0], elements[$0 + 1]) }
      node = .array(
        pairs.sorted { $0.0.rendered.utf8.lexicographicallyPrecedes($1.0.rendered.utf8) }
          .flatMap { [$0.0, $0.1] })
    }
    return node
  }

  indirect enum Node {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([Node])
    case object([String: Node])

    var rendered: String {
      switch self {
      case .null: return "null"
      case .bool(let value): return value ? "true" : "false"
      case .number(let value): return value
      case .string(let value): return Self.quote(value.precomposedStringWithCanonicalMapping)
      case .array(let values): return "[" + values.map(\.rendered).joined(separator: ",") + "]"
      case .object(let fields):
        let normalized = Dictionary(
          fields.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value.rendered) },
          uniquingKeysWith: { first, _ in first })
        let keys = normalized.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return "{" + keys.map { Self.quote($0) + ":" + normalized[$0]! }
          .joined(separator: ",") + "}"
      }
    }

    static func quote(_ text: String) -> String {
      var result = "\""
      for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case _ where scalar.value < 0x20:
          result += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count)
            + String(scalar.value, radix: 16)
        default: result.unicodeScalars.append(scalar)
        }
      }
      return result + "\""
    }
  }
}

/// Encodes as an array whose element order carries no meaning.
protocol CanonicalUnorderedElements {}
/// Encodes, when not as an object, as a flat key/value array without meaningful order.
protocol CanonicalUnorderedPairs {}
extension Set: CanonicalUnorderedElements {}
extension Dictionary: CanonicalUnorderedPairs {}

private final class Slot {
  enum Content {
    case empty
    case value(CanonicalJSON.Node)
    case array([Slot])
    case object([String: Slot])
  }
  var content: Content = .empty

  func finish() -> CanonicalJSON.Node {
    switch content {
    case .empty: return .object([:])
    case .value(let node): return node
    case .array(let slots): return .array(slots.map { $0.finish() })
    case .object(let slots): return .object(slots.mapValues { $0.finish() })
    }
  }

  func makeObject() {
    if case .object = content { return }
    content = .object([:])
  }

  func makeArray() {
    if case .array = content { return }
    content = .array([])
  }

  func child(_ key: String) -> Slot {
    makeObject()
    guard case .object(var slots) = content else { fatalError("unreachable") }
    if let existing = slots[key] { return existing }
    let slot = Slot()
    slots[key] = slot
    content = .object(slots)
    return slot
  }

  func append() -> Slot {
    makeArray()
    guard case .array(var slots) = content else { fatalError("unreachable") }
    let slot = Slot()
    slots.append(slot)
    content = .array(slots)
    return slot
  }

  var arrayCount: Int {
    if case .array(let slots) = content { return slots.count }
    return 0
  }
}

private struct IndexKey: CodingKey {
  let intValue: Int?
  let stringValue: String
  init(_ index: Int) { intValue = index; stringValue = String(index) }
  init?(stringValue: String) { self.stringValue = stringValue; intValue = Int(stringValue) }
  init?(intValue: Int) { self.init(intValue) }
}

private final class CanonicalEncoder: Encoder {
  let codingPath: [any CodingKey]
  let userInfo: [CodingUserInfoKey: Any] = [:]
  let root: Slot

  init(codingPath: [any CodingKey], root: Slot = Slot()) {
    self.codingPath = codingPath
    self.root = root
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    root.makeObject()
    return KeyedEncodingContainer(Keyed<Key>(slot: root, codingPath: codingPath))
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    root.makeArray()
    return Unkeyed(slot: root, codingPath: codingPath)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    Single(slot: root, codingPath: codingPath)
  }
}

private func node<T: Encodable>(_ value: T, path: [any CodingKey]) throws -> CanonicalJSON.Node {
  switch value {
  case let value as String: return .string(value)
  case let value as Bool: return .bool(value)
  case let value as Double:
    guard value.isFinite else {
      throw EncodingError.invalidValue(value, .init(codingPath: path, debugDescription: "non-finite"))
    }
    return .number(value == 0 ? "0.0" : "\(value)")
  case let value as Float:
    guard value.isFinite else {
      throw EncodingError.invalidValue(value, .init(codingPath: path, debugDescription: "non-finite"))
    }
    return .number(value == 0 ? "0.0" : "\(value)")
  case let value as any BinaryInteger: return .number("\(value)")
  default: return try CanonicalJSON.encodeValue(value)
  }
}

private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let slot: Slot
  let codingPath: [any CodingKey]

  mutating func encodeNil(forKey key: Key) throws { slot.child(key.stringValue).content = .value(.null) }
  mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    slot.child(key.stringValue).content = .value(try node(value, path: codingPath + [key]))
  }
  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type, forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let child = slot.child(key.stringValue)
    child.makeObject()
    return KeyedEncodingContainer(Keyed<NestedKey>(slot: child, codingPath: codingPath + [key]))
  }
  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    let child = slot.child(key.stringValue)
    child.makeArray()
    return Unkeyed(slot: child, codingPath: codingPath + [key])
  }
  mutating func superEncoder() -> any Encoder {
    CanonicalEncoder(codingPath: codingPath, root: slot.child("super"))
  }
  mutating func superEncoder(forKey key: Key) -> any Encoder {
    CanonicalEncoder(codingPath: codingPath + [key], root: slot.child(key.stringValue))
  }
}

private struct Unkeyed: UnkeyedEncodingContainer {
  let slot: Slot
  let codingPath: [any CodingKey]
  var count: Int { slot.arrayCount }

  mutating func encodeNil() throws { slot.append().content = .value(.null) }
  mutating func encode<T: Encodable>(_ value: T) throws {
    let path = codingPath + [IndexKey(count)]
    slot.append().content = .value(try node(value, path: path))
  }
  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> {
    let path = codingPath + [IndexKey(count)]
    let child = slot.append()
    child.makeObject()
    return KeyedEncodingContainer(Keyed<NestedKey>(slot: child, codingPath: path))
  }
  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    let path = codingPath + [IndexKey(count)]
    let child = slot.append()
    child.makeArray()
    return Unkeyed(slot: child, codingPath: path)
  }
  mutating func superEncoder() -> any Encoder {
    let path = codingPath + [IndexKey(count)]
    return CanonicalEncoder(codingPath: path, root: slot.append())
  }
}

private struct Single: SingleValueEncodingContainer {
  let slot: Slot
  let codingPath: [any CodingKey]

  mutating func encodeNil() throws { slot.content = .value(.null) }
  mutating func encode<T: Encodable>(_ value: T) throws {
    slot.content = .value(try node(value, path: codingPath))
  }
}
