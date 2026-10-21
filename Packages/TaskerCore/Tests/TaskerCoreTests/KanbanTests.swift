import Foundation
import Testing
@testable import TaskerCore

@Suite struct KanbanTests {
    func board() throws -> Store {
        let s = try tempStore()
        s.transact { tx in
            tx.addDefaultStages()
            for id in ["A", "B", "C"] { tx.createTask(NewTask(title: id), id: id) }
        }
        return s
    }

    @Test func defaultStagesAreOrderedAndMergeAcrossDevices() throws {
        let a = try board(), b = try tempStore()
        b.transact { $0.addDefaultStages() } // the other device sets up the board too
        try a.ingest(allOps(b)); try b.ingest(allOps(a))
        #expect(a.snapshot().stages.map(\.name) == ["To Do", "In Progress", "Waiting", "Done"])
        #expect(b.snapshot().stages.map(\.id) == a.snapshot().stages.map(\.id))
    }

    @Test func movingKeepsColumnOrder() throws {
        let s = try board()
        s.transact { tx in tx.moveToStage("A", stage: "todo"); tx.moveToStage("B", stage: "todo") }
        s.transact { $0.moveToStage("C", stage: "todo", before: "B") }
        let todo = s.snapshot().stages[0]
        #expect(s.snapshot().cards(in: todo, completedSince: .distantPast).map(\.id) == ["A", "C", "B"])
        s.transact { $0.moveToStage("C", stage: "doing") }
        #expect(s.snapshot().cards(in: todo, completedSince: .distantPast).map(\.id) == ["A", "B"])
        s.transact { $0.moveToStage("A", stage: nil) }
        #expect(s.snapshot().tasks["A"]?.stageID == nil)
    }

    @Test func doneCompletesAndLeavingReopens() throws {
        let s = try board()
        s.transact { $0.moveToStage("A", stage: "done") }
        #expect(s.snapshot().tasks["A"]?.isCompleted == true)
        let done = s.snapshot().stages.last!
        #expect(s.snapshot().cards(in: done, completedSince: Date().addingTimeInterval(-60)).map(\.id) == ["A"])
        s.transact { $0.moveToStage("A", stage: "doing") }
        #expect(s.snapshot().tasks["A"]?.isCompleted == false)
    }

    @Test func deletedStagesDisappear() throws {
        let s = try board()
        s.transact { $0.deleteStage("waiting") }
        #expect(s.snapshot().stages.map(\.id) == ["todo", "doing", "done"])
        #expect(s.snapshot().hasStages)
    }
}

@Suite struct PomodoroTests {
    @Test func sessionsFromTwoDevicesBothCount() throws {
        let a = try tempStore(), b = try tempStore()
        a.transact { $0.createTask(NewTask(title: "Write"), id: "T") }
        try b.ingest(allOps(a))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        a.transact { $0.logPomodoro("T", at: t0, minutes: 25) }
        b.transact { $0.logPomodoro("T", at: t0.addingTimeInterval(1800), minutes: 50) }
        try a.ingest(allOps(b)); try b.ingest(allOps(a))
        for s in [a, b] {
            let t = try #require(s.snapshot().tasks["T"])
            #expect(t.pomodoroCount == 2)
            #expect(t.focusMinutes == 75)
            #expect(t.focusSessions.first?.minutes == 25)
        }
    }
}
