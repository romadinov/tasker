import Foundation

/// Serialises a run of ops for one CloudKit record. Pure and testable.
public enum OpBatchCodec {
    public static let recordType = "OpBatch"
    public static let headType = "Head"
    /// Payloads above this go into a CKAsset instead of an inline bytes field (record limit is 1 MB).
    public static let inlineLimit = 600_000

    public static func recordName(replica: String, first: Int64, last: Int64) -> String {
        "b_\(replica)_\(first)_\(last)"
    }

    public static func parseRecordName(_ name: String) -> (replica: String, first: Int64, last: Int64)? {
        let parts = name.split(separator: "_")
        guard parts.count >= 4, parts[0] == "b", let last = Int64(parts[parts.count - 1]), let first = Int64(parts[parts.count - 2]) else { return nil }
        let replica = parts[1..<(parts.count - 2)].joined(separator: "_")
        return (replica, first, last)
    }

    public static func headName(replica: String) -> String { "h_\(replica)" }

    public static func encode(_ ops: [Op]) throws -> Data {
        let raw = try JSONEncoder().encode(ops)
        return try (raw as NSData).compressed(using: .lzfse) as Data
    }

    public static func decode(_ data: Data) throws -> [Op] {
        let raw = try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode([Op].self, from: raw)
    }
}
