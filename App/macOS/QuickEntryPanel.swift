import AppKit
import SwiftUI
import TaskerCore

/// Floating, non-activating panel (like Spotlight): it takes keyboard focus without pulling
/// Tasker's main window forward, and focus goes back to the previous app on close.
final class QuickEntryWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class QuickEntryController {
    static let shared = QuickEntryController()
    private var panel: QuickEntryWindow?

    func show(capture: AppModel.Capture = .init()) {
        panel?.close()
        let panel = QuickEntryWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 230),
                                     styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                                     backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let root = QuickEntryForm(capture: capture, onDone: { [weak panel] in panel?.close() })
            .environment(AppModel.shared)
            .frame(width: 620)
            .background(.regularMaterial)
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}
