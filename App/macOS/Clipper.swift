import AppKit
import ApplicationServices
import TaskerCore

/// The clipper: captures what you're looking at in the frontmost app into Quick Entry.
/// - Safari / Chromium browsers / Arc: page title + URL (+ selected text)
/// - Mail: subject + a message:// link that reopens the email
/// - Anything else: the selected text (via Accessibility, if permitted)
@MainActor
enum Clipper {
    static func clipFrontmost() {
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier ?? ""
        var capture = AppModel.Capture()
        let selection = selectedText()

        switch bundle {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            if let r = runScript("tell application id \"\(bundle)\" to return {name of current tab of front window, URL of current tab of front window}") {
                capture.title = r.first ?? ""
                capture.note = r.dropFirst().first ?? ""
            }
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi":
            if let r = runScript("tell application id \"\(bundle)\" to return {title of active tab of front window, URL of active tab of front window}") {
                capture.title = r.first ?? ""
                capture.note = r.dropFirst().first ?? ""
            }
        case "com.apple.mail":
            let script = """
            tell application "Mail"
                set m to item 1 of (get selection)
                return {subject of m, message id of m, sender of m}
            end tell
            """
            if let r = runScript(script), r.count >= 2 {
                capture.title = r[0]
                let id = r[1].addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? r[1]
                capture.note = "message://%3C\(id)%3E" + (r.count > 2 ? "\nFrom: \(r[2])" : "")
            }
        default:
            capture.title = app?.localizedName.map { "From \($0)" } ?? ""
        }

        if let selection, !selection.isEmpty {
            if capture.title.isEmpty || capture.title.hasPrefix("From ") {
                let firstLine = selection.split(separator: "\n").first.map(String.init) ?? selection
                capture.title = String(firstLine.prefix(120))
            }
            capture.note = [capture.note, selection].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        QuickEntryController.shared.show(capture: capture)
    }

    /// Selected text from the focused element of the frontmost app (needs Accessibility).
    static func selectedText() -> String? {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    private static func runScript(_ source: String) -> [String]? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            NSLog("Tasker clipper: \(error ?? [:])")
            return nil
        }
        if result.numberOfItems == 0 { return result.stringValue.map { [$0] } }
        return (1...result.numberOfItems).map { result.atIndex($0)?.stringValue ?? "" }
    }
}

/// Services menu: "Send to Tasker" from any app (assign a shortcut in System Settings → Keyboard).
final class ServicesProvider: NSObject {
    @objc func sendToInbox(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string) ?? pboard.string(forType: .URL) ?? ""
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let capture = AppModel.Capture(title: String(firstLine.prefix(120)), note: text == firstLine ? "" : text)
        Task { @MainActor in QuickEntryController.shared.show(capture: capture) }
    }
}
