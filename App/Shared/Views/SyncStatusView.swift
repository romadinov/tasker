import SwiftUI
import UniformTypeIdentifiers
import TaskerCore

extension UTType {
    static let taskerLog = UTType(exportedAs: "com.romadinov.tasker.log", conformingTo: .data)
}

struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.taskerLog, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: LogDocument?
    @State private var importing = false
    @State private var message: String?
    @State private var repairing = false

    var body: some View {
        let s = model.syncStatus
        Form {
            Section("iCloud") {
                LabeledContent("State", value: SyncBadge().title(s))
                LabeledContent("Last received", value: s.lastFetch.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")
                LabeledContent("Last sent", value: s.lastSend.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")
                LabeledContent("Waiting to upload", value: "\(s.pendingUpload) changes")
                LabeledContent("History on this device", value: "\(s.totalOps) changes")
                if s.missingChanges > 0 {
                    LabeledContent("Announced but not yet received", value: "\(s.missingChanges)")
                        .foregroundStyle(.orange)
                }
                if let e = s.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                if let r = s.lastRepair { LabeledContent("Last repair", value: r.formatted(date: .abbreviated, time: .shortened)) }
            }
            Section {
                ForEach(s.devices) { d in
                    HStack {
                        Image(systemName: d.platform.contains("mac") ? "laptopcomputer" : (d.platform.contains("iPad") ? "ipad" : "iphone"))
                        VStack(alignment: .leading) {
                            Text(d.name + (d.isThisDevice ? " (this device)" : ""))
                            Text("Updated \(d.updated.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if d.have >= d.lastCounter {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("\(d.have)/\(d.lastCounter)").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                        }
                    }
                }
            } header: { Text("Devices") } footer: {
                Text("Every device publishes how many of its changes are in iCloud. A green check means this device has received all of them.")
            }
            Section {
                Button("Sync Now") { Task { await model.sync?.syncNow() } }
                Button(repairing ? "Repairing…" : "Repair Sync") {
                    repairing = true
                    Task { await model.sync?.repair(); repairing = false }
                }
                .disabled(repairing)
            } footer: {
                Text("Repair re-downloads everything from iCloud and uploads whatever iCloud is missing. Merging is idempotent, so it can't duplicate or lose anything. It also runs automatically when a gap is detected.")
            }
            Section {
                Button("Export Database File…") {
                    if let d = try? model.store.exportLog() { exporting = LogDocument(data: d) }
                }
                Button("Merge Database File…") { importing = true }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Manual transfer") } footer: {
                Text("Works without iCloud: AirDrop the file to another device and merge it there. Daily backups are kept next to the database.")
            }
            Section("Log") {
                ForEach(s.events, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
                      contentType: .taskerLog, defaultFilename: "Tasker \(Date().formatted(.iso8601.year().month().day())).taskerlog") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.taskerLog, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let n = try model.store.mergeLog(Data(contentsOf: url))
                model.sync?.localChangesCommitted()
                message = "Merged \(n) new changes."
            } catch {
                message = "Couldn't merge: \(error.localizedDescription)"
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Sync") {
                Button("Sync status…") { model.showSyncStatus = true }
            }
            CalendarSettingsSection()
            Section("Dates") {
                Stepper("Due soon: \(model.snapshot.setting("dueSoonDays")?.int ?? 2) days",
                        value: Binding(get: { model.snapshot.setting("dueSoonDays")?.int ?? 2 },
                                       set: { v in model.perform("Due Soon") { $0.setSetting("dueSoonDays", .number(Double(v))) } }), in: 0...14)
            }
            Section("Quick entry shorthand") {
                Text("#tag   ::project   !  (flag)   due:fri   defer:tomorrow   plan:+3d   ~30m").font(.callout.monospaced())
            }
            #if os(iOS)
            Section("Import") {
                Text("Import your OmniFocus database from the Mac app (Settings → Import). It syncs here automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
