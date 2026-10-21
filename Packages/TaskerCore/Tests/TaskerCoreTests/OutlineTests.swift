import Foundation
import Testing
@testable import TaskerCore

@Suite struct OutlineTests {
    /// Inbox A B C D E.
    func inbox() throws -> Store {
        let s = try tempStore()
        s.transact { tx in for id in ["A", "B", "C", "D", "E"] { tx.createTask(NewTask(title: id), id: id) } }
        return s
    }

    @Test func indentRunGoesUnderItemAboveInOrder() throws {
        let s = try inbox()
        s.transact { _ = $0.indent(["C", "B", "D"]) }
        let snap = s.snapshot()
        #expect(snap.inboxIDs == ["A", "E"])
        #expect(snap.childIDs("A") == ["B", "C", "D"])
    }

    @Test func outdentKeepsOrderAndLandsAfterParent() throws {
        let s = try inbox()
        s.transact { _ = $0.indent(["B", "C", "D"]) }
        s.transact { $0.outdent(["D", "B"]) }
        let snap = s.snapshot()
        #expect(snap.inboxIDs == ["A", "B", "D", "E"])
        #expect(snap.childIDs("A") == ["C"])
    }

    @Test func moveUpDownMovesTheWholeSelection() throws {
        let s = try inbox()
        s.transact { $0.moveVertically(["C", "D"], up: true) }
        #expect(s.snapshot().inboxIDs == ["A", "C", "D", "B", "E"])
        s.transact { $0.moveVertically(["C", "D"], up: false) }
        #expect(s.snapshot().inboxIDs == ["A", "B", "C", "D", "E"])
    }

    @Test func groupAndUngroup() throws {
        let s = try inbox()
        var g: String?
        s.transact { g = $0.group(["B", "D", "C"]) }
        var snap = s.snapshot()
        let group = try #require(g)
        #expect(snap.inboxIDs == ["A", group, "E"])
        #expect(snap.childIDs(group) == ["B", "C", "D"])
        s.transact { $0.ungroup([group]) }
        snap = s.snapshot()
        #expect(snap.inboxIDs == ["A", "B", "C", "D", "E"])
        #expect(snap.tasks[group] == nil)
    }

    @Test func addInsideAndOutside() throws {
        let s = try inbox()
        s.transact { _ = $0.indent(["B"]) }
        var inside: String?, outside: String?
        s.transact { inside = $0.addInside("A") }
        s.transact { outside = $0.addOutside("B") }
        let snap = s.snapshot()
        #expect(snap.childIDs("A") == [inside!, "B"])
        #expect(snap.inboxIDs == ["A", outside!, "C", "D", "E"])
    }

    @Test func sortOnceSortsChildrenOfContainerAndSelectedSiblings() throws {
        let s = try tempStore()
        s.transact { tx in
            let f = tx.createFolder("Work", id: "F")
            for (id, name) in [("p3", "Zeta"), ("p1", "alpha"), ("p2", "Beta")] {
                var n = NewTask(title: name, parent: f); n.isProject = true
                tx.createTask(n, id: id)
            }
            for (id, name) in [("t2", "b"), ("t3", "c"), ("t1", "a")] { tx.createTag(name, id: id) }
        }
        s.transact { $0.sortOnce(["F"], by: .title) }
        #expect(s.snapshot().childIDs("F") == ["p1", "p2", "p3"])
        s.transact { $0.sortOnce([], by: .title, rootKey: Snapshot.tagsKey) }
        #expect(s.snapshot().tagChildren[Snapshot.tagsKey] == ["t1", "t2", "t3"])
    }

    @Test func foldersAndTagsIndentAndOutdent() throws {
        let s = try tempStore()
        s.transact { tx in
            tx.createFolder("A", id: "A"); tx.createFolder("B", id: "B")
            tx.createTag("x", id: "x"); tx.createTag("y", id: "y")
        }
        s.transact { _ = $0.indent(["B", "y"]) }
        var snap = s.snapshot()
        #expect(snap.childIDs("A") == ["B"])
        #expect(snap.tagChildren["x"] == ["y"])
        s.transact { $0.outdent(["B", "y"]) }
        snap = s.snapshot()
        #expect(snap.libraryIDs == ["A", "B"])
        #expect(snap.tagChildren[Snapshot.tagsKey] == ["x", "y"])
    }
}

@Suite struct ImportOrderTests {
    /// OmniFocus numbers folders and projects together within a container; the import must keep that interleaving.
    @Test func foldersAndProjectsKeepTheirMixedOrder() throws {
        let json = """
        {"folders":[{"id":"F1","name":"Home","parent":null,"idx":1},{"id":"F2","name":"Work","parent":null,"idx":3},
                    {"id":"F3","name":"Sub","parent":"F2","idx":1}],
         "projects":[{"id":"P0","name":"First","parent":null,"idx":0},{"id":"P2","name":"Middle","parent":null,"idx":2},
                     {"id":"P4","name":"Last","parent":null,"idx":4},{"id":"PW","name":"In work","parent":"F2","idx":0},
                     {"id":"PW2","name":"In work 2","parent":"F2","idx":2}],
         "tasks":[{"id":"T1","name":"b","parent":"P0","idx":1},{"id":"T0","name":"a","parent":"P0","idx":0},
                  {"id":"I1","name":"inbox b","parent":null,"idx":1},{"id":"I0","name":"inbox a","parent":null,"idx":0}],
         "tags":[],"perspectives":[]}
        """
        let s = try tempStore()
        _ = OmniFocusImport.apply(try OmniFocusImport.decode(Data(json.utf8)), to: s)
        let snap = s.snapshot()
        #expect(snap.libraryIDs == ["P0", "F1", "P2", "F2", "P4"])
        #expect(snap.childIDs("F2") == ["PW", "F3", "PW2"])
        #expect(snap.childIDs("P0") == ["T0", "T1"])
        #expect(snap.inboxIDs == ["I0", "I1"])
    }
}

@Suite struct CompleteCascadeTests {
    @Test func completingParentCompletesOpenChildrenAndUndoReopensThem() throws {
        let s = try tempStore()
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        s.transact { tx in
            var p = NewTask(title: "P"); p.isProject = true
            tx.createTask(p, id: "P")
            tx.createTask(NewTask(title: "G", parent: "P"), id: "G")
            tx.createTask(NewTask(title: "G1", parent: "G"), id: "G1")
            tx.createTask(NewTask(title: "A", parent: "P"), id: "A")
            tx.createTask(NewTask(title: "Old", parent: "P"), id: "Old")
        }
        s.transact { $0.complete("Old", at: earlier) }
        s.transact { $0.complete("G", at: earlier.addingTimeInterval(60)) }
        #expect(s.snapshot().tasks["G1"]?.isCompleted == true)
        #expect(s.snapshot().tasks["A"]?.isCompleted == false)
        s.transact { $0.complete("P", at: earlier.addingTimeInterval(120)) }
        let snap = s.snapshot()
        for id in ["P", "G", "G1", "A", "Old"] { #expect(snap.tasks[id]?.isCompleted == true, "\(id)") }
        #expect(snap.tasks["Old"]?.completedAt == earlier)
        s.transact { $0.uncomplete("P") }
        let back = s.snapshot()
        #expect(back.tasks["A"]?.isCompleted == false)
        #expect(back.tasks["Old"]?.isCompleted == true)   // finished on its own earlier
        #expect(back.tasks["G"]?.isCompleted == true)     // completed before the project
    }
}

@Suite struct ProjectStatusTests {
    @Test func completedStatusCascadesAndActiveReopens() throws {
        let s = try tempStore()
        s.transact { tx in
            var p = NewTask(title: "P"); p.isProject = true
            tx.createTask(p, id: "P")
            tx.createTask(NewTask(title: "A", parent: "P"), id: "A")
        }
        s.transact { $0.setProjectStatus("P", .done) }
        #expect(s.snapshot().tasks["A"]?.isCompleted == true)
        s.transact { $0.setProjectStatus("P", .active) }
        #expect(s.snapshot().tasks["A"]?.isCompleted == false)
        #expect(s.snapshot().tasks["P"]?.status == .active)
    }
}

@Suite struct ConvertBackTests {
    @Test func projectBecomesInboxActionWithSubtasks() throws {
        let s = try tempStore()
        s.transact { tx in
            tx.createTask(NewTask(title: "X"), id: "X")
            var p = NewTask(title: "P"); p.isProject = true
            tx.createTask(p, id: "P")
            tx.createTask(NewTask(title: "A", parent: "P"), id: "A")
        }
        s.transact { $0.convertToAction("P") }
        let snap = s.snapshot()
        #expect(snap.tasks["P"]?.isProject == false)
        #expect(snap.inboxIDs.first == "P")
        #expect(snap.childIDs("P") == ["A"])
        #expect(snap.projectInfo["P"] == nil)
        // and back again
        s.transact { $0.convertToProject("P", folder: nil) }
        #expect(s.snapshot().tasks["P"]?.isProject == true)
        #expect(s.snapshot().childIDs("P") == ["A"])
    }
}
