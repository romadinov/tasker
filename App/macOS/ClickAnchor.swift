import AppKit

/// Selected rows show extra fields, so changing the selection resizes rows. When a row above the
/// clicked one shrinks, everything below moves up under the pointer: the click "jumps", and the
/// second click of a double-click lands on another row. This keeps the clicked row where it was
/// by scrolling the list by however much it moved.
@MainActor
enum ClickAnchor {
    /// Call when the selection changed. Returns false when the list is scrolled to the top, so a row
    /// above the click that shrinks can't be made up for by scrolling (the caller keeps it open instead).
    @discardableResult
    static func keepClickedRowInPlace() -> Bool {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
              let win = event.window, let content = win.contentView else { return true }
        let p = event.locationInWindow
        guard let hit = content.hitTest(content.convert(p, from: nil)),
              let table = enclosing(NSTableView.self, of: hit), let scroll = table.enclosingScrollView else { return true }
        let row = table.row(at: table.convert(p, from: nil))
        guard row >= 0 else { return true }
        let clip = scroll.contentView
        // The list scrolls under the toolbar, so its top position is negative.
        let minY = -scroll.contentInsets.top
        let before = table.rect(ofRow: row).minY - clip.bounds.minY
        // Row heights update over the next few layout passes.
        for delay in [0.0, 0.03, 0.08, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard row < table.numberOfRows else { return }
                let now = table.rect(ofRow: row).minY - clip.bounds.minY
                let delta = now - before
                guard abs(delta) >= 1 else { return }
                var origin = clip.bounds.origin
                origin.y = max(minY, origin.y + delta)
                clip.setBoundsOrigin(origin)
                scroll.reflectScrolledClipView(clip)
            }
        }
        // Room to scroll back up by at least a selected row's extra height?
        return clip.bounds.minY - minY >= 90
    }

    private static func enclosing<T: NSView>(_ type: T.Type, of view: NSView) -> T? {
        var v: NSView? = view
        while let cur = v { if let t = cur as? T { return t }; v = cur.superview }
        return nil
    }
}
