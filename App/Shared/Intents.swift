import AppIntents
import Foundation
import TaskerCore

/// "Add to Uberdoer" for Shortcuts, Siri, Spotlight and the iPhone Action button.
struct AddToInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Uberdoer Inbox"
    static let description = IntentDescription("Captures an action into the Uberdoer inbox. Supports #tag ::project ! due:fri shorthand.")

    @Parameter(title: "Action") var text: String
    @Parameter(title: "Note", default: "") var note: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to Uberdoer") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        model.quickAdd(title: text, note: note, projectID: nil, tagIDs: [], flagged: false, deferDate: nil, dueDate: nil)
        await model.sync?.syncNow()
        return .result(dialog: "Added to Uberdoer.")
    }
}

struct TaskerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddToInboxIntent(), phrases: ["Add to \(.applicationName)", "Capture in \(.applicationName)"],
                    shortTitle: "Add to Inbox", systemImageName: "tray.and.arrow.down")
    }
}
