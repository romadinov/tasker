import AppKit
import SwiftUI
import TaskerCore

struct MacSettingsView: View {
    /// Shared with the "Import from OmniFocus…" menu item so it can open Settings on the Import tab.
    @AppStorage("settings.tab") private var tab = "shortcuts"

    var body: some View {
        TabView(selection: $tab) {
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
            SettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            NavigationStack { SyncStatusView() }.tabItem { Label("Sync", systemImage: "icloud") }.tag("sync")
            OmniFocusImportView().tabItem { Label("Import", systemImage: "square.and.arrow.down") }.tag("import")
            MCPSettingsView().tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }.tag("mcp")
        }
        .frame(width: 620, height: 560)
    }
}

struct ShortcutSettings: View {
    @State private var quick = Shortcut.load(HotKeys.quickEntryKey, default: .quickEntryDefault)
    @State private var clip = Shortcut.load(HotKeys.clipKey, default: .clipDefault)
    @State private var quickClip = Shortcut.load(HotKeys.quickClipKey, default: .quickClipDefault)
    @State private var axGranted = Clipper.accessibilityGranted

    var body: some View {
        Form {
            Section {
                LabeledContent("Quick Entry") { ShortcutRecorder(shortcut: $quick) }
                LabeledContent("Clip (review in Quick Entry)") { ShortcutRecorder(shortcut: $clip) }
                LabeledContent("Quick Clip (save straight to Inbox)") { ShortcutRecorder(shortcut: $quickClip) }
            } footer: {
                Text("Work from any app. Clips always carry a link back: the page URL in Safari, Chrome, Arc, Brave, Edge, Vivaldi and Orion; the email in Mail and Mimestream (select the message first); the highlighted message in Slack (hover or arrow to it); plus any selected text. Mimestream and Slack links need Accessibility access.")
            }
            Section("Selected text") {
                HStack {
                    Image(systemName: axGranted ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(axGranted ? .green : .orange)
                    Text(axGranted ? "Accessibility access granted" : "Allow Accessibility access to clip selected text")
                    Spacer()
                    if !axGranted { Button("Allow…") { Clipper.requestAccessibility() } }
                }
            }
            Section("Services menu") {
                Text("Any app: select text → right-click → Services → Send to Uberdoer. You can give it a shortcut in System Settings → Keyboard → Keyboard Shortcuts → Services.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: quick) { _, v in Shortcut.save(v, HotKeys.quickEntryKey); HotKeys.apply() }
        .onChange(of: clip) { _, v in Shortcut.save(v, HotKeys.clipKey); HotKeys.apply() }
        .onChange(of: quickClip) { _, v in Shortcut.save(v, HotKeys.quickClipKey); HotKeys.apply() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in axGranted = Clipper.accessibilityGranted }
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "Type shortcut…" : (shortcut?.display ?? "None")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 140)
            if shortcut != nil { Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
        }
        .onDisappear(perform: stop)
    }

    func start() {
        recording = true
        // Temporarily release our own hotkeys so the current combination can be re-recorded.
        HotKeyCenter.shared.unregister(id: 1); HotKeyCenter.shared.unregister(id: 2); HotKeyCenter.shared.unregister(id: 3)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Esc cancels
            if let s = Shortcut(event: e) { shortcut = s; stop() }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKeys.apply()
    }
}

struct OmniFocusImportView: View {
    @Environment(AppModel.self) private var model
    enum Phase { case idle, reading, ready(OmniFocusImport.Export, OmniFocusImport.Summary), importing, done(String), failed(String) }
    @State private var phase: Phase = .idle
    @State private var pickingFile = false

    var body: some View {
        Form {
            Section {
                Text("Reads your OmniFocus database through OmniFocus's own automation, so ids, folders, tags, repeat rules, review intervals and custom perspective rules come across exactly. OmniFocus must be installed; macOS will ask once to let Uberdoer control it. Re-importing later refreshes items instead of duplicating them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                switch phase {
                case .idle:
                    HStack {
                        Button("Read from OmniFocus") { read() }.buttonStyle(.borderedProminent)
                        Button("Import Export File…") { pickingFile = true }
                    }
                case .reading:
                    HStack { ProgressView().controlSize(.small); Text("Reading OmniFocus (can take ~30 s for large databases)…") }
                case .ready(let export, let summary):
                    Text("Found \(summary.description).")
                    if !summary.unsupportedRules.isEmpty {
                        Text("Some rules in \(summary.unsupportedRules.joined(separator: ", ")) aren't understood yet; they're kept and shown as imported rules.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Import") { apply(export) }.buttonStyle(.borderedProminent)
                        Button("Cancel") { phase = .idle }
                    }
                case .importing:
                    HStack { ProgressView().controlSize(.small); Text("Importing…") }
                case .done(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Import Again") { phase = .idle }
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.octagon").foregroundStyle(.red)
                    Button("Try Again") { phase = .idle }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            load(try? Data(contentsOf: url))
        }
    }

    func read() {
        phase = .reading
        Task.detached {
            let data = OmniFocusRunner.export()
            await MainActor.run { load(data.0, error: data.1) }
        }
    }

    @MainActor
    func load(_ data: Data?, error: String? = nil) {
        guard let data, !data.isEmpty else { phase = .failed(error ?? "No data received from OmniFocus."); return }
        do {
            let export = try OmniFocusImport.decode(data)
            phase = .ready(export, OmniFocusImport.summary(export))
        } catch {
            phase = .failed("Couldn't read the export: \(error.localizedDescription)")
        }
    }

    func apply(_ export: OmniFocusImport.Export) {
        phase = .importing
        let store = model.store
        Task.detached {
            let summary = OmniFocusImport.apply(export, to: store)
            await MainActor.run {
                AppModel.shared.sync?.localChangesCommitted()
                phase = .done("Imported \(summary.description). Uploading to iCloud in the background.")
            }
        }
    }
}

enum OmniFocusRunner {
    /// Runs the export script inside OmniFocus via `osascript` (off the main thread).
    static func export() -> (Data?, String?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tasker-of-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let js = dir.appendingPathComponent("export.js")
        let out = dir.appendingPathComponent("export.json")
        try? OmniFocusImport.exportScript.write(to: js, atomically: true, encoding: .utf8)
        let script = """
        set js to read POSIX file "\(js.path)" as «class utf8»
        with timeout of 900 seconds
            tell application id "com.omnigroup.OmniFocus4" to set jsonText to (evaluate javascript js)
        end timeout
        set f to open for access POSIX file "\(out.path)" with write permission
        set eof of f to 0
        write jsonText to f as «class utf8»
        close access f
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return (nil, error.localizedDescription) }
        p.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        if p.terminationStatus != 0 { return (nil, errText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript failed") }
        return (try? Data(contentsOf: out), nil)
    }
}

/// Connect AI assistants (Claude Code, Claude Desktop, any MCP client) to Uberdoer.
struct MCPSettingsView: View {
    @State private var copied: String?

    var path: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/uberdoer-mcp").path }
    var claudeCode: String { "claude mcp add --scope user uberdoer -- \"\(path)\"" }
    var desktopJSON: String {
        """
        {
          "mcpServers": {
            "uberdoer": { "command": "\(path)" }
          }
        }
        """
    }
    var inApplications: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    var body: some View {
        Form {
            Section {
                Text("Uberdoer includes an MCP server, so assistants can read your perspectives, search, and add or update actions. It works on this Mac's database directly; changes appear in the app at once and sync to your other devices via iCloud.")
                    .font(.callout).foregroundStyle(.secondary)
                if !inApplications {
                    Label("Uberdoer isn't in /Applications. If you move it later, update the path below in your MCP client.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Claude Code") {
                snippet(claudeCode, key: "code")
            }
            Section("Claude Desktop — add to claude_desktop_config.json") {
                snippet(desktopJSON, key: "desktop")
            }
            Section("Tools") {
                Text("list_perspectives · get_perspective_items · search_tasks · get_task · list_projects · list_tags · create_task · update_task · complete_task · drop_task · create_project · mark_reviewed")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func snippet(_ text: String, key: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == key ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = key
            }
        }
    }
}
