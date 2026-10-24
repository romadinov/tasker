import Foundation

/// `tasker://add?…` — lets other apps (e.g. Scriptorium) send an item to Uberdoer.
///
///     tasker://add?title=Chapter%203%20notes&url=scriptorium://open?doc=…&note=…&project=Reading&tags=Books,Mac
///                 &flagged=1&due=fri&defer=tomorrow&quick=1&x-success=scriptorium://
///
/// - `title` (required unless `note`/`url` given), `note`, `url` (put first in the note, as a link)
/// - `project`: "Folder : Project" or a fuzzy name; `tags`: comma-separated names
/// - `flagged`: 1/true; `due`, `defer`, `planned`: ISO 8601 or natural ("fri", "+3d")
/// - `quick=1`: save straight to Uberdoer without showing Quick Entry
/// - `x-success`: URL opened after a quick save (return to the calling app), with `id=<task id>` added
/// - `external_ref`: caller's stable id; with `quick=1` an existing item with it is reused (no duplicate)
/// - `parent`: put it inside this action/project id (nested item)
public struct AddRequest: Equatable, Sendable {
    public var title = ""
    public var note = ""
    public var url: String?
    public var project: String?
    public var tags: [String] = []
    public var flagged = false
    public var due: String?
    public var deferDate: String?
    public var planned: String?
    public var quick = false
    public var xSuccess: URL?
    public var externalRef: String?
    public var parent: String?

    public init?(url: URL) {
        guard ["uberdoer", "throughline", "tasker"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == "add" || url.path.lowercased() == "/add" || url.path.lowercased() == "add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ k: String) -> String? {
            items.first { $0.name.lowercased() == k }?.value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        title = value("title") ?? value("name") ?? ""
        note = value("note") ?? value("text") ?? ""
        self.url = value("url") ?? value("link")
        project = value("project")
        tags = (value("tags") ?? value("tag") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        flagged = ["1", "true", "yes"].contains(value("flagged")?.lowercased() ?? "")
        due = value("due"); deferDate = value("defer"); planned = value("planned")
        quick = ["1", "true", "yes"].contains(value("quick")?.lowercased() ?? "")
        xSuccess = value("x-success").flatMap(URL.init(string:))
        externalRef = value("external_ref") ?? value("externalref")
        parent = value("parent")
        guard !title.isEmpty || !note.isEmpty || self.url != nil else { return nil }
    }

    /// `x-success` with the created/reused task's id added as `id=…`, so the caller can store it.
    public func successURL(id: String?) -> URL? {
        guard let x = xSuccess else { return nil }
        guard let id, var c = URLComponents(url: x, resolvingAgainstBaseURL: false) else { return x }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "id", value: id)]
        return c.url ?? x
    }

    /// Note as stored: the link first (so it's the first visible line), then the text.
    public var fullNote: String { [url, note.isEmpty ? nil : note].compactMap { $0 }.joined(separator: "\n\n") }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Finds links in note text: web links via NSDataDetector, plus app links with custom schemes
/// (scriptorium://, message://, things:///…) that the data detector doesn't report.
public enum Links {
    static let custom = try! NSRegularExpression(pattern: #"\b[a-zA-Z][a-zA-Z0-9+.\-]{1,30}://[^\s<>"]+"#)

    public static func find(in s: String) -> [(range: Range<String.Index>, url: URL)] {
        var out: [(Range<String.Index>, URL)] = []
        let ns = NSRange(s.startIndex..., in: s)
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in det.matches(in: s, range: ns) {
                if let u = m.url, let r = Range(m.range, in: s) { out.append((r, u)) }
            }
        }
        for m in custom.matches(in: s, range: ns) {
            guard let r = Range(m.range, in: s) else { continue }
            if out.contains(where: { $0.0.overlaps(r) }) { continue }
            var text = String(s[r])
            while let last = text.last, ".,;:)]>".contains(last) { text.removeLast() }
            if let u = URL(string: text), let rr = s.range(of: text, range: r) { out.append((rr, u)) }
        }
        return out.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }
}
