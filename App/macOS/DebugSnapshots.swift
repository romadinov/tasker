#if DEBUG
import AppKit
import WhisperKit
import TaskerCore

/// Development aid: `TASKER_SNAPSHOT_DIR=/path` makes the app render its own window for each
/// main view into PNGs (no Screen Recording permission needed), then quit.
@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        // TASKER_WHISPER_TEST=a.wav,b.wav: transcribe files with the app's Whisper path, log, quit.
        if let files = ProcessInfo.processInfo.environment["TASKER_WHISPER_TEST"] {
            Task { @MainActor in
                let t0 = Date()
                _ = await WhisperModel.shared.prepare()
                NSLog("TASKER-WHISPER ready in %.1fs status=%@", Date().timeIntervalSince(t0), String(describing: WhisperModel.shared.status))
                for f in files.split(separator: ",").map(String.init) {
                    let audio = (try? AudioProcessor.loadAudioAsFloatArray(fromPath: f)) ?? []
                    let t1 = Date()
                    let text = await WhisperModel.shared.transcribe(audio, language: nil, expected: ["ru", "en"], fallback: "ru")
                    NSLog("TASKER-WHISPER %@ (%.1fs audio, %.2fs): %@", (f as NSString).lastPathComponent, Double(audio.count) / 16000, Date().timeIntervalSince(t1), text)
                }
                NSApp.terminate(nil)
            }
            return
        }
        guard let dir = ProcessInfo.processInfo.environment["TASKER_SNAPSHOT_DIR"] else { return }
        let model = AppModel.shared
        var steps: [(String, () -> Void)] = [
            ("inbox", { model.sidebar = .inbox }),
            ("projects", { model.sidebar = .projects; model.expanded.formUnion(model.snapshot.libraryIDs.prefix(4)) }),
            ("project-focus", {
                if let p = model.snapshot.orderedProjects.first(where: { (model.snapshot.projectInfo[$0.id]?.remainingCount ?? 0) > 3 }) {
                    model.projectFocus = [p.id]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.selection = [p.id] }
                }
            }),
            ("project-selected", {
                if let p = model.snapshot.orderedProjects.first(where: { model.snapshot.info[$0.id]?.isRemaining == true && (model.snapshot.projectInfo[$0.id]?.remainingCount ?? 0) > 2 }) {
                    var cur: String? = model.snapshot.projectInfo[p.id]?.folderID
                    while let c = cur { model.expanded.insert(c); cur = model.snapshot.folders[c]?.position.parent }
                    model.expanded.insert(p.id)
                    model.selection = [p.id]
                }
            }),
            ("task-selected", {
                if let t = model.snapshot.tasks.values.first(where: { !$0.isProject && $0.repeatRule != nil && model.snapshot.info[$0.id]?.isRemaining == true }) {
                    model.sidebar = .flagged; model.selection = [t.id]
                }
            }),
            ("rename-in-sidebar", {
                model.sidebar = .projects; model.selection = []
                if let f = model.snapshot.libraryIDs.first(where: { model.snapshot.folders[$0] != nil }) { model.renamingID = f }
            }),
            ("rename-done", { model.renamingID = nil }),
            ("analytics", { model.sidebar = .analytics }),
            ("forecast", { model.sidebar = .forecast }),
            ("tags", { model.sidebar = .tags }),
            ("review", { model.sidebar = .review }),
        ]
        for p in model.snapshot.perspectives.prefix(3) {
            steps.append(("perspective-\(p.name)", { model.sidebar = .perspective(p.id) }))
        }
        steps.append(("edit-perspective", { model.editingPerspective = model.snapshot.perspectives.first }))
        steps.append(("inspector-autocomplete", {
            model.editingPerspective = nil
            model.sidebar = .inbox
            if let id = model.snapshot.inboxIDs.first(where: { model.snapshot.info[$0]?.isRemaining == true }) {
                model.selection = [id]
                // Give the list keyboard focus so the selection is drawn emphasised (blue), as when you click it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let w = NSApp.windows.first(where: { $0.frame.width > 600 }),
                       let table = w.contentView.flatMap({ findTable($0) }) { w.makeFirstResponder(table) }
                }
            }
        }))
        steps.append(("new-action", {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
            model.sidebar = .inbox; model.selection = []; model.newTask()
        }))
        steps.append(("new-action-focus", {
            let r = NSApp.windows.first { $0.frame.width > 600 }?.firstResponder
            let editingField = (r as? NSTextView)?.delegate is AutoFocusTextField
            NSLog("TASKER-FOCUS first responder: \(String(describing: r.map { type(of: $0) })) inlineField=\(editingField)")
        }))
        steps.append(("forecast-calendar", { model.sidebar = .forecast }))
        steps.append(("project-combo", {
            model.sidebar = .inbox
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let id = model.sections().flatMap(\.rows).dropFirst(1).first?.id {
                    model.selection = [id]
                    model.projectEditingSeed = "нт"
                    model.inlineField = .init(id: id, field: .project)
                }
            }
        }))
        steps.append(("tags-combo", { if let id = model.selection.first { model.inlineField = .init(id: id, field: .tags) } }))
        steps.append(("tags-return-next", {
            if let id = model.selection.first {
                model.editNextTask(after: id)
                NSLog("TASKER-NEXT from=%@ to=%@ field=%@", id, model.selection.first ?? "-", String(describing: model.inlineField?.field))
            }
        }))
        steps.append(("flag-focus", { if let id = model.selection.first { model.inlineField = .init(id: id, field: .flag) } }))
        steps.append(("inspector-menu-off", {
            model.inlineField = nil
            // Press the real menu item, as the user would.
            func find(_ menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.title.contains("Inspector") { return item }
                    if let f = find(item.submenu) { return f }
                }
                return nil
            }
            if let item = find(NSApp.mainMenu), let menu = item.menu {
                menu.performActionForItem(at: menu.index(of: item))
                NSLog("TASKER-INSP pressed menu '\(item.title)' → showInspector=\(model.showInspector)")
            } else { NSLog("TASKER-INSP menu item not found") }
        }))
        steps.append(("inspector-toolbar-on", {
            // Press the real toolbar button.
            let w = NSApp.windows.first { $0.frame.width > 600 }
            let items = w?.toolbar?.items ?? []
            NSLog("TASKER-INSP toolbar items: \(items.map { $0.itemIdentifier.rawValue })")
            for it in items where ["inspect", "newAction"].contains(it.itemIdentifier.rawValue) {
                NSLog("TASKER-INSP item \(it.itemIdentifier.rawValue) action=\(String(describing: it.action)) target=\(String(describing: it.target)) view=\(String(describing: it.view.map { type(of: $0) })) button=\(findButton(it.view) != nil)")
            }
            if let item = items.first(where: { $0.itemIdentifier.rawValue == "inspect" }), let v = item.view, let win = v.window {
                // A real click: mouse down/up at the button's centre, routed through the window.
                let before = model.showInspector
                let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        win.sendEvent(e)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSLog("TASKER-INSP clicked toolbar Inspect: \(before) → \(model.showInspector)")
                }
            } else { NSLog("TASKER-INSP toolbar item not found") }
        }))
        steps.append(("click-tags", {
            model.inlineField = nil
            model.sidebar = .inbox
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let id = model.sections().flatMap(\.rows).dropFirst(2).first?.id else { return }
                model.selection = [id]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Find the "Tags" button through Accessibility and click it like a user.
                    let app = AXUIElementCreateApplication(getpid())
                    func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
                        var help: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXHelpAttribute as CFString, &help)
                        if (help as? String)?.hasPrefix("Tags —") == true { return el }
                        guard depth < 40 else { return nil }
                        var kids: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
                        for k in (kids as? [AXUIElement]) ?? [] { if let f = find(k, depth + 1) { return f } }
                        return nil
                    }
                    guard let el = find(app, 0) else { NSLog("TASKER-CLICKTAGS button not found (AX trusted=%d)", AXIsProcessTrusted() ? 1 : 0); return }
                    var posV: CFTypeRef?, sizeV: CFTypeRef?
                    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV)
                    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV)
                    var pos = CGPoint.zero, size = CGSize.zero
                    AXValueGetValue(posV as! AXValue, .cgPoint, &pos); AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
                    // The Tags element's y after the click (to detect the row jumping); re-found via AX.
                    func rowY() -> CGFloat {
                        guard let e = find(app, 0) ?? findAddTag(app, 0) else { return -1 }
                        var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &v)
                        var p = CGPoint.zero; if let v { AXValueGetValue(v as! AXValue, .cgPoint, &p) }; return p.y
                    }
                    func findAddTag(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
                        var ph: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXPlaceholderValueAttribute as CFString, &ph)
                        if (ph as? String) == "Add tag" { return el }
                        guard depth < 40 else { return nil }
                        var kids: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
                        for k in (kids as? [AXUIElement]) ?? [] { if let f = findAddTag(k, depth + 1) { return f } }
                        return nil
                    }
                    guard let win = NSApp.windows.first(where: { $0.frame.width > 600 }), let screen = win.screen ?? NSScreen.main else { return }
                    // AX uses top-left screen coordinates; AppKit windows use bottom-left.
                    let screenPoint = CGPoint(x: pos.x + size.width / 2, y: screen.frame.maxY - (pos.y + size.height / 2))
                    let p = win.convertPoint(fromScreen: screenPoint)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { win.sendEvent(e) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let panel = NSApp.windows.first { $0 is DropdownPanel && $0.isVisible }
                        // Gap between the field's bottom and the list's top (screen points), and whether the row moved.
                        var gap = -1.0
                        if let panel, let f = NSApp.windows.first(where: { $0.frame.width > 600 })?.firstResponder as? NSTextView,
                           let fw = f.window {
                            let fr = fw.convertToScreen(f.convert(f.bounds, to: nil))
                            gap = fr.minY - panel.frame.maxY
                        }
                        NSLog("TASKER-CLICKTAGS after click: inlineField=%@ panelVisible=%d gap=%.0f rowYBefore=%.0f rowYAfter=%.0f",
                              String(describing: model.inlineField?.field), panel != nil ? 1 : 0, gap, pos.y, rowY())
                    }
                }
            }
        }))
        steps.append(("tags-escape", {
            model.inlineField = nil; model.editingID = nil
            model.sidebar = .flagged
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let id = model.sections().flatMap(\.rows).map(\.id).first(where: { (model.snapshot.tasks[$0]?.tagIDs.count ?? 0) >= 1 }) else { return }
                let before = model.snapshot.tasks[id]!.tagIDs
                model.selection = [id]
                model.openInline(id, .tags)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let win = NSApp.windows.first(where: { $0.frame.width > 600 }) else { return }
                    let fr = String(describing: win.firstResponder.map { type(of: $0) })
                    func key(_ ch: String, _ code: UInt16) {
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: win.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                        isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
                        }
                    }
                    key("\u{7f}", 51) // Backspace: removes the last tag
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let mid = model.snapshot.tasks[id]?.tagIDs.count ?? -1
                        key("\u{1b}", 53) // Escape: should put it back
                        NSLog("TASKER-ESC afterBackspace=%d", mid)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let after = model.snapshot.tasks[id]?.tagIDs ?? []
                        NSLog("TASKER-ESC frBefore=%@ tagsBefore=%d tagsAfter=%d inlineField=%@ selection=%d editing=%@", fr, before.count, after.count,
                              String(describing: model.inlineField?.field), model.selection.count, model.editingID ?? "nil")
                    }
                }
            }
        }))
        steps.append(("tags-backspace", {
            model.inlineField = nil; model.editingID = nil
            model.sidebar = .flagged
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let id = model.sections().flatMap(\.rows).map(\.id).first(where: { (model.snapshot.tasks[$0]?.tagIDs.count ?? 0) >= 1 }) else {
                    NSLog("TASKER-TAGDEL no tagged row"); return
                }
                let before = model.snapshot.tasks[id]!.tagIDs
                model.selection = [id]
                model.inlineField = .init(id: id, field: .tags)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let win = NSApp.windows.first(where: { $0.frame.width > 600 }) else { return }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: win.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                                    isARepeat: false, keyCode: 51) { NSApp.postEvent(e, atStart: false) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let after = model.snapshot.tasks[id]?.tagIDs ?? []
                        NSLog("TASKER-TAGDEL before=%d after=%d removedLast=%d fieldFocused=%d", before.count, after.count,
                              after == Array(before.dropLast()) ? 1 : 0, win.firstResponder is NSTextView ? 1 : 0)
                    }
                }
            }
        }))
        steps.append(("return-adds-below", {
            model.inlineField = nil; model.editingID = nil
            model.sidebar = .inbox
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let rows = model.sections().flatMap(\.rows)
                guard rows.count > 4 else { return }
                let sel = rows[2].id
                model.selection = [sel]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let win = NSApp.windows.first(where: { $0.frame.width > 600 }) else { return }
                    func table(_ v: NSView) -> NSTableView? { if let t = v as? NSTableView, t.numberOfRows > 4 { return t }; for c in v.subviews { if let t = table(c) { return t } }; return nil }
                    if let t = win.contentView.flatMap(table) { win.makeFirstResponder(t) }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: win.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                    isARepeat: false, keyCode: 36) { NSApp.postEvent(e, atStart: false) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let now = model.sections().flatMap(\.rows).map(\.id)
                        let e = model.editingID ?? "nil"
                        NSLog("TASKER-RETURN editing=%@ newIsBelow=%d editorFocused=%d", e,
                              (now.firstIndex(of: sel).map { now.indices.contains($0 + 1) && now[$0 + 1] == e } ?? false) ? 1 : 0,
                              win.firstResponder is NSTextView ? 1 : 0)
                    }
                }
            }
        }))
        steps.append(("space-in-project-field", {
            model.inlineField = nil; model.editingID = nil
            model.sidebar = .inbox
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let id = model.sections().flatMap(\.rows).first?.id else { return }
                model.selection = [id]
                model.inlineField = .init(id: id, field: .project)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let win = NSApp.windows.first(where: { $0.frame.width > 600 }) else { return }
                    for (type, chars) in [(NSEvent.EventType.keyDown, "a"), (.keyUp, "a"), (.keyDown, " "), (.keyUp, " ")] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                    isARepeat: false, keyCode: chars == " " ? 49 : 0) { NSApp.postEvent(e, atStart: false) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        NSLog("TASKER-SPACE completed=%d fieldText='%@' firstResponder=%@", model.snapshot.tasks[id]?.isCompleted == true ? 1 : 0,
                              (win.firstResponder as? NSTextView)?.string ?? "-", String(describing: type(of: win.firstResponder as Any)))
                    }
                }
            }
        }))
        steps.append(("dblclick-title", {
            // Project field open on one row, then a real double-click on another row's title.
            model.inlineField = nil; model.editingID = nil
            model.sidebar = .inbox
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let rows = model.sections().flatMap(\.rows)
                guard rows.count > 6, let target = model.snapshot.tasks[rows[5].id], !target.title.isEmpty else { return }
                model.selection = [rows[2].id]
                model.inlineField = .init(id: rows[2].id, field: .project)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let app = AXUIElementCreateApplication(getpid())
                    func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
                        var v: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
                        if (v as? String) == target.title { return el }
                        guard depth < 40 else { return nil }
                        var kids: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
                        for k in (kids as? [AXUIElement]) ?? [] { if let f = find(k, depth + 1) { return f } }
                        return nil
                    }
                    func frame(_ el: AXUIElement) -> CGRect {
                        var posV: CFTypeRef?, sizeV: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV)
                        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV)
                        var pos = CGPoint.zero, size = CGSize.zero
                        if let posV { AXValueGetValue(posV as! AXValue, .cgPoint, &pos) }
                        if let sizeV { AXValueGetValue(sizeV as! AXValue, .cgSize, &size) }
                        return CGRect(origin: pos, size: size)
                    }
                    guard let el = find(app, 0) else { NSLog("TASKER-DBL title not found"); return }
                    let r = frame(el)
                    guard let win = NSApp.windows.first(where: { $0.frame.width > 600 }), let screen = win.screen ?? NSScreen.main else { return }
                    let p = win.convertPoint(fromScreen: CGPoint(x: r.minX + 20, y: screen.frame.maxY - r.midY))
                    let t0 = ProcessInfo.processInfo.systemUptime
                    // Like a person: the second click ~0.15 s after the first.
                    func click(_ n: Int) {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                        }
                    }
                    click(1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { click(2) }
                    for delay in [0.25, 0.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            let editor = (win.firstResponder as? NSTextView)?.string
                            let rowNow = find(app, 0).map(frame) ?? .zero
                            NSLog("TASKER-DBL selection=%@ +%.2fs editingID=%@ (target %@) firstResponder=%@ inlineField=%@ yBefore=%.0f yNow=%.0f",
                                  model.selection.joined(separator: ","), ProcessInfo.processInfo.systemUptime - t0, model.editingID ?? "nil", target.id, editor ?? "-",
                                  String(describing: model.inlineField?.field), r.minY, rowNow == .zero ? -1 : rowNow.minY)
                        }
                    }
                }
            }
        }))
        steps.append(("reorder", {
            model.sidebar = .inbox
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // 1. Inbox: 4th row to the top.
                var rows = model.sections().flatMap(\.rows)
                let fourth = rows[3].id
                model.moveRows(IndexSet(integer: 3), to: 0, in: rows)
                rows = model.sections().flatMap(\.rows)
                NSLog("TASKER-REORDER inbox: moved to index %d", rows.firstIndex { $0.id == fourth } ?? -1)
                // 2. A task dropped right below an open project becomes its first action.
                let s = model.snapshot
                if let p = s.orderedProjects.first(where: { (s.projectInfo[$0.id]?.remainingCount ?? 0) > 1 }) {
                    let projectRow = OutlineRow(id: p.id, kind: .project, depth: 0, hasChildren: true, expanded: true, showContext: false)
                    let taskRow = OutlineRow(id: fourth, kind: .task, depth: 0, hasChildren: false, expanded: false, showContext: false)
                    model.moveRows(IndexSet(integer: 1), to: 1, in: [projectRow, taskRow])
                    let after = model.snapshot
                    NSLog("TASKER-REORDER into project: parent=%@ firstChild=%@", after.info[fourth]?.parentID == p.id ? "ok" : "WRONG", after.childIDs(p.id).first == fourth ? "ok" : "WRONG")
                }
                // 3. A project dropped after another folder in the library outline.
                let s2 = model.snapshot
                let folders = s2.libraryIDs.filter { s2.folders[$0] != nil }
                if folders.count >= 2, let proj = s2.childIDs(folders[0]).first(where: { s2.tasks[$0]?.isProject == true }) {
                    let a = OutlineRow(id: proj, kind: .project, depth: 1, hasChildren: false, expanded: false, showContext: false)
                    let b = OutlineRow(id: folders[1], kind: .folder, depth: 0, hasChildren: true, expanded: false, showContext: false)
                    model.moveRows(IndexSet(integer: 0), to: 2, in: [a, b])
                    let after = model.snapshot
                    let idx = after.libraryIDs.firstIndex(of: proj)
                    let fidx = after.libraryIDs.firstIndex(of: folders[1])
                    NSLog("TASKER-REORDER project after folder: %@", (idx != nil && fidx != nil && idx! == fidx! + 1) ? "ok" : "WRONG")
                }
            }
        }))
        steps.append(("file-in-place", {
            model.sidebar = .inbox
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let before = model.sections().flatMap(\.rows).map(\.id)
                guard before.count > 3, let project = model.snapshot.orderedProjects.first(where: { model.snapshot.info[$0.id]?.isRemaining == true }) else { return }
                let id = before[2]
                model.selection = [id]
                model.assignProject([id], project.id)
                let after = model.sections().flatMap(\.rows).map(\.id)
                model.perform("Tag") { tx in if let tag = model.snapshot.orderedTags.first?.tag.id { tx.setTag(id, tag, true) } }
                let afterTag = model.sections().flatMap(\.rows).map(\.id)
                NSLog("TASKER-FILE before=\(before.firstIndex(of: id) ?? -1) afterProject=\(after.firstIndex(of: id) ?? -1) afterTag=\(afterTag.firstIndex(of: id) ?? -1) neighboursSame=\(Array(before.prefix(6)) == Array(afterTag.prefix(6)))")
                model.cleanUp()
                NSLog("TASKER-FILE afterCleanUp present=\(model.sections().flatMap(\.rows).contains { $0.id == id })")
                _ = model.store.undo // keep the scratch DB realistic; nothing else to do
            }
        }))
        steps.append(("quick-entry", { model.editingPerspective = nil; QuickEntryController.shared.show(capture: .init()) }))

        if ProcessInfo.processInfo.environment["TASKER_STRESS"] != nil {
            // Rapidly flip between perspectives with and without a sidebar (toolbar race regression test).
            let items: [SidebarItem] = [.inbox, .tags, .flagged, .forecast, .projects, .nearby, .review] + model.snapshot.perspectives.prefix(2).map { .perspective($0.id) }
            steps = (0..<60).map { i in ("stress-\(i)", { model.sidebar = items[i % items.count] }) }
        }
        func run(_ i: Int) {
            guard i < steps.count else { NSApp.terminate(nil); return }
            steps[i].1()
            let stress = ProcessInfo.processInfo.environment["TASKER_STRESS"] != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (stress ? 0.15 : 1.2)) {
                if stress { run(i + 1); return }
                for (n, w) in NSApp.windows.enumerated() where w.isVisible && (w.frame.width > 300 || w is DropdownPanel) {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(String(format: "%02d", i))-\(steps[i].0)-w\(n).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                run(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
            run(0)
        }
    }
}
func findButton(_ v: NSView?) -> NSButton? {
    guard let v else { return nil }
    if let b = v as? NSButton { return b }
    for s in v.subviews { if let b = findButton(s) { return b } }
    return nil
}

func findTable(_ v: NSView) -> NSView? {
    if v is NSTableView { return v }
    for s in v.subviews { if let t = findTable(s) { return t } }
    return nil
}
#endif
