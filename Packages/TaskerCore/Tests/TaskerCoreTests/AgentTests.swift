import Foundation
import Testing
@testable import TaskerCore

@Suite struct AgentTests {
    let apps = [AgentApp(id: "scriptorium", name: "Scriptorium"), AgentApp(id: "uberdoer", name: "Uberdoer")]

    @Test func createsOneTagPerAgentAndMergesAcrossDevices() throws {
        let a = try tempStore(), b = try tempStore()
        a.transact { $0.syncAgents(apps) }
        b.transact { $0.syncAgents(apps) }
        try a.ingest(allOps(b)); try b.ingest(allOps(a))
        let s = a.snapshot()
        #expect(s.tags.values.filter { $0.agent != nil }.count == 2)
        #expect(s.tags[Agents.tagID("scriptorium")]?.position.parent == Agents.parentTagID)
        #expect(s.tags[Agents.tagID("scriptorium")]?.name == "Scriptorium agent")
        #expect(s.agentApps.map(\.id).sorted() == ["scriptorium", "uberdoer"])
        #expect(b.snapshot().tags.count == s.tags.count)
    }

    @Test func deletedAgentTagIsNotRecreated() throws {
        let s = try tempStore()
        s.transact { $0.syncAgents(apps) }
        s.transact { $0.set(.tag, Agents.tagID("uberdoer"), F.deleted, true) }
        s.transact { $0.syncAgents(apps) }
        #expect(s.snapshot().tags[Agents.tagID("uberdoer")] == nil)
        s.transact { $0.syncAgents(apps + [AgentApp(id: "jinnie", name: "Jinnie")]) }
        #expect(s.snapshot().tags[Agents.tagID("jinnie")]?.agent == "jinnie")
    }

    @Test func agentTasksAreRemainingActionsWithAnAgentTag() throws {
        let s = try tempStore()
        func task(_ tx: inout Tx, _ id: String, _ tags: [String]) {
            var n = NewTask(title: id); n.tagIDs = tags; tx.createTask(n, id: id)
        }
        s.transact { tx in
            tx.syncAgents(apps)
            let child = tx.createTag("Bugs", parent: Agents.tagID("uberdoer"), id: "bugs")
            task(&tx, "A", [Agents.tagID("uberdoer")])
            task(&tx, "B", [child])
            task(&tx, "C", [Agents.tagID("scriptorium")])
            task(&tx, "D", [])
        }
        #expect(s.snapshot().agentTasks("uberdoer").map(\.id).sorted() == ["A", "B"])
        s.transact { $0.complete("A") }
        #expect(s.snapshot().agentTasks("uberdoer").map(\.id) == ["B"])
    }
}
