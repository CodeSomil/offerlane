import Foundation

/// Coders matching the prototype's on-disk JSON (snake_case keys).
public enum JSONCoding {
    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
    public static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e
    }
}

/// A string field that also accepts numbers and booleans (the prototype stored `years_experience: 4` and
/// `graduation_year: 2022` as numbers) and defaults to "" when missing.
@propertyWrapper
public struct Lenient: Codable, Hashable, Sendable {
    public var wrappedValue: String
    public init(wrappedValue: String = "") { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = "" }
        else if let s = try? c.decode(String.self) { wrappedValue = s }
        else if let i = try? c.decode(Int.self) { wrappedValue = String(i) }
        else if let d = try? c.decode(Double.self) { wrappedValue = d == d.rounded() ? String(Int(d)) : String(d) }
        else if let b = try? c.decode(Bool.self) { wrappedValue = b ? "Yes" : "No" }
        else { wrappedValue = "" }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wrappedValue) }
}

/// A boolean that defaults when missing and accepts "yes"/"true"/1.
@propertyWrapper
public struct LenientBool<Default: BoolDefault>: Codable, Hashable, Sendable {
    public var wrappedValue: Bool
    public init(wrappedValue: Bool = Default.value) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { wrappedValue = b }
        else if let i = try? c.decode(Int.self) { wrappedValue = i != 0 }
        else if let s = try? c.decode(String.self) { wrappedValue = ["yes", "true", "1", "y"].contains(s.lowercased()) }
        else { wrappedValue = Default.value }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wrappedValue) }
}
public protocol BoolDefault: Sendable { static var value: Bool { get } }
public enum DefaultFalse: BoolDefault { public static let value = false }
public enum DefaultTrue: BoolDefault { public static let value = true }

/// An array that defaults to [] when missing or malformed.
@propertyWrapper
public struct LenientArray<T: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: [T]
    public init(wrappedValue: [T] = []) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        wrappedValue = (try? decoder.singleValueContainer().decode([LossyItem<T>].self))?.compactMap(\.value) ?? []
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wrappedValue) }
}
struct LossyItem<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
}

extension KeyedDecodingContainer {
    public func decode(_ t: Lenient.Type, forKey key: Key) throws -> Lenient { try decodeIfPresent(t, forKey: key) ?? Lenient() }
    public func decode<D>(_ t: LenientBool<D>.Type, forKey key: Key) throws -> LenientBool<D> { try decodeIfPresent(t, forKey: key) ?? LenientBool() }
    public func decode<T>(_ t: LenientArray<T>.Type, forKey key: Key) throws -> LenientArray<T> { try decodeIfPresent(t, forKey: key) ?? LenientArray() }
}

/// Untyped JSON for values whose shape the app passes through (plans, raw API payloads).
public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var string: String? {
        switch self { case .string(let s): s; case .number(let n): n == n.rounded() ? String(Int(n)) : String(n); default: nil }
    }
    public var double: Double? { switch self { case .number(let n): n; case .string(let s): Double(s); default: nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}
