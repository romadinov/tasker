import SwiftUI
import TaskerCore

struct Suggestion: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String?
    var icon: String
}

/// Type-to-filter field with a suggestion list and an "Add new …" row.
/// ↑/↓ move the highlight, Return picks it (or creates when nothing matches), Esc clears.
struct AutocompleteField: View {
    let placeholder: String
    let icon: String
    let suggestions: (String) -> [Suggestion]
    /// e.g. { "New project “\($0)”" }; nil disables creation.
    var createLabel: ((String) -> String)?
    let onPick: (Suggestion) -> Void
    var onCreate: ((String) -> Void)?
    /// Show suggestions even before typing (useful for short lists such as tags).
    var showAllWhenEmpty = false

    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    private var items: [Suggestion] { Array(suggestions(trimmed).prefix(8)) }

    private var canCreate: Bool {
        guard createLabel != nil, onCreate != nil, !trimmed.isEmpty else { return false }
        return !items.contains { $0.title.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private var rowCount: Int { items.count + (canCreate ? 1 : 0) }
    private var showList: Bool { focused && (showAllWhenEmpty || !trimmed.isEmpty) && rowCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                TextField(placeholder, text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: text) { _, _ in highlighted = 0 }
                    .onSubmit(commit)
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(rowCount - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) {
                        if text.isEmpty { return .ignored }
                        text = ""; return .handled
                    }
            }
            if showList {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                        row(index: i) {
                            Label {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(s.title).lineLimit(1)
                                    if let sub = s.subtitle, !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            } icon: { Image(systemName: s.icon) }
                        } action: { pick(s) }
                    }
                    if canCreate, let createLabel {
                        row(index: items.count) {
                            Label(createLabel(trimmed), systemImage: "plus.circle.fill").foregroundStyle(.tint)
                        } action: { create() }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background).shadow(color: .black.opacity(0.12), radius: 6, y: 2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
        }
    }

    private func row<L: View>(index: Int, @ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Color.accentColor.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        if highlighted < items.count, !items.isEmpty { pick(items[highlighted]) }
        else if canCreate { create() }
    }

    private func pick(_ s: Suggestion) {
        onPick(s)
        text = ""
        focused = true
    }

    private func create() {
        onCreate?(trimmed)
        text = ""
        focused = true
    }
}

/// Matching helpers shared by Quick Entry and the inspector.
enum Lookup {
    static func projects(_ s: Snapshot, _ q: String) -> [Suggestion] {
        let remaining = s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true }
        return rank(remaining, q, title: \.title).map {
            Suggestion(id: $0.id, title: $0.title, subtitle: s.path(of: $0.id), icon: $0.singleActions ? "list.bullet.circle" : "circle.grid.2x2")
        }
    }

    static func tags(_ s: Snapshot, _ q: String, excluding: Set<String> = []) -> [Suggestion] {
        let tags = s.orderedTags.map(\.tag).filter { $0.status != .dropped && !excluding.contains($0.id) }
        return rank(tags, q, title: \.name).map { t in
            let parent = t.position.parent.flatMap { s.tags[$0]?.name }
            return Suggestion(id: t.id, title: t.name, subtitle: parent, icon: "tag")
        }
    }

    /// Exact, then prefix, then word-prefix, then substring matches; outline order within each.
    static func rank<T>(_ items: [T], _ q: String, title: KeyPath<T, String>) -> [T] {
        guard !q.isEmpty else { return items }
        let n = q.lowercased()
        func score(_ t: T) -> Int? {
            let s = t[keyPath: title].lowercased()
            if s == n { return 0 }
            if s.hasPrefix(n) { return 1 }
            if s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(n) }) { return 2 }
            if s.contains(n) { return 3 }
            return nil
        }
        return items.enumerated().compactMap { i, t in score(t).map { ($0, i, t) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }
}
