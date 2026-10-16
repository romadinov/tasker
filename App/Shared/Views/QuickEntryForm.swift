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
    @State private var tagIDs: [String] = []
    @State private var flagged = false
    @State private var deferText = ""
    @State private var dueText = ""
    @State private var savedCount = 0
    @State private var presetDue: Date?
    @FocusState private var titleFocused: Bool

    var body: some View {
        let s = model.snapshot
        let preview = QuickEntryParser(snapshot: s).parse(title)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.tint)
                TextField("New action", text: $title, prompt: Text("New action   #tag ::project ! due:fri"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { save(keepOpen: false) }
            }
            // What the inline shorthand will do.
            if preview != QuickEntryParser.Result(title: title) {
                HStack(spacing: 4) {
                    if let p = preview.projectID, let project = s.tasks[p] { Badge(text: project.title, systemImage: "circle.grid.2x2", color: Palette.project) }
                    ForEach(preview.tagIDs, id: \.self) { Badge(text: s.tags[$0]?.name ?? "", color: Palette.tag) }
                    ForEach(preview.unknownTags, id: \.self) { Badge(text: "+" + $0, color: Palette.tag) }
                    if preview.flagged { Image(systemName: "flag.fill").foregroundStyle(Palette.flag) }
                    if let d = preview.dueDate { Badge(text: "Due " + Fmt.relative(d), color: Palette.dueSoon) }
                    if let d = preview.deferDate { Badge(text: "Defer " + Fmt.relative(d)) }
                    if let d = preview.plannedDate { Badge(text: "Planned " + Fmt.relative(d), color: .blue) }
                    if let e = preview.estimatedMinutes { Badge(text: Fmt.estimate(e), systemImage: "clock") }
                }
                .font(.caption)
            }

            TextField("Note", text: $note, prompt: Text("Note"), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .foregroundStyle(.secondary)

            Divider()

            // Project: chip when chosen, otherwise an autocomplete field.
            if let pid = projectID, let p = s.tasks[pid] {
                HStack {
                    Image(systemName: "circle.grid.2x2").foregroundStyle(Palette.project)
                    Text(p.title)
                    Button { projectID = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                    Spacer()
                }
            } else {
                AutocompleteField(placeholder: "Project (Inbox)", icon: "circle.grid.2x2",
                                  suggestions: { Lookup.projects(model.snapshot, $0) },
                                  createLabel: { "New project “\($0)”" },
                                  onPick: { projectID = $0.id },
                                  onCreate: { name in projectID = model.createProject(named: name) })
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(tagIDs, id: \.self) { id in
                    Button { tagIDs.removeAll { $0 == id } } label: { Badge(text: s.tags[id]?.name ?? "?", systemImage: "xmark", color: Palette.tag) }
                        .buttonStyle(.plain)
                }
                AutocompleteField(placeholder: tagIDs.isEmpty ? "Tags" : "Add tag", icon: "tag",
                                  suggestions: { Lookup.tags(model.snapshot, $0, excluding: Set(tagIDs)) },
                                  createLabel: { "New tag “\($0)”" },
                                  onPick: { tagIDs.append($0.id) },
                                  onCreate: { name in tagIDs.append(model.createTag(named: name)) })
            }

            HStack(spacing: 8) {
                Toggle(isOn: $flagged) { Image(systemName: flagged ? "flag.fill" : "flag") }
                    .toggleStyle(.button)
                    .tint(Palette.flag)
                TextField("Defer", text: $deferText, prompt: Text("Defer: tom, fri…"))
                TextField("Due", text: $dueText, prompt: Text(presetDue.map { "Due " + Fmt.relative($0) } ?? "Due: today, +3d…"))
            }
            .textFieldStyle(.roundedBorder)

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
            tagIDs = capture.tagIDs
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

    func save(keepOpen: Bool) {
        let parser = QuickEntryParser(snapshot: model.snapshot)
        let id = model.quickAdd(title: title, note: note, projectID: projectID, tagIDs: tagIDs, flagged: flagged,
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
