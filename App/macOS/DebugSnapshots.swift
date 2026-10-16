#if DEBUG
import AppKit
import TaskerCore

/// Development aid: `TASKER_SNAPSHOT_DIR=/path` makes the app render its own window for each
/// main view into PNGs (no Screen Recording permission needed), then quit.
@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["TASKER_SNAPSHOT_DIR"] else { return }
        let model = AppModel.shared
        var steps: [(String, () -> Void)] = [
            ("inbox", { model.sidebar = .inbox }),
            ("projects", { model.sidebar = .projects; model.expanded.formUnion(model.snapshot.libraryIDs.prefix(4)) }),
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
            ("forecast", { model.sidebar = .forecast }),
            ("tags", { model.sidebar = .tags }),
            ("review", { model.sidebar = .review }),
        ]
        for p in model.snapshot.perspectives.prefix(3) {
            steps.append(("perspective-\(p.name)", { model.sidebar = .perspective(p.id) }))
        }
        steps.append(("edit-perspective", { model.editingPerspective = model.snapshot.perspectives.first }))
        steps.append(("quick-entry", { model.editingPerspective = nil; QuickEntryController.shared.show(capture: .init(title: "Call Anna #pho ::home due:fri", note: "")) }))

        func run(_ i: Int) {
            guard i < steps.count else { NSApp.terminate(nil); return }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                for (n, w) in NSApp.windows.enumerated() where w.isVisible && w.frame.width > 300 {
                    guard let view = w.contentView?.superview ?? w.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(String(format: "%02d", i))-\(steps[i].0)-w\(n).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                run(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run(0) }
    }
}
#endif
