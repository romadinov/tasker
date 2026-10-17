import SwiftUI
import TaskerCore

#if os(macOS)
import AppKit

/// AppKit text field for inline row editing on the Mac. SwiftUI's outline list re-takes
/// first responder while it selects and scrolls to a new row, so a SwiftUI focus request
/// is lost; this field makes itself first responder directly once it is in the window.
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var bold = false
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onEndEditing: () -> Void

    func makeNSView(context: Context) -> AutoFocusTextField {
        let f = AutoFocusTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.placeholderString = placeholder
        f.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        f.stringValue = text
        return f
    }

    func updateNSView(_ view: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        if view.stringValue != text && view.currentEditor() == nil { view.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        var finished = false
        init(_ p: InlineTextField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finished = true; parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                finished = true; parent.onCancel(); return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ n: Notification) {
            guard !finished else { return }
            finished = true
            parent.onEndEditing()
        }
    }
}

final class AutoFocusTextField: NSTextField {
    private var focusedOnce = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        for delay in [0.0, 0.05, 0.15, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let window = self.window, !self.focusedOnce else { return }
                if self.currentEditor() != nil { self.focusedOnce = true; return }
                if window.makeFirstResponder(self) {
                    self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.count, length: 0)
                    self.focusedOnce = self.currentEditor() != nil
                }
            }
        }
    }
}
#endif

/// Click-to-edit project chip in a row: popover with project autocomplete and "New project…".
struct ProjectChip: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    var placeholder = false
    @State private var open = false

    var body: some View {
        let s = model.snapshot
        let name = s.info[task.id]?.projectID.flatMap { s.tasks[$0]?.title }
        Button { open = true } label: {
            if let name {
                Badge(text: name, systemImage: "circle.grid.2x2", color: Palette.project)
            } else if placeholder {
                Badge(text: "Project", systemImage: "plus", color: .secondary)
            } else {
                Badge(text: "Inbox", systemImage: "tray")
            }
        }
        .buttonStyle(.plain)
        .help("Change project")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Project").font(.headline)
                AutocompleteField(placeholder: "Find or create a project", icon: "circle.grid.2x2",
                                  suggestions: { Lookup.projects(model.snapshot, $0) },
                                  createLabel: { "New project “\($0)”" },
                                  onPick: { model.assignProject([task.id], $0.id); open = false },
                                  onCreate: { name in model.assignProject([task.id], model.createProject(named: name)); open = false },
                                  showAllWhenEmpty: true)
                if name != nil {
                    Button("Move to Inbox") { model.assignProject([task.id], nil); open = false }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .topLeading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Click-to-edit tags: click a chip (or "+" on the selected row) to add/remove with autocomplete.
struct TagChips: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    var showAdd = false
    @State private var open = false

    var body: some View {
        let s = model.snapshot
        let ids = task.tagIDs.filter { s.tags[$0] != nil }
        HStack(spacing: 4) {
            ForEach(ids, id: \.self) { id in
                Button { open = true } label: { Badge(text: s.tags[id]!.name, color: Palette.tag) }
                    .buttonStyle(.plain)
                    .help("Edit tags")
            }
            if showAdd {
                Button { open = true } label: { Badge(text: ids.isEmpty ? "Tag" : "", systemImage: "plus", color: .secondary) }
                    .buttonStyle(.plain)
                    .help("Add tag")
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags").font(.headline)
                HStack(spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        Button { model.perform("Remove Tag") { $0.setTag(task.id, id, false) } } label: {
                            Badge(text: s.tags[id]!.name, systemImage: "xmark", color: Palette.tag)
                        }
                        .buttonStyle(.plain)
                    }
                }
                AutocompleteField(placeholder: "Find or create a tag", icon: "tag",
                                  suggestions: { Lookup.tags(model.snapshot, $0, excluding: Set(task.tagIDs)) },
                                  createLabel: { "New tag “\($0)”" },
                                  onPick: { tag in model.perform("Add Tag") { $0.setTag(task.id, tag.id, true) } },
                                  onCreate: { name in
                                      let tag = model.createTag(named: name)
                                      model.perform("Add Tag") { $0.setTag(task.id, tag, true) }
                                  },
                                  showAllWhenEmpty: true)
            }
            .padding(12)
            .frame(width: 320, alignment: .topLeading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Flag toggle shown at the trailing edge of every action row.
struct FlagButton: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let effective: Bool

    var body: some View {
        Button { model.toggleFlag([task.id]) } label: {
            Image(systemName: task.flagged ? "flag.fill" : "flag")
                .foregroundStyle(task.flagged ? Palette.flag : (effective ? Palette.flag.opacity(0.5) : Color.secondary.opacity(0.35)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.flagged ? "Unflag (F)" : "Flag (F)")
    }
}
