import SwiftUI
import TaskerCore
#if os(macOS)
import AppKit
#endif

/// One row in the project dropdown.
struct ComboItem: Identifiable, Hashable {
    let id: String
    let folder: String
    let title: String
    let onHold: Bool
    var createName: String? = nil

    var display: String { folder.isEmpty ? title : "\(folder) : \(title)" }
}

enum ComboKind { case project, tag }

@MainActor @Observable
final class ComboState {
    var query = "" { didSet { refresh() } }
    var items: [ComboItem] = []
    var highlighted = 0
    let kind: ComboKind
    /// Tags already on the item (excluded from the tag list).
    var excluded: Set<String> = []
    @ObservationIgnored let snapshot: () -> Snapshot

    init(kind: ComboKind = .project, snapshot: @escaping () -> Snapshot) { self.kind = kind; self.snapshot = snapshot }

    func refresh() {
        let s = snapshot()
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [ComboItem]
        switch kind {
        case .project:
            out = Lookup.projects(s, q).prefix(40).map { sug in
                ComboItem(id: sug.id, folder: sug.subtitle ?? "", title: sug.title, onHold: s.tasks[sug.id]?.status == .onHold)
            }
            if !q.isEmpty && s.project(atPath: q) == nil {
                out.append(ComboItem(id: "#new", folder: "", title: Lookup.newProjectLabel(q), onHold: false, createName: q))
            }
        case .tag:
            out = Lookup.tags(s, q, excluding: excluded).prefix(40).map { sug in
                ComboItem(id: sug.id, folder: sug.subtitle ?? "", title: sug.title, onHold: s.tags[sug.id]?.status == .onHold)
            }
            if !q.isEmpty && !s.tags.values.contains(where: { $0.name.compare(q, options: .caseInsensitive) == .orderedSame }) {
                out.append(ComboItem(id: "#new", folder: "", title: "New tag “\(q)”", onHold: false, createName: q))
            }
        }
        items = Array(out)
        highlighted = 0
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        highlighted = min(max(highlighted + d, 0), items.count - 1)
    }

    var current: ComboItem? { items.indices.contains(highlighted) ? items[highlighted] : nil }
}

/// Project field for the selected row: click → type → dropdown of
/// "Folder : Project" with typed letters highlighted → Return picks.
struct InlineProjectField: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        let s = model.snapshot
        let projectID = s.info[task.id]?.projectID
        let name = projectID.flatMap { s.tasks[$0]?.title }
        if model.inlineField == .init(id: task.id, field: .project) {
            ProjectComboEditor(task: task, initial: model.projectEditingSeed, onDone: { model.inlineField = nil })
                .frame(minWidth: 180, maxWidth: 260)
        } else {
            Button { model.projectEditingSeed = ""; model.inlineField = .init(id: task.id, field: .project) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "circle.grid.2x2").imageScale(.small)
                    Text(name ?? "Project").lineLimit(1)
                    if name != nil { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
                }
                .font(.caption)
                .foregroundStyle(name == nil ? Color.secondary.opacity(0.7) : Palette.project)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Project — click and type to choose")
        }
    }
}

struct ProjectComboEditor: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let initial: String
    let onDone: () -> Void
    @State private var state: ComboState
    @State private var showList = true

    init(task: TaskItem, initial: String, onDone: @escaping () -> Void) {
        self.task = task; self.initial = initial; self.onDone = onDone
        let s = ComboState { AppModel.shared.snapshot }
        s.query = initial
        _state = State(initialValue: s)
    }

    var body: some View {
        #if os(macOS)
        ComboTextField(state: state, placeholder: "Project", onCommit: { item, _ in commit(item); return false }, onCancel: onDone)
        #else
        TextField("Project", text: Bindable(state).query)
            .textFieldStyle(.roundedBorder)
            .onSubmit { commit(state.current) }
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                ComboList(state: state, onPick: commit)
                    .frame(width: 380)
                    .presentationCompactAdaptation(.popover)
            }
        #endif
    }

    func commit(_ item: ComboItem?) {
        if let item {
            if let name = item.createName {
                model.assignProject([task.id], model.createProject(named: name))
            } else {
                model.assignProject([task.id], item.id)
            }
        }
        // Flow: Project → Tags → Flag.
        model.inlineField = .init(id: task.id, field: .tags)
    }
}

/// Inline tags field: Return adds the highlighted tag and stays for another;
/// Tab (or Return on an empty field) moves on to the flag.
struct InlineTagsField: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @State private var state: ComboState

    init(task: TaskItem) {
        self.task = task
        let s = ComboState(kind: .tag) { AppModel.shared.snapshot }
        s.excluded = Set(task.tagIDs)
        s.refresh()
        _state = State(initialValue: s)
    }

    var body: some View {
        #if os(macOS)
        ComboTextField(state: state, placeholder: "Add tag", onCommit: { item, viaTab in
            if let item { add(item) }
            // Tab → Flag. Return on an empty field = done with this item → next task (Inbox processing).
            if viaTab { model.inlineField = .init(id: task.id, field: .flag); return false }
            if item == nil { model.editNextTask(after: task.id); return false }
            return true // Return with a tag picked: stay for another tag
        }, onCancel: { model.inlineField = nil })
        .frame(minWidth: 140, maxWidth: 220)
        #else
        TextField("Add tag", text: Bindable(state).query)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
            .onSubmit {
                if let item = state.current, !state.query.isEmpty { add(item); state.query = "" }
                else { model.inlineField = nil }
            }
            .popover(isPresented: .constant(!state.query.isEmpty), arrowEdge: .bottom) {
                ComboList(state: state, onPick: { add($0); state.query = "" })
                    .frame(width: 320)
                    .presentationCompactAdaptation(.popover)
            }
        #endif
    }

    func add(_ item: ComboItem) {
        let id = item.createName.map { model.createTag(named: $0) } ?? item.id
        model.perform("Add Tag") { $0.setTag(task.id, id, true) }
        state.excluded.insert(id)
        state.refresh()
    }
}

/// The dropdown list (shared by the Mac panel and the iPad popover).
struct ComboList: View {
    @Bindable var state: ComboState
    let onPick: (ComboItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                        let selected = i == state.highlighted
                        Button { onPick(item) } label: {
                            Text(highlighted(item, selected: selected))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(selected ? Color.accentColor : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                    if state.items.isEmpty {
                        Text("No matching projects").foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            .onChange(of: state.highlighted) { _, i in proxy.scrollTo(i) }
        }
        .font(.system(size: 12))
    }

    func highlighted(_ item: ComboItem, selected: Bool) -> AttributedString {
        if let name = item.createName {
            var a = AttributedString("＋ " + Lookup.newProjectLabel(name))
            a.foregroundColor = selected ? .white : .accentColor
            return a
        }
        let text = item.display
        var a = AttributedString(text)
        a.foregroundColor = selected ? .white : (item.onHold ? .secondary : .primary)
        if !item.folder.isEmpty, let r = a.range(of: item.folder) {
            if !selected { a[r].foregroundColor = item.onHold ? Color.secondary.opacity(0.7) : .secondary }
        }
        // Highlight the typed letters in the project name (yellow tint).
        let titleOffset = text.count - item.title.count
        let positions = Fuzzy.matchPositions(state.query, item.title).map { $0 + titleOffset }
        let chars = Array(text)
        for p in positions where p < chars.count {
            let lower = a.index(a.startIndex, offsetByCharacters: p)
            let upper = a.index(lower, offsetByCharacters: 1)
            if selected {
                a[lower..<upper].underlineStyle = .single
            } else {
                a[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
            }
        }
        return a
    }
}

#if os(macOS)
/// AppKit field that drives the dropdown: ↑/↓ move, Return/Tab pick, Esc cancels.
/// The list lives in a borderless child window under the field, so the table can't clip it.
struct ComboTextField: NSViewRepresentable {
    let state: ComboState
    var placeholder = "Project"
    /// (picked item or nil, pressed Tab) → true to keep the field open for another entry.
    let onCommit: (ComboItem?, Bool) -> Bool
    let onCancel: () -> Void

    func makeNSView(context: Context) -> AutoFocusTextField {
        let f = AutoFocusTextField()
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        f.stringValue = state.query
        context.coordinator.field = f
        DispatchQueue.main.async { context.coordinator.showPanel() }
        return f
    }

    func updateNSView(_ nsView: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: AutoFocusTextField, coordinator: Coordinator) {
        coordinator.hidePanel()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComboTextField
        weak var field: NSTextField?
        var panel: NSPanel?
        var done = false
        var keyMonitor: Any?
        init(_ p: ComboTextField) { parent = p }

        func showPanel() {
            guard let field, let window = field.window else { return }
            let p = DropdownPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.hasShadow = true
            p.isOpaque = false
            p.backgroundColor = .clear
            let host = FirstMouseHostingView(rootView:
                ComboList(state: parent.state, onPick: { [weak self] item in self?.finish(item) })
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            )
            p.contentView = host
            window.addChildWindow(p, ordered: .above)
            panel = p
            position()
            // ⌘↩ creates a new project/tag from the typed text (instead of picking the highlighted match).
            // A local monitor sees it before window key equivalents such as Quick Entry's ⌘↩ = Save.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let f = self.field, let editor = f.currentEditor(), f.window?.firstResponder === editor,
                      [36, 76].contains(e.keyCode),
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return e }
                let q = self.parent.state.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { return e }
                let existing = self.parent.state.items.first { $0.createName == nil && $0.title.compare(q, options: .caseInsensitive) == .orderedSame }
                self.finish(existing ?? ComboItem(id: "#new", folder: "", title: q, onHold: false, createName: q))
                return nil
            }
        }

        func position() {
            guard let field, let window = field.window, let panel else { return }
            let r = window.convertToScreen(field.convert(field.bounds, to: nil))
            let rows = min(max(parent.state.items.count, 1), 8)
            let h = CGFloat(rows) * 21 + 6
            panel.setFrame(NSRect(x: r.minX, y: r.minY - h - 2, width: 460, height: h), display: true)
        }

        func hidePanel() {
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            panel = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        func finish(_ item: ComboItem?, viaTab: Bool = false) {
            guard !done else { return }
            if parent.onCommit(item, viaTab) {
                // Stay open (e.g. add another tag).
                field?.stringValue = ""
                parent.state.query = ""
                position()
                return
            }
            done = true
            hidePanel()
        }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.state.query = f.stringValue
            position()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): parent.state.move(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.state.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                let tab = sel == #selector(NSResponder.insertTab(_:))
                // Empty field: nothing picked, just move on.
                let item = (field?.stringValue.isEmpty ?? true) ? nil : parent.state.current
                finish(item, viaTab: tab)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                done = true; hidePanel(); parent.onCancel(); return true
            default: return false
            }
        }

        func controlTextDidEndEditing(_ n: Notification) {
            // Clicking a row ends editing first; give the click a moment to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !self.done else { return }
                self.done = true
                self.hidePanel()
                self.parent.onCancel()
            }
        }
    }
}

final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
