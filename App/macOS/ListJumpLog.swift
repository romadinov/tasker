import AppKit
import SwiftUI

/// Records unexplained jumps of the main list to ~/Library/Logs/Uberdoer/list-jumps.log: whenever the list's scroll
/// position moves by more than 100 pt without the user scrolling, one line with what changed the data last and the
/// list's height before and after. (A jump after completing the last Inbox row couldn't be reproduced on a copy.)
struct ListJumpProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private var observer: NSObjectProtocol?
        private weak var scroll: NSScrollView?
        private var lastY: CGFloat = 0
        private var lastHeight: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        override func layout() {
            super.layout()
            if scroll?.window == nil { attach() }
        }

        /// The probe sits behind the List: watch the table scroll view that covers the same area.
        private func attach() {
            guard let window, let content = window.contentView else { return }
            let mid = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            func find(_ v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView, s.documentView is NSTableView,
                   s.convert(s.bounds, to: nil).contains(mid) { return s }
                for c in v.subviews { if let s = find(c) { return s } }
                return nil
            }
            guard let sv = find(content), sv !== scroll else { return }
            observer.map(NotificationCenter.default.removeObserver)
            scroll = sv
            let clip = sv.contentView
            clip.postsBoundsChangedNotifications = true
            lastY = clip.bounds.minY
            lastHeight = sv.documentView?.frame.height ?? 0
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        private func check() {
            guard let sv = scroll else { return }
            let y = sv.contentView.bounds.minY
            let height = sv.documentView?.frame.height ?? 0
            defer { lastY = y; lastHeight = height }
            let delta = y - lastY
            guard abs(delta) > 100 else { return }
            let event = NSApp.currentEvent?.type
            if event == .scrollWheel || event == .leftMouseDragged || event == .swipe { return }   // the user scrolled
            let m = AppModel.shared
            let ago = Date().timeIntervalSince(m.lastChange.at)
            let line = String(format: "%@  %@  jump %+.0f (y %.0f→%.0f, list height %.0f→%.0f, view %.0f)  last change: %@ %.1fs ago  event: %@  selection: %d\n",
                              ISO8601DateFormatter().string(from: Date()), m.sidebar?.title ?? "-", delta, lastY, y, lastHeight, height,
                              sv.contentView.bounds.height, m.lastChange.cause, ago, event.map { "\($0.rawValue)" } ?? "none", m.selection.count)
            ListJumpLog.append(line)
        }
    }
}

enum ListJumpLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Uberdoer/list-jumps.log")

    static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
