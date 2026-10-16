import SwiftUI
import TaskerCore

/// Shared quick-capture form: the floating panel on the Mac, a sheet on iPhone/iPad.
struct QuickEntryForm: View {
    @Environment(AppModel.self) private var model
    let capture: AppModel.Capture
    let onDone: () -> Void

    @State private var title = ""
    @State private var note = ""
    @State private var projectID: String?
    @State private var tagIDs: Set<String> = []
    @State private var flagged = false
    @State private var deferText = ""
    @State private var dueText = ""
    @State private var savedCount = 0
    @State private var presetDue: Date?
    @FocusState private var titleFocused: Bool

    var body: some View {
        let s = model.snapshot
        let parser = QuickEntryParser(snapshot: s)
        let preview = parser.parse(title)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.tint)
                TextField("New action   #tag ::project ! due:fri", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { save(keepOpen: false) }
            }
            // What the shorthand will do.
            HStack(spacing: 4) {
                if let p = preview.projectID ?? projectID, let project = s.tasks[p] {
                    Badge(text: project.title, systemImage: "circle.grid.2x2", color: Palette.project)
                }
                ForEach(preview.tagIDs, id: \.self) { Badge(text: s.tags[$0]?.name ?? "", color: Palette.tag) }
                ForEach(preview.unknownTags, id: \.self) { Badge(text: "+" + $0, color: Palette.tag) }
                if preview.flagged { Image(systemName: "flag.fill").foregroundStyle(Palette.flag) }
                if let d = preview.dueDate { Badge(text: "Due " + Fmt.relative(d), color: Palette.dueSoon) }
                if let d = preview.deferDate { Badge(text: "Defer " + Fmt.relative(d)) }
                if let d = preview.plannedDate { Badge(text: "Planned " + Fmt.relative(d), color: .blue) }
                if let e = preview.estimatedMinutes { Badge(text: Fmt.estimate(e), systemImage: "clock") }
            }
            .font(.caption)

            TextField("Note", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...8)
                .foregroundStyle(.secondary)

            Divider()
            #if os(iOS)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) { projectMenu(s); tagMenu(s); flagToggle; Spacer() }
                HStack(spacing: 8) { deferField; dueField }
            }
            .textFieldStyle(.roundedBorder)
            #else
            HStack(spacing: 12) {
                projectMenu(s); tagMenu(s); flagToggle
                deferField.frame(width: 80)
                dueField.frame(width: 80)
                Spacer()
            }
            .textFieldStyle(.roundedBorder)
            .menuStyle(.borderlessButton)
            #endif

            HStack {
                if savedCount > 0 { Text("Saved \(savedCount)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                #if os(macOS)
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                #endif
                Button("Save & Add Another") { save(keepOpen: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                #if os(macOS)
                Button("Save") { save(keepOpen: false) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                #endif
            }
            #if os(iOS)
            Spacer(minLength: 0)
            #endif
        }
        .padding(16)
        .onAppear {
            title = capture.title
            note = capture.note
            projectID = capture.projectID
            tagIDs = Set(capture.tagIDs)
            flagged = capture.flagged || model.sidebar == .flagged
            presetDue = capture.dueDate
            DispatchQueue.main.async { titleFocused = true }
        }
        #if os(iOS)
        .navigationTitle("New Action")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { onDone() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save(keepOpen: false) }.fontWeight(.semibold) }
        }
        #endif
    }

    func projectMenu(_ s: Snapshot) -> some View {
        Menu {
            Button("Inbox") { projectID = nil }
            Divider()
            ForEach(s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true }) { p in
                Button(p.title) { projectID = p.id }
            }
        } label: {
            Label(projectID.flatMap { s.tasks[$0]?.title } ?? "Inbox", systemImage: projectID == nil ? "tray" : "circle.grid.2x2")
                .lineLimit(1)
        }
        .fixedSize()
    }

    func tagMenu(_ s: Snapshot) -> some View {
        Menu {
            ForEach(s.orderedTags, id: \.tag.id) { e in
                Button { if tagIDs.contains(e.tag.id) { tagIDs.remove(e.tag.id) } else { tagIDs.insert(e.tag.id) } } label: {
                    Label(String(repeating: "   ", count: e.depth) + e.tag.name, systemImage: tagIDs.contains(e.tag.id) ? "checkmark" : "")
                }
            }
        } label: {
            Label(tagIDs.isEmpty ? "Tags" : s.tagNames(Array(tagIDs)).joined(separator: ", "), systemImage: "tag")
                .lineLimit(1)
        }
        .fixedSize()
    }

    var flagToggle: some View {
        Toggle(isOn: $flagged) { Image(systemName: flagged ? "flag.fill" : "flag") }
            .toggleStyle(.button)
            .tint(Palette.flag)
    }

    var deferField: some View { TextField("Defer", text: $deferText, prompt: Text("Defer: tom, fri…")) }
    var dueField: some View {
        TextField("Due", text: $dueText, prompt: Text(presetDue.map { "Due " + Fmt.relative($0) } ?? "Due: today, +3d…"))
    }

    func save(keepOpen: Bool) {
        let parser = QuickEntryParser(snapshot: model.snapshot)
        let id = model.quickAdd(title: title, note: note, projectID: projectID, tagIDs: Array(tagIDs), flagged: flagged,
                                deferDate: parser.date(deferText, hour: 0), dueDate: parser.date(dueText, hour: 17) ?? presetDue)
        guard id != nil else { if !keepOpen { onDone() }; return }
        savedCount += 1
        if keepOpen {
            title = ""; note = ""; flagged = false; deferText = ""; dueText = ""
            titleFocused = true
        } else {
            onDone()
        }
    }
}
