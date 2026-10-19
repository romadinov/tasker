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
