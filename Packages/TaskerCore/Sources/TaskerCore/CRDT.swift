import Foundation

// MARK: - Hybrid logical clock

/// Hybrid logical clock timestamp. Total order: (ms, c, replica).
/// Wall time keeps "last edit wins" intuitive; the logical counter keeps causality
/// when device clocks disagree; the replica id breaks exact ties deterministically.
public struct HLC: Comparable, Hashable, Sendable, Codable {
    public var ms: Int64
    public var c: Int32
    public var replica: String

    public init(ms: Int64, c: Int32, replica: String) {
        self.ms = ms; self.c = c; self.replica = replica
    }

    public static let zero = HLC(ms: 0, c: 0, replica: "")

    public static func < (a: HLC, b: HLC) -> Bool {
        if a.ms != b.ms { return a.ms < b.ms }
        if a.c != b.c { return a.c < b.c }
        return a.replica < b.replica
    }

    public var date: Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

public struct HLCClock: Sendable {
    public let replica: String
    private(set) var ms: Int64 = 0
    private(set) var c: Int32 = 0

    public init(replica: String) { self.replica = replica }

    public static func wallMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public mutating func tick(now: Int64 = HLCClock.wallMillis()) -> HLC {
        if now > ms { ms = now; c = 0 } else { c &+= 1 }
        return HLC(ms: ms, c: c, replica: replica)
    }

    /// Advance past a timestamp we've seen so our next edit is ordered after it.
    /// Remote time is clamped to one year ahead so a device with a wildly wrong clock
    /// can't drag every replica's clock into the far future.
    public mutating func observe(_ h: HLC, now: Int64 = HLCClock.wallMillis()) {
        let cap = now + 365 * 24 * 3600 * 1000
        let hms = min(h.ms, cap)
        if hms > ms || (hms == ms && h.c > c) { ms = hms; c = h.c }
    }
}

// MARK: - Operations

public enum EntityType: String, Sendable, Codable, CaseIterable {
    case task, folder, tag, perspective, setting
}

public struct EntityKey: Hashable, Sendable {
    public var type: EntityType
    public var id: String
    public init(_ type: EntityType, _ id: String) { self.type = type; self.id = id }
}

/// One field assignment. Ops are immutable and uniquely identified by (replica, counter),
/// so applying them is idempotent, commutative and associative: sync is a set union.
public struct Op: Hashable, Sendable {
    public var replica: String
    public var counter: Int64
    public var hlc: HLC
    public var type: EntityType
    public var id: String
    public var field: String
    public var value: JSON

    public init(replica: String, counter: Int64, hlc: HLC, type: EntityType, id: String, field: String, value: JSON) {
        self.replica = replica; self.counter = counter; self.hlc = hlc
        self.type = type; self.id = id; self.field = field; self.value = value
    }

    public var key: EntityKey { EntityKey(type, id) }
}

/// Compact wire format. The HLC replica always equals the op replica, so it isn't repeated.
extension Op: Codable {
    enum CodingKeys: String, CodingKey { case r, n, t, c, e, i, f, v }

    public init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        replica = try k.decode(String.self, forKey: .r)
        counter = try k.decode(Int64.self, forKey: .n)
        let ms = try k.decode(Int64.self, forKey: .t)
        let c = try k.decode(Int32.self, forKey: .c)
        hlc = HLC(ms: ms, c: c, replica: replica)
        let typeRaw = try k.decode(String.self, forKey: .e)
        guard let t = EntityType(rawValue: typeRaw) else {
            throw DecodingError.dataCorruptedError(forKey: .e, in: k, debugDescription: "Unknown entity type \(typeRaw)")
        }
        type = t
        id = try k.decode(String.self, forKey: .i)
        field = try k.decode(String.self, forKey: .f)
        value = try k.decodeIfPresent(JSON.self, forKey: .v) ?? .null
    }

    public func encode(to encoder: Encoder) throws {
        var k = encoder.container(keyedBy: CodingKeys.self)
        try k.encode(replica, forKey: .r)
        try k.encode(counter, forKey: .n)
        try k.encode(hlc.ms, forKey: .t)
        try k.encode(hlc.c, forKey: .c)
        try k.encode(type.rawValue, forKey: .e)
        try k.encode(id, forKey: .i)
        try k.encode(field, forKey: .f)
        try k.encode(value, forKey: .v)
    }
}

/// Last-writer-wins register.
public struct Register: Hashable, Sendable {
    public var value: JSON
    public var hlc: HLC
    public init(value: JSON, hlc: HLC) { self.value = value; self.hlc = hlc }
}

/// The CRDT state: a map of LWW registers per entity field.
/// Tag membership is a register per (task, tag) pair ("tag:<id>"), i.e. an LWW-element set,
/// so adding one tag on the phone and another on the Mac keeps both.
public struct CRDTState: Sendable {
    public private(set) var entities: [EntityKey: [String: Register]] = [:]

    public init() {}

    /// Returns true if the op changed the visible state.
    @discardableResult
    public mutating func apply(_ op: Op) -> Bool {
        let key = op.key
        if let existing = entities[key]?[op.field], !(existing.hlc < op.hlc) { return false }
        entities[key, default: [:]][op.field] = Register(value: op.value, hlc: op.hlc)
        return true
    }

    public mutating func load(_ key: EntityKey, field: String, register: Register) {
        entities[key, default: [:]][field] = register
    }

    public func fields(_ key: EntityKey) -> [String: Register]? { entities[key] }

    public func value(_ key: EntityKey, _ field: String) -> JSON? { entities[key]?[field]?.value }

    public var maxHLC: HLC {
        var m = HLC.zero
        for (_, fields) in entities { for (_, r) in fields where m < r.hlc { m = r.hlc } }
        return m
    }
}

// MARK: - Identifiers

public enum IDs {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// 11-character base62 random id (≈65 bits).
    public static func make() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<11).map { _ in alphabet[Int(g.next() % 62)] })
    }

    /// Deterministic id derived from a seed. Used when two devices may perform the same
    /// logical action concurrently (e.g. completing one occurrence of a repeating task):
    /// both generate the same id, so the result converges instead of duplicating.
    public static func derived(_ seed: String) -> String {
        // FNV-1a 128-bit spread over two 64-bit lanes; stable across platforms and releases.
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x84222325cbf29ce4
        for b in seed.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = (h2 ^ UInt64(b) ^ (h1 >> 29)) &* 0x100000001b3
        }
        var out = ""
        var x = h1, y = h2
        for i in 0..<11 {
            let v: UInt64
            if i % 2 == 0 { v = x % 62; x /= 62 } else { v = y % 62; y /= 62 }
            out.append(alphabet[Int(v)])
        }
        return out
    }
}
