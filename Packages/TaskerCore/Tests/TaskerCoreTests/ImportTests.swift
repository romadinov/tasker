import Foundation
import Testing
@testable import TaskerCore

/// Runs against a real OmniFocus export when TASKER_OF_EXPORT points to one
/// (scripts/omnifocus-export.sh writes it). Skipped otherwise.
@Suite struct ImportTests {
    static let exportURL: URL? = ProcessInfo.processInfo.environment["TASKER_OF_EXPORT"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: exportURL != nil))
    func importRealDatabase() throws {
        let data = try Data(contentsOf: Self.exportURL!)
        let export = try OmniFocusImport.decode(data)
        let store = try tempStore()
        let clock = ContinuousClock()
        let elapsed = clock.measure { OmniFocusImport.apply(export, to: store) }
        let snap = store.snapshot()
        print("Imported in \(elapsed): \(OmniFocusImport.summary(export))")
        #expect(snap.tasks.count == export.tasks.count + export.projects.count)
        #expect(snap.folders.count == export.folders.count)
        #expect(snap.tags.count == export.tags.count)
        #expect(snap.perspectives.count == export.perspectives.count)

        // Every action ends up where OmniFocus had it.
        for t in export.tasks.prefix(2000) {
            #expect(snap.info[t.id]?.parentID == t.parent, "parent of \(t.name)")
        }

        // Re-import is idempotent in shape.
        let before = fingerprint(snap)
        OmniFocusImport.apply(export, to: store)
        #expect(fingerprint(store.snapshot()) == before)

        // Snapshot build cost at this size.
        let rebuild = clock.measure { _ = Snapshot(state: CRDTStateAccess.state(of: store), version: -1) }
        print("Snapshot rebuild: \(rebuild)")

        let engine = PerspectiveEngine(snap)
        for p in snap.perspectives {
            print("Perspective \(p.name): \(engine.count(p)) items, supported=\(p.rules.allSatisfy(PerspectiveEngine.isSupported))")
        }
        let available = snap.tasks.values.filter { !$0.isProject && snap.info[$0.id]?.isAvailable == true }.count
        let remaining = snap.tasks.values.filter { !$0.isProject && snap.info[$0.id]?.isRemaining == true }.count
        print("available=\(available) remaining=\(remaining) inbox=\(snap.inboxIDs.count)")

        // Reopen from disk.
        let reopened = try Store(url: store.url)
        #expect(fingerprint(reopened.snapshot()) == before)
    }
}

enum CRDTStateAccess {
    static func state(of store: Store) -> CRDTState { store.debugState }
}

/// Developer helper: TASKER_SEED_DB=/path TASKER_OF_EXPORT=/export.json swift test --filter seed
@Suite struct SeedDatabase {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TASKER_SEED_DB"] != nil && ImportTests.exportURL != nil))
    func seed() throws {
        let store = try Store(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TASKER_SEED_DB"]!))
        let export = try OmniFocusImport.decode(Data(contentsOf: ImportTests.exportURL!))
        print(OmniFocusImport.apply(export, to: store))
    }
}
