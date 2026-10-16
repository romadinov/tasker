#if DEBUG
import SwiftUI

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
            default: break
            }
        }
    }
}
#endif
