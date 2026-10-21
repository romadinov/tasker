import Foundation

/// A Kanban column. Stages are stored as settings records ("stage:<id>" → object), one per stage, so
/// builds that predate the board sync them without trouble (an unknown entity type would not decode).
public struct KanbanStage: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var order: String
    /// SF colour name: "gray", "blue", "orange", "purple", "green", "red", "teal", "yellow".
    public var color: String
    /// Moving a card here completes the action (and moving it out again reopens it).
    public var completes: Bool

    public init(id: String, name: String, order: String, color: String = "blue", completes: Bool = false) {
        self.id = id; self.name = name; self.order = order; self.color = color; self.completes = completes
    }

    static let prefix = "stage:"

    var json: JSON {
        .object(["name": .string(name), "order": .string(order), "color": .string(color), "completes": .bool(completes)])
    }

    init?(id: String, json: JSON) {
        guard case .object = json, json["deleted"]?.bool != true, let name = json["name"]?.string else { return nil }
        self.init(id: id, name: name, order: json["order"]?.string ?? "V", color: json["color"]?.string ?? "blue",
                  completes: json["completes"]?.bool ?? false)
    }

    /// Fixed ids, so two devices creating the defaults at once end up with one set.
    public static let defaults: [KanbanStage] = {
        let k = FractionalIndex.evenlySpaced(4)
        return [
            KanbanStage(id: "todo", name: "To Do", order: k[0], color: "gray"),
            KanbanStage(id: "doing", name: "In Progress", order: k[1], color: "blue"),
            KanbanStage(id: "waiting", name: "Waiting", order: k[2], color: "orange"),
            KanbanStage(id: "done", name: "Done", order: k[3], color: "green", completes: true),
        ]
    }()
}

extension Snapshot {
    /// Board columns in order.
    public var stages: [KanbanStage] {
        settings.compactMap { key, value -> KanbanStage? in
            guard key.hasPrefix(KanbanStage.prefix) else { return nil }
            return KanbanStage(id: String(key.dropFirst(KanbanStage.prefix.count)), json: value)
        }
        .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Whether the board has ever been set up (deleted stages still count, so defaults aren't re-added).
    public var hasStages: Bool { settings.keys.contains { $0.hasPrefix(KanbanStage.prefix) } }

    /// Cards in a column: remaining actions in that stage, plus ones completed in the last week when
    /// the stage completes them. In column order.
    public func cards(in stage: KanbanStage, completedSince: Date) -> [TaskItem] {
        tasks.values.filter { t in
            guard !t.isProject, t.stageID == stage.id, let i = info[t.id] else { return false }
            if i.isRemaining { return true }
            return stage.completes && (t.completedAt.map { $0 >= completedSince } ?? false)
        }
        .sorted { ($0.stageOrder, $0.title) < ($1.stageOrder, $1.title) }
    }
}

extension Tx {
    public mutating func saveStage(_ s: KanbanStage) {
        setSetting(KanbanStage.prefix + s.id, s.json)
    }

    public mutating func deleteStage(_ id: String) {
        setSetting(KanbanStage.prefix + id, .object(["deleted": .bool(true)]))
    }

    public mutating func addDefaultStages() {
        for s in KanbanStage.defaults { saveStage(s) }
    }

    /// Puts an action in a stage (nil = off the board), before `before` or at the end of the column.
    /// A completing stage completes it; leaving one reopens it.
    public mutating func moveToStage(_ id: String, stage: String?, before: String? = nil) {
        guard let t = base.tasks[id], !t.isProject else { return }
        let stages = base.stages
        let target = stage.flatMap { sid in stages.first { $0.id == sid } }
        let wasCompleting = t.stageID.flatMap { sid in stages.first { $0.id == sid } }?.completes ?? false
        guard let stage, let target else {
            set(.task, id, F.stage, .null)
            return
        }
        let column = base.tasks.values
            .filter { !$0.isProject && $0.stageID == stage && $0.id != id && (base.info[$0.id]?.isRemaining ?? false || target.completes) }
            .sorted { ($0.stageOrder, $0.title) < ($1.stageOrder, $1.title) }
        var lo: String?, hi: String?
        if let before, let i = column.firstIndex(where: { $0.id == before }) {
            hi = column[i].stageOrder
            lo = i > 0 ? column[i - 1].stageOrder : nil
        } else {
            // Cards appended earlier in this same transaction aren't in `base` yet.
            lo = [column.last?.stageOrder, lastAppended["#stage:" + stage]].compactMap { $0 }.max()
        }
        if let l = lo, let h = hi, l >= h { hi = nil } // duplicate keys: append after
        let key = FractionalIndex.between(lo, hi)
        if hi == nil { lastAppended["#stage:" + stage] = key }
        set(.task, id, F.stage, .string(stage))
        set(.task, id, F.stageOrder, .string(key))
        if target.completes && !t.isCompleted { complete(id) }
        else if !target.completes && wasCompleting && t.isCompleted && t.repeatRule == nil { uncomplete(id) }
    }
}
