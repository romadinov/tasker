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
            case "nearby":
                // TASKER_DEBUG_TAGLOC="TagName|search term" links a tag to a kind of place.
                if let spec = ProcessInfo.processInfo.environment["TASKER_DEBUG_TAGLOC"]?.split(separator: "|").map(String.init), spec.count == 2,
                   let tag = model.snapshot.tags.values.first(where: { $0.name == spec[0] }) {
                    let loc = TagLocation(kind: .kind, name: spec[1], query: spec[1], radius: 300)
                    model.perform("Tag Location") { $0.set(.tag, tag.id, F.location, JSON(encoding: loc)) }
                }
                model.sidebar = .nearby
                NearbyModel.shared.startIfNeeded()
            default: break
            }
        }
    }
}
#endif
