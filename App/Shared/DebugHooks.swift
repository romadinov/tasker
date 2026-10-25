#if DEBUG
import SwiftUI
import TaskerCore

/// Development aid: `TASKER_DEBUG_ACTION=newTask|quickEntry` runs a UI action shortly after launch,
/// so flows can be reproduced in the simulator without tapping.
enum DebugHooks {
    @MainActor
    static func run(_ model: AppModel, newTask: @escaping () -> Void) {
        guard let action = ProcessInfo.processInfo.environment["TASKER_DEBUG_ACTION"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            switch action {
            case "newTask": newTask()
            case "quickEntry": model.presentQuickEntry()
            case "url":
                // TASKER_DEBUG_URL="tasker://add?…" exercises the same handler as onOpenURL.
                if let u = ProcessInfo.processInfo.environment["TASKER_DEBUG_URL"].flatMap(URL.init(string:)), let r = AddRequest(url: u) {
                    model.handleAdd(r)
                }
            case "nearby":
                // TASKER_DEBUG_TAGLOC="TagName|search term" links a tag to a kind of place.
                if let spec = ProcessInfo.processInfo.environment["TASKER_DEBUG_TAGLOC"]?.split(separator: "|").map(String.init), spec.count == 2,
                   let tag = model.snapshot.tags.values.first(where: { $0.name == spec[0] }) {
                    let loc = TagLocation(kind: .kind, name: spec[1], query: spec[1], radius: 300)
                    model.perform("Tag Location") { $0.set(.tag, tag.id, F.location, JSON(encoding: loc)) }
                }
                model.sidebar = .nearby
                NearbyModel.shared.startIfNeeded()
            case "picker":
                // Project picker on a selected Inbox row, seeded with TASKER_DEBUG_QUERY (iPad popover check).
                for path in ["Работа : Mésange Bleue", "Работа : Scriptorium", "Дом : Ремонт", "Personal : Health"] where model.snapshot.project(atPath: path) == nil {
                    _ = model.createProject(named: path)
                }
                let id = IDs.make()
                model.perform("Debug") { _ = $0.createTask(NewTask(title: "Picker test"), id: id) }
                model.sidebar = .inbox
                model.selection = [id]
                model.projectEditingSeed = ProcessInfo.processInfo.environment["TASKER_DEBUG_QUERY"] ?? ""
                model.inlineField = .init(id: id, field: .project)
            case "feedback":
                // Writes a note to TASKER_FEEDBACK_DIR and reports whether the iCloud container resolves.
                let shot = AppModel.captureWindow()?.pngBytes
                Task.detached {
                    let container = FileManager.default.url(forUbiquityContainerIdentifier: Feedback.containerID)
                    NSLog("FEEDBACK container: %@", container?.path ?? "nil")
                    do {
                        try ImprovementNotes.add("Test note (line one)\nsecond line", where: "Inbox, action “x”", screenshot: shot)
                        NSLog("FEEDBACK wrote to %@", Feedback.documents().path)
                    } catch { NSLog("FEEDBACK error %@", "\(error)") }
                }
            default: break
            }
        }
    }
}
#endif
