import Foundation

/// A JSON value. Every CRDT register holds one of these, so the op log stays schema-free:
/// an older build that doesn't know a field still stores, merges and forwards it.
public enum JSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
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

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var date: Date? { double.map { Date(timeIntervalSince1970: $0) } }

    public subscript(key: String) -> JSON? { object?[key] }

    public static func date(_ d: Date?) -> JSON {
        guard let d else { return .null }
        // Whole seconds keep the log compact and make equal edits compare equal.
        return .number(d.timeIntervalSince1970.rounded())
    }
    public static func optional(_ s: String?) -> JSON { s.map(JSON.string) ?? .null }
    public static func optional(_ i: Int?) -> JSON { i.map { .number(Double($0)) } ?? .null }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Canonical text form (sorted keys) used for storage.
    public var text: String {
        // Top-level fragments are allowed by JSONEncoder on all supported OS versions.
        (try? String(decoding: JSON.encoder.encode(self), as: UTF8.self)) ?? "null"
    }

    public init(text: String) {
        self = (try? JSONDecoder().decode(JSON.self, from: Data(text.utf8))) ?? .null
    }

    /// Bridges Codable values into JSON (used for structured fields such as repeat rules).
    public init<T: Encodable>(encoding value: T) {
        self = (try? JSONDecoder().decode(JSON.self, from: JSON.encoder.encode(value))) ?? .null
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard !isNull, let data = try? JSON.encoder.encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(nilLiteral: ()) { self = .null }
}
