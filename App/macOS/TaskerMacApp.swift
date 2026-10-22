import AppKit
import SwiftUI
import TaskerCore

@main
struct TaskerMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Uberdoer", id: "main") {
            RootView()
                .environment(AppModel.shared)
                .frame(minWidth: 1080, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 860)
        // tasker:// links go to the app delegate; don't let SwiftUI open extra windows for them.
        .handlesExternalEvents(matching: [])
        .commands { TaskerCommands() }

        Settings {
            MacSettingsView()
                .environment(AppModel.shared)
        }

        // Pomodoro in the menu bar while one is active: visible whatever app is in front.
        MenuBarExtra(isInserted: Binding(get: { PomodoroTimer.shared.isActive }, set: { _ in })) {
            PomodoroMenu().environment(AppModel.shared)
        } label: {
            let t = PomodoroTimer.shared
            Text(t.phase == .ready ? "🍅 ready" : "🍅 \(t.display)" + (t.isPaused ? " ⏸" : ""))
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            HotKeys.apply()
            _ = PomodoroTimer.shared // resumes a running pomodoro, logs one that ended while quit
            #if DEBUG
            DebugSnapshots.runIfRequested()
            #endif
        }
        NSApp.servicesProvider = services
        NotificationCenter.default.addObserver(forName: .taskerQuickAdded, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { Toast.show("Added to Uberdoer", detail: n.object as? String ?? "") }
        }
        NotificationCenter.default.addObserver(forName: .taskerShowQuickEntry, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                if let c = n.userInfo?["capture"] as? AppModel.Capture { QuickEntryController.shared.show(capture: c) }
            }
        }
        NSUpdateDynamicServices()
        NSApp.registerForRemoteNotifications()
    }

    /// tasker://add?… from other apps (Scriptorium's "Send to Uberdoer", Shortcuts, scripts).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if let r = AddRequest(url: url) { AppModel.shared.handleAdd(r); continue }
                // tasker://clip[?quick=1|dry=1] — run the clipper on the frontmost app (Shortcuts, Keyboard Maestro…).
                // dry=1 only reports what would be captured (no task is created).
                if ["uberdoer", "throughline", "tasker"].contains(url.scheme ?? ""), url.host == "clip" {
                    let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let flag = { (k: String) in q.contains { $0.name == k && ["1", "true"].contains($0.value ?? "") } }
                    if flag("dry") {
                        let c = Clipper.capture()
                        let summary = "title=\(c.title) | note=\(c.note.prefix(200))"
                        NSLog("TASKER-CLIP dry %@", summary)
                        Toast.show("Clip preview", detail: c.title + "\n" + (c.note.split(separator: "\n").first.map(String.init) ?? ""), seconds: 4)
                    } else {
                        Clipper.clipFrontmost(quick: flag("quick"))
                    }
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.becameActive() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // stay running so the global shortcuts keep working
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await AppModel.shared.sync?.syncNow() }
    }
}

@MainActor
enum HotKeys {
    static let quickEntryKey = "hotkey.quickEntry"
    static let clipKey = "hotkey.clip"
    static let quickClipKey = "hotkey.quickClip"
    static let voiceEntryKey = "hotkey.voiceEntry"

    static func apply() {
        HotKeyCenter.shared.register(id: 1, Shortcut.load(quickEntryKey, default: .quickEntryDefault)) {
            QuickEntryController.shared.show()
        }
        HotKeyCenter.shared.register(id: 2, Shortcut.load(clipKey, default: .clipDefault)) {
            Clipper.clipFrontmost()
        }
        HotKeyCenter.shared.register(id: 3, Shortcut.load(quickClipKey, default: .quickClipDefault)) {
            Clipper.clipFrontmost(quick: true)
        }
        // Voice entry: Quick Entry that starts listening at once; Return saves to the Inbox.
        HotKeyCenter.shared.register(id: 4, Shortcut.load(voiceEntryKey, default: .voiceEntryDefault)) {
            var c = AppModel.Capture()
            c.listen = true
            QuickEntryController.shared.show(capture: c)
        }
    }
}

/// Opens Settings on the Import tab. The old `showSettingsWindow:` action is ignored by SwiftUI's Settings
/// scene on current macOS, so this goes through `openSettings`.
private struct OpenImportSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("Import from OmniFocus…") {
            UserDefaults.standard.set("import", forKey: "settings.tab")
            NSApp.activate()
            openSettings()
        }
    }
}

struct TaskerCommands: Commands {
    var model: AppModel { AppModel.shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Action") { model.newTask() }.keyboardShortcut("n")
            Button("New Project") { model.newTask(isProject: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Folder") { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Divider()
            Button("Quick Entry…") { QuickEntryController.shared.show() }.keyboardShortcut("e", modifiers: [.command, .control])
            Button("Voice Entry…") { var c = AppModel.Capture(); c.listen = true; QuickEntryController.shared.show(capture: c) }
            Divider()
            OpenImportSettingsButton()
        }
        CommandMenu("Item") {
            let sel = Array(model.selection)
            // Space (and F to flag) are handled by the focused list, not as menu key equivalents,
            // which would also fire while typing in text fields.
            Button("Complete  (Space)") { model.toggleComplete(sel) }.disabled(sel.isEmpty)
            Button("Flag  (F)") { model.toggleFlag(sel) }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(sel.isEmpty)
            // Return (handled by the list) adds a new item below the selection; this edits the title (also double-click).
            Button("Edit Title") { if let id = sel.first { model.beginEditing(id) } }.disabled(sel.count != 1 || model.editingID != nil)
            Divider()
            Button("Start Pomodoro") { if let id = sel.first { PomodoroTimer.shared.start(id) } }
                .keyboardShortcut("p", modifiers: [.command, .control])
                .disabled(sel.count != 1 || model.snapshot.tasks[sel.first ?? ""]?.isProject != false)
            Button("Move To…") { model.moveTargetFor = sel }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(sel.isEmpty)
            Divider()
            Button("Defer to Tomorrow") { model.setDate(sel, F.deferDate, QuickEntryParser(snapshot: model.snapshot).date("tomorrow", hour: 0)) }
                .keyboardShortcut("d", modifiers: [.command, .control]).disabled(sel.isEmpty)
            Button("Due Today") { model.setDate(sel, F.dueDate, QuickEntryParser(snapshot: model.snapshot).date("today", hour: 17)) }
                .keyboardShortcut("t", modifiers: [.command, .control]).disabled(sel.isEmpty)
            Button("Mark Reviewed") {
                if model.sidebar == .review { model.markReviewedAndAdvance(); return }
                model.perform("Mark Reviewed") { tx in for id in sel where tx.base.tasks[id]?.isProject == true { tx.markReviewed(id) } }
                model.recentlyCompleted.formUnion(sel)
            }
        }
        CommandMenu("Organize") {
            OrganizeMenuItems(includeCleanUp: true).environment(AppModel.shared)
        }
        CommandGroup(after: .sidebar) {
            Button("Inbox") { model.sidebar = .inbox }.keyboardShortcut("1")
            Button("Projects") { model.sidebar = .projects }.keyboardShortcut("2")
            Button("Tags") { model.sidebar = .tags }.keyboardShortcut("3")
            Button("Forecast") { model.sidebar = .forecast }.keyboardShortcut("4")
            Button("Flagged") { model.sidebar = .flagged }.keyboardShortcut("5")
            Button("Nearby") { model.sidebar = .nearby }.keyboardShortcut("6")
            Button("Review") { model.sidebar = .review }.keyboardShortcut("7")
            Button("Board") { model.sidebar = .kanban }.keyboardShortcut("b", modifiers: [.command, .control])
            Button("Analytics") { model.sidebar = .analytics }.keyboardShortcut("0")
            ForEach(Array(model.snapshot.perspectives.prefix(2).enumerated()), id: \.element.id) { i, p in
                Button(p.name) { model.sidebar = .perspective(p.id) }.keyboardShortcut(KeyEquivalent(Character("\(8 + i)")))
            }
            Divider()
            Button("Back") { model.goBack() }.keyboardShortcut("[", modifiers: [.command, .option]).disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }.keyboardShortcut("]", modifiers: [.command, .option]).disabled(!model.canGoForward)
            Button(model.focusIDs.isEmpty ? "Focus" : "Unfocus") { model.toggleFocus() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button(model.showSidebar ? "Hide Sidebar" : "Show Sidebar") { model.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
            Button("Sync Status…") { model.showSyncStatus = true }
            Button("Sync Now") { Task { await model.sync?.syncNow() } }.keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}

/// Menu-bar dropdown for the running pomodoro.
struct PomodoroMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let t = PomodoroTimer.shared
        let title = t.taskID.flatMap { model.snapshot.tasks[$0]?.title } ?? ""
        Text(t.phase == .ready ? "Break over" : "\(t.phaseLabel) — \(t.display) left")
        Button(title.count > 50 ? String(title.prefix(50)) + "…" : title) {
            if let id = t.taskID { NSApp.activate(); model.reveal(id) }
        }
        Divider()
        PomodoroControls()
    }
}
