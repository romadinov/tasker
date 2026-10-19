import SwiftUI
import TaskerCore

/// OmniFocus's Organize menu: used in the menu bar (Mac, iPad keyboard) and in row context menus.
struct OrganizeMenuItems: View {
    @Environment(AppModel.self) private var model
    /// Items to act on; nil = the current selection (menu bar).
    var ids: [String]?
    var includeCleanUp = false

    var body: some View {
        let ids = ids ?? model.organizeIDs
        let off = ids.isEmpty || model.editingID != nil
        let s = model.snapshot
        if includeCleanUp {
            Button("Clean Up") { model.cleanUp() }.keyboardShortcut("k")
            Divider()
        }
        Button("Add Inside") { model.selection = Set(ids.prefix(1)); model.addInside() }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(off || ids.count != 1 || s.tasks[ids[0]] == nil)
        Button("Add Outside") { model.selection = Set(ids.prefix(1)); model.addOutside() }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(off || !canAddOutside(ids))
        Divider()
        Menu("Move") {
            Button("Move Down") { model.moveUpDown(ids, up: false) }.keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Move Right") { model.indent(ids) }.keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            Button("Move Up") { model.moveUpDown(ids, up: true) }.keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Move Left") { model.outdent(ids) }.keyboardShortcut(.leftArrow, modifiers: [.command, .control])
        }
        .disabled(off)
        Button("Indent") { model.indent(ids) }.keyboardShortcut("]").disabled(off)
        Button("Outdent") { model.outdent(ids) }.keyboardShortcut("[").disabled(off)
        Button("Group") { model.group(ids) }.keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(off || ids.contains { s.tags[$0] != nil })
        Button("Ungroup") { model.ungroup(ids) }.keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(off || !ids.contains { id in
                (s.tasks[id]?.isProject == false || s.folders[id] != nil) && !(s.children[id] ?? []).isEmpty
            })
        Divider()
        Menu("Sort Once") {
            ForEach(OutlineSort.allCases, id: \.self) { sort in
                Button(sort.label) { model.sortOnce(ids, by: sort) }
            }
        }
        .disabled(model.editingID != nil)
    }

    private func canAddOutside(_ ids: [String]) -> Bool {
        let s = model.snapshot
        guard ids.count == 1, s.tasks[ids[0]]?.isProject == false, let p = s.info[ids[0]]?.parentID else { return false }
        return s.tasks[p]?.isProject == false
    }
}
