import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Mac Share menu → "Throughline": sends the shared link/text to the Throughline app via tasker://add.
/// (Extensions are sandboxed and can't open Throughline's database; the app saves the item.)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 230))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { @MainActor in
            let c = await Self.extract(items)
            let form = MacShareForm(title: c.title, url: c.url, note: c.note,
                                    onSave: { [weak self] t, n, flagged in self?.send(title: t, url: c.url, note: n, flagged: flagged) },
                                    onCancel: { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) })
            let host = NSHostingView(rootView: form)
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            view.addSubview(host)
            preferredContentSize = host.fittingSize
        }
    }

    static func extract(_ items: [NSExtensionItem]) async -> (title: String, url: String?, note: String) {
        var title = items.first?.attributedContentText?.string ?? items.first?.attributedTitle?.string ?? ""
        var url: URL?
        var text: String?
        for item in items {
            for p in item.attachments ?? [] {
                if url == nil, p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let v = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier)
                    url = (v as? URL) ?? (v as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (v as? String).flatMap(URL.init(string:))
                }
                if text == nil, p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
                }
            }
        }
        if url == nil, let t = text, let u = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme != nil { url = u; text = nil }
        if title.isEmpty || title == url?.absoluteString {
            title = text.map { String(($0.split(separator: "\n").first ?? "").prefix(120)) } ?? url?.host() ?? "Link"
        }
        let note = (text == title) ? "" : (text ?? "")
        return (title, url?.absoluteString, note)
    }

    func send(title: String, url: String?, note: String, flagged: Bool) {
        var c = URLComponents()
        c.scheme = "throughline"; c.host = "add"
        var q = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "quick", value: "1")]
        if let url { q.append(URLQueryItem(name: "url", value: url)) }
        if !note.isEmpty { q.append(URLQueryItem(name: "note", value: note)) }
        if flagged { q.append(URLQueryItem(name: "flagged", value: "1")) }
        c.queryItems = q
        // Percent-encode values fully (links contain ? & =).
        c.percentEncodedQuery = q.map { "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "")" }
            .joined(separator: "&")
        if let u = c.url {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false // stay where you are; Throughline shows a small confirmation
            NSWorkspace.shared.open(u, configuration: config) { _, _ in }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct MacShareForm: View {
    @State var title: String
    let url: String?
    @State var note: String
    @State private var flagged = false
    let onSave: (String, String, Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add to Throughline Inbox", systemImage: "tray.and.arrow.down.fill").font(.headline)
            TextField("Title", text: $title, prompt: Text("Untitled Item"))
                .textFieldStyle(.roundedBorder)
            if let url {
                Label(url, systemImage: "link").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TextField("Note", text: $note, prompt: Text("Note"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            HStack {
                Toggle("Flag", isOn: $flagged)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(title, note, flagged) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
