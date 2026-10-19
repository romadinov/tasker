import Foundation
import Synchronization

/// Fuzzy matching for projects and tags (fzf-style, typo- and layout-tolerant).
///
/// - Letters of the query must appear in order (subsequence), anywhere in the candidate.
///   Word starts, consecutive runs and early matches score higher.
/// - Typos: for 3+ letters one query letter may be missing/wrong, for 6+ letters two.
/// - Keyboard layout: a query typed in the wrong layout (EN ⇄ RU ЙЦУКЕН) also matches.
public enum Fuzzy {
    /// Higher is better; nil = no match.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = normalize(query).filter { !$0.isWhitespace }
        guard !q.isEmpty else { return 0 }
        let c = normalize(candidate)
        let direct = match(q, c)
        // Wrong-layout reading is a fallback: it must clearly beat the query as typed
        // ("нт" must not prefer "d-yn-amic" over "Новые тулы").
        var best = direct
        for alt in layoutVariants(q) {
            if let s = match(alt, c) { best = max(best ?? .min, s - 60) }
        }
        return best
    }

    /// Sorts items by fuzzy score (stable for equal scores), dropping non-matches.
    public static func rank<T>(_ items: [T], _ query: String, text: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        let scored = items.enumerated()
            .compactMap { i, t in score(query, text(t)).map { (s: $0, i: i, t: t) } }
            .sorted { $0.s != $1.s ? $0.s > $1.s : $0.i < $1.i }
        // Typo-tolerant matches score below zero; show them only when real matches are scarce.
        let real = scored.filter { $0.s >= 0 }
        return (real.count >= 3 ? real : scored).map(\.t)
    }

    static func normalize(_ s: String) -> [Character] {
        if let hit = cache.withLock({ $0[s] }) { return hit }
        let v = Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е"))
        cache.withLock { c in
            if c.count > 5000 { c.removeAll(keepingCapacity: true) }
            c[s] = v
        }
        return v
    }

    /// Normalised candidate strings are reused across keystrokes (project/tag names rarely change).
    private static let cache = Mutex<[String: [Character]]>([:])

    private static func match(_ q: [Character], _ c: [Character]) -> Int? {
        let k = q.count >= 6 ? 2 : (q.count >= 3 ? 1 : 0)
        // Cheap rejection: too many query letters don't occur in the candidate at all.
        let present = Set(c)
        if q.reduce(0, { $0 + (present.contains($1) ? 0 : 1) }) > k { return nil }
        if let s = subsequence(q, c) { return s + exactBonus(q, c) }
        // Typo tolerance in one O(m·n) pass: the longest in-order run of query letters found in the
        // candidate. Up to 1 letter may be missing for 3+ letters, 2 for 6+. Scored far below real
        // matches, so they only fill the list when nothing matches properly.
        guard k > 0 else { return nil }
        let found = lcs(q, c)
        let missing = q.count - found
        guard missing <= k else { return nil }
        return found * 4 - missing * 40 - 60
    }

    /// Length of the longest common subsequence (rolling single row).
    private static func lcs(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var prevDiag = 0
            for j in 1...b.count {
                let saved = row[j]
                row[j] = x == b[j - 1] ? prevDiag + 1 : max(row[j], row[j - 1])
                prevDiag = saved
            }
        }
        return row[b.count]
    }

    private static func exactBonus(_ q: [Character], _ c: [Character]) -> Int {
        let qs = String(q), cs = String(c)
        if cs.hasPrefix(qs) { return 60 }
        if cs.contains(qs) { return 35 }
        return 0
    }

    /// Best-scoring placement of q as a subsequence of c (DP over positions).
    private static func subsequence(_ q: [Character], _ c: [Character]) -> Int? {
        let n = c.count, m = q.count
        guard m > 0, m <= n else { return m == 0 ? 0 : nil }
        func isWordStart(_ j: Int) -> Bool {
            j == 0 || !(c[j - 1].isLetter || c[j - 1].isNumber) || (c[j].isUppercase && c[j - 1].isLowercase)
        }
        let neg = Int.min / 4
        // prev[j]: best score with q[i-1] matched at c[j]
        var prev = [Int](repeating: neg, count: n)
        for j in 0..<n where c[j] == q[0] {
            prev[j] = 10 + (isWordStart(j) ? 12 : 0) - min(j, 20) / 2
        }
        if m == 1 { return prev.max().flatMap { $0 > neg ? $0 : nil } }
        for i in 1..<m {
            var cur = [Int](repeating: neg, count: n)
            var runningMax = neg // best prev[k] for k < j-1
            for j in 1..<n {
                if j >= 2 { runningMax = max(runningMax, prev[j - 2]) }
                guard c[j] == q[i] else { continue }
                let base = 10 + (isWordStart(j) ? 12 : 0)
                let consecutive = prev[j - 1] > neg ? prev[j - 1] + base + 8 : neg
                let gapped = runningMax > neg ? runningMax + base - 2 : neg
                cur[j] = max(consecutive, gapped)
            }
            prev = cur
        }
        let best = prev.max() ?? neg
        return best > neg ? best - n / 8 : nil
    }

    /// On the Russian layout the ":" key types "Ж". If a "ж"/"Ж" directly follows a known folder
    /// name ("СамообразованиеЖ"), read it as the "Folder : Project" separator.
    public static func layoutColon(_ query: String, folderNames: [String]) -> String {
        guard !query.contains(":"), query.contains(where: { $0 == "ж" || $0 == "Ж" }) else { return query }
        let folders = folderNames.map { String(normalize($0)) }
        let chars = Array(query)
        for (i, ch) in chars.enumerated() where (ch == "ж" || ch == "Ж") && i > 0 {
            let before = String(normalize(String(chars[..<i]))).trimmingCharacters(in: .whitespaces)
            // the last path segment before the Ж must be (the start of) a folder name
            let lastSegment = before.split(separator: ":").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? before
            if !lastSegment.isEmpty, folders.contains(where: { $0.hasPrefix(lastSegment) }) {
                var out = chars; out[i] = ":"
                return layoutColon(String(out), folderNames: folderNames) // handles nested folders too
            }
        }
        return query
    }

    /// The query plus its wrong-layout conversions ("ubnfhf" → "гитара", "руддщ" → "hello").
    public static func layoutAlternatives(_ query: String) -> [String] {
        let q = Array(query.lowercased())
        return [query.lowercased()] + layoutVariants(q).map { String($0) }
    }

    /// Plain search: every word of the query occurs in the text, in either keyboard layout.
    public static func containsAllWords(_ query: String, in text: String) -> Bool {
        // Each word may be in either layout on its own (you switched layout mid-query).
        let hay = String(normalize(text))
        let words = query.split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy { word in
            layoutAlternatives(word).contains { hay.contains(String(normalize($0))) }
        }
    }

    /// Character offsets in `candidate` to highlight for `query` (best effort, for display):
    /// each query letter goes to the next word start that has it, else the next occurrence.
    /// Tries the wrong-layout conversions too; letters that can't be placed are skipped (typos).
    public static func matchPositions(_ query: String, _ candidate: String) -> [Int] {
        let c = normalize(candidate)
        func place(_ q: [Character]) -> [Int] {
            var out: [Int] = []
            var from = 0
            for ch in q where !ch.isWhitespace {
                var hit: Int?
                var j = from
                while j < c.count {
                    if c[j] == ch && (j == 0 || !(c[j - 1].isLetter || c[j - 1].isNumber)) { hit = j; break }
                    j += 1
                }
                if hit == nil { hit = c[from...].firstIndex(of: ch) }
                if let h = hit { out.append(h); from = h + 1 }
            }
            return out
        }
        let q = normalize(query)
        var best = place(q)
        for alt in layoutVariants(q) { let p = place(alt); if p.count > best.count { best = p } }
        // Prefer a contiguous substring hit when there is one.
        if let r = String(c).range(of: String(q)), !q.isEmpty {
            let start = String(c).distance(from: String(c).startIndex, to: r.lowerBound)
            best = Array(start..<(start + q.count))
        }
        return best
    }

    // MARK: Keyboard layouts

    private static let en = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,.")
    private static let ru = Array("ёйцукенгшщзхъфывапролджэячсмитьбю")
    private static let enToRu: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(en, ru))
    private static let ruToEn: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(ru, en))

    static func layoutVariants(_ q: [Character]) -> [[Character]] {
        var out: [[Character]] = []
        let toRu = q.map { enToRu[$0] ?? $0 }
        let toEn = q.map { ruToEn[$0] ?? $0 }
        if toRu != q { out.append(toRu) }
        if toEn != q { out.append(toEn) }
        return out
    }
}
