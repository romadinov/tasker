#if DEBUG
import AppKit
import TaskerCore
import Darwin

/// Development aid: `TASKER_DEMO_DIR=<dir>` records the narrated demo (demo/README.md). Each scene runs its
/// actions on a timeline while the app captures its own windows (main window plus Quick Entry, popovers and
/// dropdowns composited on top) at 10 fps into `<dir>/<scene>/`, with an ffconcat list per scene. Scene lengths
/// come from the voiceover's durations.json. No Screen Recording permission needed. Run it on a demo database.
@MainActor
enum DemoRecorder {
    struct Scene { let id: String; let actions: [(Double, () -> Void)] }

    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["TASKER_DEMO_DIR"] else { return false }
        let durations = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir).appending(path: "durations.json")))) as? [String: Double] ?? [:]
        let only = ProcessInfo.processInfo.environment["TASKER_DEMO_SCENES"]?.split(separator: ",").map(String.init)
        let all = scenes().filter { only == nil || only!.contains($0.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { NSApp.terminate(nil); return }
            // Keep the user's own calendar out of the demo; show sync as healthy (it's off for the demo database).
            CalendarModel.shared.hideForDemo()
            AppModel.shared.syncStatus.phase = .idle
            AppModel.shared.syncStatus.lastFetch = Date()
            let savedFrame = main.frame
            main.setFrame(NSRect(x: 80, y: 120, width: 1280, height: 800), display: true)
            @MainActor func run(_ i: Int) {
                guard i < all.count else {
                    main.setFrame(savedFrame, display: false)
                    NSApp.terminate(nil)
                    return
                }
                let scene = all[i]
                let length = (durations[scene.id] ?? 6) + 1.0
                record(scene, length: length, main: main, dir: URL(fileURLWithPath: dir)) { run(i + 1) }
            }
            run(0)
        } }
        return true
    }

    // MARK: Scenes

    static func scenes() -> [Scene] {
        let m = AppModel.shared
        func project(_ title: String) -> String? { m.snapshot.tasks.values.first { $0.isProject && $0.title == title }?.id }
        func tag(_ name: String) -> String? { m.snapshot.tags.values.first { $0.name == name }?.id }
        func task(_ title: String) -> String? { m.snapshot.tasks.values.first { $0.title == title }?.id }
        func select(_ title: String) -> () -> Void { { if let id = task(title) { m.selection = [id] } } }
        return [
            Scene(id: "s01_inbox", actions: [
                (0, { m.sidebar = .inbox; m.selection = [] }),
                (4.5, select("Call the dentist")),
                (7.5, select("Renew passport")),
            ]),
            Scene(id: "s02_quick", actions: [
                (0, { m.selection = [] }),
                (0.6, { QuickEntryController.shared.show(); placeQuickEntry() }),
                (2.0, { type("Book a table for Friday dinner") }),
                (5.6, { key("\t", 48) }),
                (6.0, { type("lisbon") }),
                (7.6, { key("\t", 48) }),
                (8.0, { type("calls") }),
                (9.4, { key("\t", 48) }),
                (10.2, { key(" ", 49) }),
                (11.0, { key("\t", 48) }),
                (11.6, { type("friday") }),
                (13.4, { key("\t", 48) }),
                (14.6, { key("\r", 36) }),
            ]),
            Scene(id: "s03_projects", actions: [
                (0, { m.sidebar = .projects; m.selection = [] }),
                (1.2, { if let p = project("Trip to Lisbon") { m.projectFocus = [p] } }),
                (5.0, { if let p = project("Garden") { m.projectFocus = [p] } }),
                (6.2, { if let p = project("Garden") { m.setProjectStatus([p], .done) } }),
            ]),
            Scene(id: "s04_forecast", actions: [
                (0, { m.sidebar = .forecast; m.selection = [] }),
            ]),
            Scene(id: "s05_board", actions: [
                (0, { m.sidebar = .kanban; m.selection = [] }),
            ]),
            Scene(id: "s06_tags", actions: [
                (0, { m.sidebar = .tags; m.selection = [] }),
                (2.0, { if let t = tag("Calls") { m.tagFocus = [t] } }),
                (4.2, { if let t = tag("Errands") { m.tagFocus = [t] } }),
            ]),
            Scene(id: "s07_outro", actions: [
                (0, { m.sidebar = .flagged; m.selection = [] }),
                (6.5, { if let id = task("Book flights") { m.toggleComplete(id) } }),
                (9.0, { if let id = task("Book the budget review meeting") { m.toggleComplete(id) } }),
            ]),
        ]
    }

    /// Quick Entry normally opens near the top of the screen; in the demo it sits over the main window.
    static func placeQuickEntry() {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1000 }),
              let qe = NSApp.windows.first(where: { $0 is QuickEntryWindow }) else { return }
        qe.setFrameTopLeftPoint(NSPoint(x: main.frame.midX - qe.frame.width / 2, y: main.frame.maxY - 150))
    }

    // MARK: Input

    static func key(_ chars: String, _ code: UInt16) {
        let target = NSApp.keyWindow ?? NSApp.windows.last { $0.isVisible && $0.className.contains("Popover") }
            ?? NSApp.windows.first { $0 is QuickEntryWindow && $0.isVisible } ?? NSApp.mainWindow
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let w = target, let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                         isARepeat: false, keyCode: code) else { continue }
            w.sendEvent(e)
        }
    }

    /// Types like a person: one character every ~70 ms.
    static func type(_ text: String) {
        for (i, c) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) { key(String(c), c == " " ? 49 : 0) }
        }
    }

    // MARK: Capture

    static func record(_ scene: Scene, length: Double, main: NSWindow, dir: URL, done: @escaping @MainActor () -> Void) {
        let out = dir.appending(path: scene.id)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (t, action) in scene.actions { DispatchQueue.main.asyncAfter(deadline: .now() + t) { action() } }
        let start = Date()
        var frames: [(String, Double)] = []
        let writer = DispatchQueue(label: "demo.writer", attributes: .concurrent)
        let group = DispatchGroup()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let image = composite(main) else { return }
                let name = String(format: "f%05d.jpg", frames.count)
                frames.append((name, Date().timeIntervalSince(start)))
                nonisolated(unsafe) let rep = image
                writer.async(group: group) {
                    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])?.write(to: out.appending(path: name))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + length) {
            timer.invalidate()
            // ffconcat: each frame lasts until the next one; the last fills up to the scene length.
            var list = "ffconcat version 1.0\n"
            for (i, f) in frames.enumerated() {
                let end = i + 1 < frames.count ? frames[i + 1].1 : length
                list += "file '\(f.0)'\nduration \(String(format: "%.3f", max(end - f.1, 0.01)))\n"
            }
            if let last = frames.last { list += "file '\(last.0)'\n" }
            group.notify(queue: .global()) {
                try? list.write(to: out.appending(path: "frames.ffconcat"), atomically: true, encoding: .utf8)
                DispatchQueue.main.async { NSLog("TASKER-DEMO %@ %d frames %.1fs", scene.id, frames.count, length); done() }
            }
        }
    }

    /// CGWindowListCreateImage is unavailable to Swift since macOS 15 but still exported; an app may capture its own
    /// windows with it without Screen Recording permission. Debug builds only.
    typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    static let createImage: CreateImage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: CreateImage.self) }

    static func windowImage(_ w: NSWindow) -> CGImage? {
        // optionIncludingWindow = 8; boundsIgnoreFraming = 1, bestResolution = 8.
        createImage?(.null, 8, UInt32(w.windowNumber), 1 | 8)?.takeRetainedValue()
    }

    /// The main window with every visible window of the app that overlaps it drawn on top (panels and popovers
    /// by level), as a 2× bitmap.
    static func composite(_ main: NSWindow) -> NSBitmapImageRep? {
        let region = main.frame
        let scale = main.backingScaleFactor
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width * scale), pixelsHigh: Int(region.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        out.size = region.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: region.size).fill()
        // NSApp.orderedWindows leaves out panels, so order by level with the main window at the bottom.
        let others = NSApp.windows.filter { $0 !== main && $0.isVisible && $0.frame.intersects(region) }
            .sorted { $0.level.rawValue < $1.level.rawValue }
        for w in [main] + others {
            let origin = NSPoint(x: w.frame.minX - region.minX, y: w.frame.minY - region.minY)
            // The window server's image has the real materials (sidebar selection, popovers); cacheDisplay can't draw those.
            if let image = windowImage(w), let cg = NSGraphicsContext.current?.cgContext {
                cg.saveGState()
                // Panels (Quick Entry, popovers) float: give them the shadow the window server adds on screen.
                if w !== main { cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor) }
                cg.draw(image, in: NSRect(origin: origin, size: w.frame.size))
                cg.restoreGState()
                continue
            }
            guard let view = w.contentView?.superview ?? w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            rep.draw(in: NSRect(origin: origin, size: w.frame.size), from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
        }
        return out
    }
}
#endif
