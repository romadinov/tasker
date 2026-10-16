import AppKit
import SwiftUI
import TaskerCore

struct MacSettingsView: View {
    var body: some View {
        TabView {
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            SettingsView().tabItem { Label("General", systemImage: "gearshape") }
            NavigationStack { SyncStatusView() }.tabItem { Label("Sync", systemImage: "icloud") }
            OmniFocusImportView().tabItem { Label("Import", systemImage: "square.and.arrow.down") }
        }
        .frame(width: 620, height: 560)
    }
}

struct ShortcutSettings: View {
    @State private var quick = Shortcut.load(HotKeys.quickEntryKey, default: .quickEntryDefault)
    @State private var clip = Shortcut.load(HotKeys.clipKey, default: .clipDefault)
    @State private var axGranted = Clipper.accessibilityGranted

    var body: some View {
        Form {
            Section {
                LabeledContent("Quick Entry") { ShortcutRecorder(shortcut: $quick) }
                LabeledContent("Clip from front app") { ShortcutRecorder(shortcut: $clip) }
            } footer: {
                Text("Work from any app. Clipping grabs the page title and URL in Safari, Chrome, Arc, Brave and Edge, a link back to the selected email in Mail, and the selected text everywhere else.")
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
                Text("Any app: select text → right-click → Services → Send to Tasker. You can give it a shortcut in System Settings → Keyboard → Keyboard Shortcuts → Services.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: quick) { _, v in Shortcut.save(v, HotKeys.quickEntryKey); HotKeys.apply() }
        .onChange(of: clip) { _, v in Shortcut.save(v, HotKeys.clipKey); HotKeys.apply() }
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
        HotKeyCenter.shared.unregister(id: 1); HotKeyCenter.shared.unregister(id: 2)
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
                Text("Reads your OmniFocus database through OmniFocus's own automation, so ids, folders, tags, repeat rules, review intervals and custom perspective rules come across exactly. OmniFocus must be installed; macOS will ask once to let Tasker control it. Re-importing later refreshes items instead of duplicating them.")
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
