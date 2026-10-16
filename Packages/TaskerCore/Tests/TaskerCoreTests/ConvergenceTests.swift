import Foundation
import Testing
@testable import TaskerCore

func tempStore(_ role: String = "app", file: URL? = nil) throws -> Store {
    let url = file ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("tasker-tests-\(UUID().uuidString)/tasker.sqlite")
    return try Store(url: url, role: role)
}

/// All ops a store holds, by replica.
func allOps(_ s: Store) -> [Op] {
    s.knownReplicas.flatMap { r, max in s.ops(replica: r, first: 1, last: max) }
}

/// Canonical comparable form of a snapshot.
func fingerprint(_ s: Snapshot) -> String {
    var lines: [String] = []
    for id in s.tasks.keys.sorted() {
        let t = s.tasks[id]!
        let i = s.info[id]
        lines.append("T \(id) \(t.title) p=\(i?.parentID ?? s.projectInfo[id]?.folderID ?? "-") o=\(t.position.order) f=\(t.flagged) c=\(t.completedAt.map { "\($0.timeIntervalSince1970)" } ?? "-") tags=\(t.tagIDs) due=\(t.dueDate?.timeIntervalSince1970 ?? 0) avail=\(i?.isAvailable ?? false)")
    }
    for (k, v) in s.children.sorted(by: { $0.key < $1.key }) { lines.append("C \(k) \(v)") }
    for id in s.tags.keys.sorted() { lines.append("G \(id) \(s.tags[id]!.name) \(s.tags[id]!.status)") }
    return lines.joined(separator: "\n")
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite struct ConvergenceTests {
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func randomEditsConverge(seed: UInt64) throws {
        var rng = SeededRNG(state: seed)
        let replicas = try (0..<3).map { _ in try tempStore() }
        // Shared starting point: one project and a couple of tags everyone knows.
        let project = "proj-shared"
        replicas[0].transact { tx in
            var n = NewTask(title: "Shared project"); n.isProject = true
            tx.createTask(n, id: project)
            tx.createTag("home", id: "tag-home")
            tx.createTag("work", id: "tag-work")
        }
        let seedOps = allOps(replicas[0])
        for r in replicas.dropFirst() { try r.ingest(seedOps) }

        for _ in 0..<12 {
            // Each replica edits offline.
            for r in replicas {
                for _ in 0..<Int.random(in: 3...10, using: &rng) { randomEdit(r, project: project, rng: &rng) }
            }
            // Random partial, duplicated, out-of-order delivery between random pairs.
            for _ in 0..<4 {
                let a = replicas.randomElement(using: &rng)!, b = replicas.randomElement(using: &rng)!
                guard a !== b else { continue }
                var ops = allOps(a).filter { _ in Bool.random(using: &rng) }
                ops.shuffle(using: &rng)
                ops += ops.prefix(3) // duplicates
                try b.ingest(ops)
            }
        }
        // Full exchange.
        let union = replicas.flatMap(allOps)
        for r in replicas { try r.ingest(union.shuffled(using: &rng)) }

        let prints = replicas.map { fingerprint($0.snapshot()) }
        #expect(prints[0] == prints[1])
        #expect(prints[1] == prints[2])
        #expect(!replicas[0].snapshot().tasks.isEmpty)
    }

    func randomEdit(_ s: Store, project: String, rng: inout SeededRNG) {
        let snap = s.snapshot()
        let actions = snap.tasks.values.filter { !$0.isProject }.map(\.id).sorted()
        s.transact { tx in
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1:
                var n = NewTask(title: "t\(Int.random(in: 0..<1000, using: &rng))")
                n.parent = Bool.random(using: &rng) ? project : actions.randomElement(using: &rng)
                tx.createTask(n)
            case 2:
                if let id = actions.randomElement(using: &rng) { tx.setTask(id, F.title, .string("renamed \(Int.random(in: 0..<99, using: &rng))")) }
            case 3:
                if let id = actions.randomElement(using: &rng) { tx.setTask(id, F.flagged, .bool(Bool.random(using: &rng))) }
            case 4:
                if let id = actions.randomElement(using: &rng) { tx.setTag(id, Bool.random(using: &rng) ? "tag-home" : "tag-work", Bool.random(using: &rng)) }
            case 5:
                if let id = actions.randomElement(using: &rng) {
                    // Moves (including attempts that would create cycles on other replicas).
                    let target = Bool.random(using: &rng) ? project : actions.randomElement(using: &rng)
                    tx.move(id, to: target, placement: Bool.random(using: &rng) ? .start : .end)
                }
            case 6:
                if let id = actions.randomElement(using: &rng) { tx.complete(id) }
            case 7:
                if let id = actions.randomElement(using: &rng), Int.random(in: 0..<3, using: &rng) == 0 { tx.delete(id) }
            case 8:
                if let id = actions.randomElement(using: &rng) { tx.setTask(id, F.dueDate, .date(Date().addingTimeInterval(Double(Int.random(in: -5...5, using: &rng)) * 86400))) }
            default:
                if let id = actions.randomElement(using: &rng) { tx.indent(id) }
            }
        }
    }

    @Test func concurrentMovesNeverCreateCycles() throws {
        let a = try tempStore(), b = try tempStore()
        a.transact { tx in
            tx.createTask(NewTask(title: "X"), id: "X")
            tx.createTask(NewTask(title: "Y"), id: "Y")
        }
        try b.ingest(allOps(a))
        a.transact { $0.move("X", to: "Y") }   // X under Y
        b.transact { $0.move("Y", to: "X") }   // Y under X, concurrently
        try a.ingest(allOps(b)); try b.ingest(allOps(a))
        let sa = a.snapshot(), sb = b.snapshot()
        #expect(fingerprint(sa) == fingerprint(sb))
        #expect(sa.tasks["X"] != nil && sa.tasks["Y"] != nil)
        // Both still reachable from a root.
        let reachable = Set(sa.inboxIDs + sa.inboxIDs.flatMap { sa.descendants(of: $0) })
        #expect(reachable.contains("X") && reachable.contains("Y"))
    }

    @Test func childOfDeletedParentIsNotLost() throws {
        let a = try tempStore(), b = try tempStore()
        a.transact { tx in tx.createTask(NewTask(title: "Parent"), id: "P") }
        try b.ingest(allOps(a))
        a.transact { $0.delete("P") }
        b.transact { tx in var n = NewTask(title: "Child added offline"); n.parent = "P"; tx.createTask(n, id: "C") }
        try a.ingest(allOps(b)); try b.ingest(allOps(a))
        #expect(a.snapshot().tasks["P"] == nil)
        #expect(a.snapshot().inboxIDs.contains("C"))
        #expect(fingerprint(a.snapshot()) == fingerprint(b.snapshot()))
    }

    @Test func tagsAddedOnTwoDevicesBothSurvive() throws {
        let a = try tempStore(), b = try tempStore()
        a.transact { tx in
            tx.createTask(NewTask(title: "T"), id: "T")
            tx.createTag("A", id: "ta"); tx.createTag("B", id: "tb")
        }
        try b.ingest(allOps(a))
        a.transact { $0.setTag("T", "ta", true) }
        b.transact { $0.setTag("T", "tb", true) }
        try a.ingest(allOps(b)); try b.ingest(allOps(a))
        #expect(a.snapshot().tasks["T"]?.tagIDs == ["ta", "tb"])
        #expect(b.snapshot().tasks["T"]?.tagIDs == ["ta", "tb"])
    }

    @Test func completingRepeatingTaskOnTwoDevicesConverges() throws {
        let a = try tempStore(), b = try tempStore()
        let due = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
        a.transact { tx in
            var n = NewTask(title: "Water plants"); n.dueDate = due
            tx.createTask(n, id: "R")
            tx.setTask("R", F.repeatRule, JSON(encoding: RepeatRule(rrule: "FREQ=WEEKLY")))
        }
        try b.ingest(allOps(a))
        a.transact { $0.complete("R") }
        b.transact { $0.complete("R") }
        try a.ingest(allOps(b)); try b.ingest(allOps(a))
        let s = a.snapshot()
        #expect(fingerprint(s) == fingerprint(b.snapshot()))
        let completedCopies = s.tasks.values.filter { $0.title == "Water plants" && $0.completedAt != nil }
        #expect(completedCopies.count == 1)
        let next = s.tasks["R"]!.dueDate!
        #expect(Calendar.current.dateComponents([.day], from: due, to: next).day == 7)
    }

    @Test func mergeIsIdempotentAndPersistent() throws {
        let a = try tempStore()
        a.transact { tx in for i in 0..<50 { tx.createTask(NewTask(title: "Item \(i)")) } }
        let url = a.url
        let before = fingerprint(a.snapshot())
        #expect(try a.ingest(allOps(a)) == 0)
        let reopened = try Store(url: url)
        #expect(fingerprint(reopened.snapshot()) == before)
        #expect(reopened.replica == a.replica)
    }

    @Test func twoProcessesShareOneDatabase() throws {
        let app = try tempStore("app")
        let ext = try Store(url: app.url, role: "share")
        #expect(app.replica != ext.replica)
        ext.transact { tx in tx.createTask(NewTask(title: "Captured in share sheet"), id: "S") }
        app.transact { tx in tx.createTask(NewTask(title: "Typed in app"), id: "A") }
        try app.pullNewOps()
        try ext.pullNewOps()
        #expect(app.snapshot().tasks["S"] != nil)
        #expect(ext.snapshot().tasks["A"] != nil)
        #expect(fingerprint(app.snapshot()) == fingerprint(ext.snapshot()))
    }

    @Test func exportAndMergeLogFile() throws {
        let a = try tempStore(), b = try tempStore()
        a.transact { tx in for i in 0..<20 { tx.createTask(NewTask(title: "N\(i)")) } }
        let data = try a.exportLog()
        #expect(try b.mergeLog(data) > 0)
        #expect(fingerprint(a.snapshot()) == fingerprint(b.snapshot()))
        #expect(try b.mergeLog(data) == 0)
    }

    @Test func undoRestoresPreviousValues() throws {
        let s = try tempStore()
        s.transact { tx in tx.createTask(NewTask(title: "Original"), id: "U") }
        let undo = s.transact { $0.setTask("U", F.title, "Changed") }!
        #expect(s.snapshot().tasks["U"]?.title == "Changed")
        _ = s.undo(undo)
        #expect(s.snapshot().tasks["U"]?.title == "Original")
        let undoCreate = s.transact { tx in tx.createTask(NewTask(title: "New"), id: "N2") }!
        _ = s.undo(undoCreate)
        #expect(s.snapshot().tasks["N2"] == nil)
    }

    @Test func uploadBookkeeping() throws {
        let s = try tempStore()
        s.transact { tx in for i in 0..<25 { tx.createTask(NewTask(title: "\(i)")) } }
        let runs = s.pendingUploadRuns(maxOps: 40)
        #expect(runs.count >= 2)
        #expect(s.uploadedThrough(s.replica) == 0)
        s.markUploaded(replica: runs[0].replica, first: runs[0].first, last: runs[0].last)
        #expect(s.uploadedThrough(s.replica) == runs[0].last)
        for r in runs { s.markUploaded(replica: r.replica, first: r.first, last: r.last) }
        #expect(s.pendingUploadRuns().isEmpty)
        #expect(s.uploadedThrough(s.replica) == s.contiguous(s.replica))
        s.markAllNotUploaded()
        #expect(s.syncCounts().pendingUpload == s.syncCounts().totalOps)
    }
}
