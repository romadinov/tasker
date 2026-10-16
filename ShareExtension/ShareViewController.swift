import SwiftUI
import TaskerCore
import UIKit
import UniformTypeIdentifiers

/// Share sheet capture. Writes straight into the shared database (with its own replica id)
/// and uploads immediately, so the capture reaches the Mac even if Tasker isn't opened.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { @MainActor in
            let capture = await Self.extract(items)
            let form = ShareForm(initialTitle: capture.title, initialNote: capture.note,
                                 onSave: { [weak self] title, note, flagged in await self?.save(title: title, note: note, flagged: flagged) },
                                 onCancel: { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) })
            let host = UIHostingController(rootView: form)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    static func extract(_ items: [NSExtensionItem]) async -> (title: String, note: String) {
        var title = items.first?.attributedContentText?.string ?? ""
        var url: URL?
        var text: String?
        for item in items {
            if title.isEmpty, let t = item.attributedTitle?.string { title = t }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
                }
                if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
                }
            }
        }
        if title.isEmpty { title = text.map { String(($0.split(separator: "\n").first ?? "").prefix(120)) } ?? url?.host ?? "" }
        let note = [url?.absoluteString, text == title ? nil : text].compactMap { $0 }.joined(separator: "\n\n")
        return (title, note)
    }

    @MainActor
    func save(title: String, note: String, flagged: Bool) async {
        do {
            let store = try Store(url: TaskerConfig.databaseURL(), role: "share")
            let parsed = QuickEntryParser(snapshot: store.snapshot()).parse(title)
            store.transact("Share") { tx in
                var n = NewTask(title: parsed.title.isEmpty ? title : parsed.title)
                n.note = note
                n.flagged = flagged || parsed.flagged
                n.dueDate = parsed.dueDate
                n.deferDate = parsed.deferDate
                n.parent = parsed.projectID
                n.tagIDs = parsed.tagIDs
                tx.createTask(n)
            }
            TaskerConfig.postExternalChange()
            // Best effort; if it doesn't finish in time the app uploads it on next launch.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await CloudSync.uploadPending(store: store, containerIdentifier: TaskerConfig.cloudContainer, replicas: [store.replica]) }
                group.addTask { try? await Task.sleep(for: .seconds(8)) }
                await group.next()
                group.cancelAll()
            }
        } catch {
            NSLog("Tasker share: \(error)")
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct ShareForm: View {
    @State var title: String
    @State var note: String
    @State private var flagged = false
    @State private var saving = false
    let onSave: (String, String, Bool) async -> Void
    let onCancel: () -> Void

    init(initialTitle: String, initialNote: String, onSave: @escaping (String, String, Bool) async -> Void, onCancel: @escaping () -> Void) {
        _title = State(initialValue: initialTitle)
        _note = State(initialValue: initialNote)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Action  (#tag ::project due:fri)", text: $title, axis: .vertical)
                TextField("Note", text: $note, axis: .vertical).lineLimit(3...10)
                Toggle("Flagged", isOn: $flagged)
            }
            .navigationTitle("Add to Tasker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") {
                            saving = true
                            Task { await onSave(title, note, flagged) }
                        }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && note.isEmpty)
                    }
                }
            }
        }
    }
}
