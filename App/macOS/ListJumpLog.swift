import AppKit
import SwiftUI

/// Keeps the main list steady, and records any jump it can't explain.
///
/// SwiftUI's List (an NSTableView with automatic row heights) measures only rows it has shown and guesses the rest
/// from `rowHeight` (24 pt; Uberdoer's rows are ~36). Every data change re-guesses, so after scrolling through the
/// Inbox, adding or completing an item shrank the list by ~1,700 pt and the view jumped, sometimes leaving empty space
/// below the last row. Fixes: a realistic guess, staying at the end when the user was at the end, and never resting
/// past the end of the list.
///
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
        private var frameObserver: NSObjectProtocol?
        /// The user was looking at the last row before the latest change — in this view (`atEndView`), so switching
        /// to another view never scrolls that one to its end.
        private var atEnd = false
        private var atEndView = ""
        /// Typical height of a one-line row with its padding; the table's guess for rows it hasn't measured.
        static let estimatedRowHeight: CGFloat = 36

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
            frameObserver.map(NotificationCenter.default.removeObserver)
            scroll = sv
            let clip = sv.contentView
            clip.postsBoundsChangedNotifications = true
            lastY = clip.bounds.minY
            lastHeight = sv.documentView?.frame.height ?? 0
            (sv.documentView as? NSTableView)?.rowHeight = Self.estimatedRowHeight
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            if let doc = sv.documentView {
                doc.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.contentResized() }
                }
            }
        }

        deinit {
            observer.map(NotificationCenter.default.removeObserver)
            frameObserver.map(NotificationCenter.default.removeObserver)
        }

        /// Largest scroll position that still shows content at the bottom.
        private func endY(_ sv: NSScrollView) -> CGFloat {
            let doc = sv.documentView?.frame.height ?? 0
            return max(-sv.contentInsets.top, doc - sv.contentView.bounds.height + sv.contentInsets.bottom)
        }

        private var table: NSTableView? { scroll?.documentView as? NSTableView }

        /// Whether the last row is on screen (the table's own frame lags its rows right after a change, so ask it
        /// about the row rather than comparing heights).
        private func lastRowVisible() -> Bool {
            guard let tv = table, tv.numberOfRows > 0 else { return false }
            let vis = tv.rows(in: tv.visibleRect)
            return vis.location + vis.length >= tv.numberOfRows
        }

        /// The list's height changed (rows added, removed or re-guessed): if the user was looking at the end, show
        /// the end again (scrollRowToVisible measures the rows it passes); never rest past the end.
        private func contentResized() {
            guard let sv = scroll, let tv = table else { return }
            if tv.rowHeight != Self.estimatedRowHeight { tv.rowHeight = Self.estimatedRowHeight }
            if atEnd && atEndView == AppModel.shared.viewKey {
                guard !restoringEnd else { return }
                restoringEnd = true
                // Once now and once after SwiftUI's follow-up layout passes.
                for delay in [0.0, 0.12, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, let tv = self.table, tv.numberOfRows > 0 else { return }
                        tv.scrollRowToVisible(tv.numberOfRows - 1)
                        if delay == 0.3 { self.restoringEnd = false; self.atEnd = self.lastRowVisible() }
                    }
                }
                return
            }
            let clip = sv.contentView
            if clip.bounds.minY > endY(sv) + 1 {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: endY(sv)))
                sv.reflectScrolledClipView(clip)
            }
        }
        private var restoringEnd = false

        private func check() {
            guard let sv = scroll else { return }
            // Remember whether the user is looking at the last row; a resize then keeps it in view.
            let event = NSApp.currentEvent?.type
            if !restoringEnd { atEnd = lastRowVisible(); atEndView = AppModel.shared.viewKey }
            if sv.contentView.bounds.minY > endY(sv) + 1 { DispatchQueue.main.async { [weak self] in self?.contentResized() } }
            let y = sv.contentView.bounds.minY
            let height = sv.documentView?.frame.height ?? 0
            defer { lastY = y; lastHeight = height }
            let delta = y - lastY
            guard abs(delta) > 100 else { return }
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
