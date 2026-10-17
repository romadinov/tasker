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
        let panel = QuickEntryWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
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
        panel.standardWindowButton(.closeButton)?.isHidden = true

        let root = QuickEntryForm(capture: capture, onDone: { [weak panel] in panel?.close() })
            .environment(AppModel.shared)
            .frame(width: 640)
            .background(Color(nsColor: .textBackgroundColor))
            .ignoresSafeArea(.container, edges: .top) // no empty strip where the hidden title bar is
        // The window follows the form's size (extra fields, inline dropdown fields).
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        panel.setContentSize(controller.view.fittingSize)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}
