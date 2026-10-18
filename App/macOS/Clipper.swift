import AppKit
import ApplicationServices
import os
import SwiftUI
import TaskerCore

private let clipLog = Logger(subsystem: "Uberdoer", category: "clip")

/// The clipper: captures what you're looking at in the frontmost app.
/// - Browsers (Safari, Chrome, Arc, Brave, Edge, Vivaldi, Orion): page title + URL (+ selected text)
/// - Mail: subject + message:// link
/// - Mimestream: subject + the message's deep link (Mimestream copies it on ⌘C)
/// - Slack: the highlighted message's link (Slack copies it on "L") + selected text
/// - Anything else: selected text (Accessibility)
/// Normal clip opens Quick Entry pre-filled; Quick Clip saves straight to the Inbox.
@MainActor
enum Clipper {
    enum Problem: CustomStringConvertible {
        case noAccessibility
        case selectMessage(String)
        case info(String)
        var description: String {
            switch self {
            case .noAccessibility: "Uberdoer needs Accessibility access to link emails and Slack messages. Allow it in System Settings → Privacy & Security → Accessibility."
            case .selectMessage(let s), .info(let s): s
            }
        }
    }
    static var problem: Problem?

    static func clipFrontmost(quick: Bool = false) {
        let capture = capture()
        if let problem {
            Toast.show(problemTitle(problem), detail: problem.description, seconds: 5)
            if case .noAccessibility = problem { requestAccessibility() }
        }
        if quick {
            let title = capture.title.isEmpty ? "Clipping" : capture.title
            if AppModel.shared.quickAdd(title: title, note: capture.note, projectID: nil, tagIDs: [], flagged: false, deferDate: nil, dueDate: nil) != nil,
               problem == nil {
                Toast.show("Clipped to Inbox", detail: title)
            }
        } else {
            QuickEntryController.shared.show(capture: capture)
        }
    }

    static func capture() -> AppModel.Capture {
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier ?? ""
        var capture = AppModel.Capture()
        var link: String?
        problem = nil
        let selection = selectedText()

        switch bundle {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS":
            if let r = runScript("tell application id \"\(bundle)\" to return {name of current tab of front window, URL of current tab of front window}") {
                capture.title = r.first ?? ""
                link = r.dropFirst().first
            }
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.google.Chrome.canary":
            if let r = runScript("tell application id \"\(bundle)\" to return {title of active tab of front window, URL of active tab of front window}") {
                capture.title = r.first ?? ""
                link = r.dropFirst().first
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
                link = "message://%3C\(id)%3E"
                if r.count > 2 { capture.note = "From: \(r[2])" }
            }
        case "com.mimestream.Mimestream":
            // ⌘C on a selected message or thread (in the message list) copies its link.
            if !AXIsProcessTrusted() {
                problem = .noAccessibility
            } else if let copied = copyViaKeystroke(keyCode: 8, flags: .maskCommand) {
                link = copied.url
                // The email subject comes as the link's name; never use a URL or the mailbox name as the title.
                if let t = copied.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, firstURL(in: t) == nil {
                    capture.title = String(t.prefix(150))
                }
                if link == nil { problem = .selectMessage("Select the email in Mimestream's message list, then clip.") }
            } else {
                problem = .selectMessage("Select the email in Mimestream's message list, then clip.")
            }
            if capture.title.isEmpty {
                // Window titles are the mailbox ("Inbox: Primary") unless a message window is open.
                let w = focusedWindowTitle(of: app).map(cleanMimestreamTitle) ?? ""
                capture.title = w.hasPrefix("Inbox") || w.contains(": ") && !w.contains(" ") ? "Email" : w
            }
        case "com.romadinov.reader.mac":
            // Scriptorium: ⌃⌘C "Copy Link" puts the deep link (public.url, scriptorium://open?doc=…&page=…)
            // and "Book — p. N" (public.url-name) on the clipboard. Selected text comes via Accessibility.
            if !AXIsProcessTrusted() {
                problem = .noAccessibility
            } else if let copied = copyViaKeystroke(keyCode: 8, flags: [.maskControl, .maskCommand]), let url = copied.url {
                link = url
                if let t = copied.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, Links.find(in: t).isEmpty {
                    capture.title = String(t.prefix(150))
                }
            } else {
                problem = .selectMessage("Scriptorium didn't provide a link. Update Scriptorium (it needs Edit → Copy Link, ⌃⌘C).")
            }
            if capture.title.isEmpty { capture.title = focusedWindowTitle(of: app) ?? "Scriptorium" }
        case "com.tinyspeck.slackmacgap":
            // "L" copies the link of the highlighted message, but would type into the composer,
            // so only send it when a text field doesn't have focus.
            if !AXIsProcessTrusted() {
                problem = .noAccessibility
            } else if !focusedElementIsTextInput(), let copied = copyViaKeystroke(keyCode: 37, flags: []),
                      let url = copied.url, url.contains("slack.com") {
                link = url
            } else if let recent = recentClipboardURL(containing: "slack.com/archives") {
                link = recent
            } else if let channel = slackChannelURL(app) {
                // No highlighted message (e.g. typing in the composer): link to the channel/thread instead.
                link = channel
                problem = .info("Linked the Slack channel. To link a single message, hover it (or ↑ to it) before clipping.")
            }
            let channel = focusedWindowTitle(of: app)?.components(separatedBy: " - ").first
            capture.title = channel.map { "Slack: \($0)" } ?? "Slack message"
        default:
            if let r = focusedWindowTitle(of: app), !r.isEmpty { capture.title = r }
            else { capture.title = app?.localizedName.map { "From \($0)" } ?? "" }
        }

        if let selection, !selection.isEmpty {
            let firstLine = selection.split(separator: "\n").first.map(String.init) ?? selection
            if bundle != "com.romadinov.reader.mac" && (bundle == "com.tinyspeck.slackmacgap" || capture.title.isEmpty || capture.title.hasPrefix("From ")) {
                capture.title = String(firstLine.prefix(120))
            }
            capture.note = [capture.note, selection].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        // The link goes first so it's the first thing visible in the note.
        if let link, !link.isEmpty {
            capture.note = [link, capture.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        clipLog.info("clip app=\(bundle, privacy: .public) trusted=\(AXIsProcessTrusted()) title=\(capture.title, privacy: .public) link=\(link ?? "-", privacy: .public) problem=\(String(describing: problem), privacy: .public)")
        return capture
    }

    // MARK: Helpers

    static func problemTitle(_ p: Problem) -> String {
        switch p {
        case .noAccessibility: "Link not captured"
        case .selectMessage: "Link not captured"
        case .info: "Clipped with channel link"
        }
    }

    /// The Slack window's current web URL (channel or thread), via Accessibility.
    static func slackChannelURL(_ app: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted(), let pid = app?.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        func search(_ el: AXUIElement, depth: Int) -> String? {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" {
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &url) == .success {
                    if let u = url as? URL { return u.absoluteString }
                    if let s = url as? String { return s }
                }
            }
            guard depth < 8 else { return nil }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
            for k in (kids as? [AXUIElement]) ?? [] { if let r = search(k, depth: depth + 1) { return r } }
            return nil
        }
        guard let raw = search(window as! AXUIElement, depth: 0), raw.contains("slack.com") else { return nil }
        return raw
    }

    static func cleanMimestreamTitle(_ t: String) -> String {
        // Window titles look like "Subject — account@gmail.com"; keep the subject.
        t.components(separatedBy: " — ").first ?? t
    }

    static func firstURL(in s: String) -> String? {
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return det?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.url?.absoluteString
    }

    private static var lastSeenChange = (count: NSPasteboard.general.changeCount, at: Date())

    static func recentClipboardURL(containing needle: String) -> String? {
        let pb = NSPasteboard.general
        guard let s = pb.string(forType: .string), s.contains(needle) else { return nil }
        return firstURL(in: s)
    }

    /// Sends a keystroke to the frontmost app and returns what it put on the clipboard,
    /// then restores the clipboard. Needs Accessibility permission.
    static func copyViaKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) -> (text: String?, url: String?)? {
        guard AXIsProcessTrusted() else { return nil }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        } ?? []
        // The hotkey fires while its modifiers are still held; wait for release so they don't
        // combine with the synthetic keystroke (e.g. ⌃⌥⇧L instead of L).
        let mods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let releaseBy = Date().addingTimeInterval(1.5)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(mods).isEmpty && Date() < releaseBy {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        let deadline = Date().addingTimeInterval(0.8)
        while pb.changeCount == before && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        guard pb.changeCount != before else {
            clipLog.info("keystroke \(keyCode) put nothing on the clipboard")
            return nil
        }
        // Apps put links in different flavours: URL, plain text, or only inside rich text/HTML.
        let types = pb.types?.map(\.rawValue) ?? []
        // A link's title travels as "public.url-name" (Mimestream puts the email subject there).
        let text = pb.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? pb.string(forType: .string)
        var url = pb.string(forType: .URL) ?? pb.string(forType: NSPasteboard.PasteboardType("public.url"))
        if url == nil, let t = text { url = firstURL(in: t) }
        if url == nil, let html = pb.string(forType: .html), let r = html.range(of: #"href="([^"]+)""#, options: .regularExpression) {
            url = String(html[r]).replacingOccurrences(of: "href=\"", with: "").dropLast().description
        }
        if url == nil, let rtf = pb.data(forType: .rtf),
           let a = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            a.enumerateAttribute(.link, in: NSRange(location: 0, length: a.length)) { v, _, stop in
                if let u = v as? URL { url = u.absoluteString; stop.pointee = true }
                else if let s = v as? String { url = s; stop.pointee = true }
            }
        }
        clipLog.info("keystroke \(keyCode) clipboard types=\(types.joined(separator: ","), privacy: .public) url=\(url ?? "-", privacy: .public) name=\(text ?? "-", privacy: .public)")
        let result: (text: String?, url: String?) = (text, url)
        // Put the user's clipboard back.
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, v) in dict { item.setData(v, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        return result
    }

    static func focusedElementIsTextInput() -> Bool {
        guard AXIsProcessTrusted() else { return true }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let r = role as? String ?? ""
        return r == kAXTextAreaRole || r == kAXTextFieldRole || r == "AXComboBox"
    }

    static func focusedWindowTitle(of app: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted(), let pid = app?.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return (title as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Selected text from the focused element of the frontmost app (needs Accessibility).
    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
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
            NSLog("Uberdoer clipper: \(error ?? [:])")
            return nil
        }
        if result.numberOfItems == 0 { return result.stringValue.map { [$0] } }
        return (1...result.numberOfItems).map { result.atIndex($0)?.stringValue ?? "" }
    }
}

/// Brief confirmation bubble for Quick Clip (doesn't take focus).
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ title: String, detail: String, seconds: Double = 1.8) {
        panel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        p.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 90))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if panel === p { p.close(); panel = nil }
        }
    }
}

/// Services menu: "Send to Uberdoer" from any app (assign a shortcut in System Settings → Keyboard).
final class ServicesProvider: NSObject {
    @objc func sendToInbox(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string) ?? pboard.string(forType: .URL) ?? ""
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let capture = AppModel.Capture(title: String(firstLine.prefix(120)), note: text == firstLine ? "" : text)
        Task { @MainActor in QuickEntryController.shared.show(capture: capture) }
    }
}
