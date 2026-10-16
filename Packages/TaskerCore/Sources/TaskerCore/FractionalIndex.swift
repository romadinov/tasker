import Foundation

/// Fractional indexing over base62 digits. Keys sort lexicographically, never end in "0",
/// and a key strictly between any two keys always exists, so concurrent reorders on two
/// devices never need to renumber siblings.
public enum FractionalIndex {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = 62

    static func value(_ ch: Character) -> Int {
        guard let a = ch.asciiValue else { return 0 }
        switch a {
        case 48...57: return Int(a) - 48
        case 65...90: return Int(a) - 55
        case 97...122: return Int(a) - 61
        default: return 0
        }
    }

    /// A key strictly between `a` and `b` (nil = open end). Requires a < b when both given.
    public static func between(_ a: String?, _ b: String?) -> String {
        let lo = Array(a ?? "")
        let hi = b.map(Array.init)
        if let hi, !(lo.lexicographicallyPrecedes(hi)) {
            // Out-of-order input (e.g. two siblings got the same key concurrently); fall back
            // to "just after a" which is still a valid, deterministic position.
            return String(midpoint(lo, nil))
        }
        return String(midpoint(lo, hi))
    }

    private static func midpoint(_ a: [Character], _ b: [Character]?) -> [Character] {
        if let b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                let aRest = n < a.count ? Array(a[n...]) : []
                return Array(b[0..<n]) + midpoint(aRest, Array(b[n...]))
            }
        }
        let da = a.isEmpty ? 0 : value(a[0])
        let db = b.map { $0.isEmpty ? base : value($0[0]) } ?? base
        if db - da > 1 {
            return [digits[(da + db) / 2]]
        }
        if let b, b.count > 1 {
            return [b[0]]
        }
        return [digits[da]] + midpoint(a.count > 1 ? Array(a[1...]) : [], nil)
    }

    /// `n` short, evenly spaced keys (used for bulk import).
    public static func evenlySpaced(_ n: Int) -> [String] {
        guard n > 0 else { return [] }
        var length = 1
        var capacity = base
        while capacity < (n + 1) * 4 { length += 1; capacity *= base }
        let step = capacity / (n + 1)
        return (1...n).map { i in
            var v = i * step
            var chars = [Character](repeating: "0", count: length)
            for p in stride(from: length - 1, through: 0, by: -1) {
                chars[p] = digits[v % base]; v /= base
            }
            while chars.count > 1 && chars.last == "0" { chars.removeLast() }
            return String(chars)
        }
    }
}
