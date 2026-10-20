import SwiftUI
import TaskerCore

/// An item's name that turns into a text field on double-click (Mac) or via "Rename" (context menu).
/// Return or clicking away saves, Esc cancels.
struct RenamableName: View {
    @Environment(AppModel.self) private var model
    let id: String
    let name: String
    var placeholder = "Name"
    var font: Font = .body
    var bold = false
    var color: Color = .primary
    var strikethrough = false

    var body: some View {
        if model.renamingID == id {
            RenameField(id: id, initial: name, placeholder: placeholder, bold: bold)
        } else {
            Text(name.isEmpty ? placeholder : name)
                .font(bold ? font.weight(.semibold) : font)
                .foregroundStyle(color)
                .strikethrough(strikethrough)
                .lineLimit(1)
                #if os(macOS)
                .onTapGesture(count: 2) { model.editingID = nil; model.renamingID = id }
                #endif
        }
    }
}

private struct RenameField: View {
    @Environment(AppModel.self) private var model
    let id: String
    let initial: String
    let placeholder: String
    let bold: Bool
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var hadFocus = false

    var body: some View {
        #if os(macOS)
        InlineTextField(text: $text, placeholder: placeholder, bold: bold,
                        onSubmit: { model.rename(id, to: text) },
                        onCancel: { model.renamingID = nil },
                        onEndEditing: { if model.renamingID == id { model.rename(id, to: text) } })
            .onAppear { text = initial }
        #else
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .bold(bold)
            .focused($focused)
            .onAppear { text = initial; DispatchQueue.main.async { focused = true } }
            .onSubmit { model.rename(id, to: text) }
            .onChange(of: focused) { _, f in
                if f { hadFocus = true }
                if !f && hadFocus && model.renamingID == id { model.rename(id, to: text) }
            }
        #endif
    }
}
