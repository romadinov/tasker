import Foundation

/// Field names used in the op log. Keep these stable: they are the persisted schema.
public enum F {
    public static let title = "title"
    public static let note = "note"
    /// {"p": parentID or null, "o": order key}. Parent and order move together atomically,
    /// so a concurrent move and reorder can't tear an item between two places.
    public static let pos = "pos"
    public static let kind = "kind"            // "action" | "project"
    public static let flagged = "flagged"
    public static let deferDate = "defer"
    public static let dueDate = "due"
    public static let plannedDate = "planned"
    public static let estimate = "estimate"    // minutes
    public static let completed = "completed"  // date or null
    public static let dropped = "dropped"      // date or null
    public static let sequential = "sequential"
    public static let autoComplete = "autoComplete" // completes when children complete
    public static let repeatRule = "repeat"
    public static let created = "created"
    public static let deleted = "deleted"
    public static let status = "status"
    public static let singleActions = "singleActions"
    public static let reviewEvery = "reviewEvery"
    public static let nextReview = "nextReview"
    public static let lastReview = "lastReview"
    public static let name = "name"
    public static let icon = "icon"
    public static let rules = "rules"
    public static let aggregation = "aggregation"
    public static let groupBy = "groupBy"
    public static let sortBy = "sortBy"
    public static let value = "value"
    public static let location = "location"
    /// Kanban: the stage id an action is in, and its order key within that column.
    public static let stage = "stage"
    public static let stageOrder = "stageOrder"
    /// A companion app's own id for this item ("mindmapper:<node>", "jinnie:<id>"), for idempotent upserts.
    public static let externalRef = "externalRef"
    public static let tagPrefix = "tag:"
    /// One finished pomodoro: "pomo:<id>" → {"at": date, "min": minutes}. One register per session,
    /// so sessions logged on two devices both survive.
    public static let pomodoroPrefix = "pomo:"
    public static func tag(_ id: String) -> String { tagPrefix + id }
}

public struct Position: Hashable, Sendable, Codable {
    public var parent: String?
    public var order: String
    public init(parent: String?, order: String) { self.parent = parent; self.order = order }

    var json: JSON { .object(["p": .optional(parent), "o": .string(order)]) }
    init(json: JSON?) {
        parent = json?["p"]?.string
        order = json?["o"]?.string ?? "V"
    }
}

public enum ProjectStatus: String, Sendable, Codable, CaseIterable {
    case active, onHold, done, dropped
    public var label: String {
        switch self { case .active: "Active"; case .onHold: "On Hold"; case .done: "Completed"; case .dropped: "Dropped" }
    }
}

public enum TagStatus: String, Sendable, Codable, CaseIterable {
    case active, onHold, dropped
    public var label: String {
        switch self { case .active: "Active"; case .onHold: "On Hold"; case .dropped: "Dropped" }
    }
}

public struct ReviewInterval: Hashable, Sendable, Codable {
    public enum Unit: String, Sendable, Codable, CaseIterable { case day, week, month, year }
    public var count: Int
    public var unit: Unit
    public init(count: Int, unit: Unit) { self.count = count; self.unit = unit }
    public static let weekly = ReviewInterval(count: 1, unit: .week)

    public func advance(_ date: Date, calendar: Calendar = .current) -> Date {
        let comp: Calendar.Component = switch unit { case .day: .day; case .week: .weekOfYear; case .month: .month; case .year: .year }
        return calendar.date(byAdding: comp, value: max(1, count), to: date) ?? date
    }
    public var label: String {
        let u = unit.rawValue
        return count == 1 ? "Every \(u)" : "Every \(count) \(u)s"
    }
}

public struct TaskItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case action, project }

    public var id: String
    public var kind: Kind = .action
    public var title: String = ""
    public var note: String = ""
    public var position = Position(parent: nil, order: "V")
    public var positionStamp: HLC = .zero
    public var flagged = false
    public var deferDate: Date?
    public var dueDate: Date?
    public var plannedDate: Date?
    public var estimatedMinutes: Int?
    public var completedAt: Date?
    public var droppedAt: Date?
    public var sequential = false
    public var completesWithChildren = false
    public var repeatRule: RepeatRule?
    public var tagIDs: [String] = []
    public var createdAt: Date?
    public var modifiedAt: Date = .distantPast
    public var deleted = false
    // Project-only
    public var status: ProjectStatus = .active
    public var singleActions = false
    public var reviewInterval: ReviewInterval?
    public var nextReviewDate: Date?
    public var lastReviewDate: Date?
    // Kanban
    public var stageID: String?
    public var stageOrder: String = "V"
    public var externalRef: String?
    /// Finished pomodoros on this action (newest last).
    public var focusSessions: [FocusSession] = []
    public var pomodoroCount: Int { focusSessions.count }
    public var focusMinutes: Int { focusSessions.reduce(0) { $0 + $1.minutes } }

    public var isProject: Bool { kind == .project }
    public var isCompleted: Bool { isProject ? status == .done || completedAt != nil : completedAt != nil }
    public var isDropped: Bool { isProject ? status == .dropped || droppedAt != nil : droppedAt != nil }

    public init(id: String) { self.id = id }

    init(id: String, fields: [String: Register]) {
        self.id = id
        var maxStamp = HLC.zero
        var tags: [String] = []
        for (field, reg) in fields {
            if maxStamp < reg.hlc { maxStamp = reg.hlc }
            let v = reg.value
            switch field {
            case F.kind: kind = v.string == "project" ? .project : .action
            case F.title: title = v.string ?? ""
            case F.note: note = v.string ?? ""
            case F.pos: position = Position(json: v); positionStamp = reg.hlc
            case F.flagged: flagged = v.bool ?? false
            case F.deferDate: deferDate = v.date
            case F.dueDate: dueDate = v.date
            case F.plannedDate: plannedDate = v.date
            case F.estimate: estimatedMinutes = v.int
            case F.completed: completedAt = v.date
            case F.dropped: droppedAt = v.date
            case F.sequential: sequential = v.bool ?? false
            case F.autoComplete: completesWithChildren = v.bool ?? false
            case F.repeatRule: repeatRule = v.decode(RepeatRule.self)
            case F.created: createdAt = v.date
            case F.deleted: deleted = v.bool ?? false
            case F.status: status = v.string.flatMap(ProjectStatus.init(rawValue:)) ?? .active
            case F.singleActions: singleActions = v.bool ?? false
            case F.reviewEvery: reviewInterval = v.decode(ReviewInterval.self)
            case F.nextReview: nextReviewDate = v.date
            case F.lastReview: lastReviewDate = v.date
            case F.stage: stageID = v.string
            case F.stageOrder: stageOrder = v.string ?? "V"
            case F.externalRef: externalRef = v.string.flatMap { $0.isEmpty ? nil : $0 }
            default:
                if field.hasPrefix(F.pomodoroPrefix), let at = v["at"]?.date {
                    focusSessions.append(FocusSession(at: at, minutes: v["min"]?.int ?? 25))
                }
                if field.hasPrefix(F.tagPrefix), v.bool == true {
                    tags.append(String(field.dropFirst(F.tagPrefix.count)))
                }
            }
        }
        tagIDs = tags.sorted()
        focusSessions.sort { $0.at < $1.at }
        modifiedAt = maxStamp.date
        if createdAt == nil, let first = fields.values.map(\.hlc).min() { createdAt = first.date }
    }
}

public struct Folder: Identifiable, Hashable, Sendable {
    public var id: String
    public var name = ""
    public var position = Position(parent: nil, order: "V")
    public var positionStamp: HLC = .zero
    public var dropped = false
    public var deleted = false

    public init(id: String) { self.id = id }

    init(id: String, fields: [String: Register]) {
        self.id = id
        name = fields[F.name]?.value.string ?? ""
        if let p = fields[F.pos] { position = Position(json: p.value); positionStamp = p.hlc }
        dropped = fields[F.status]?.value.string == "dropped"
        deleted = fields[F.deleted]?.value.bool ?? false
    }
}

public struct Tag: Identifiable, Hashable, Sendable {
    public var id: String
    public var name = ""
    public var position = Position(parent: nil, order: "V")
    public var positionStamp: HLC = .zero
    public var status: TagStatus = .active
    public var location: TagLocation?
    public var deleted = false

    public init(id: String) { self.id = id }

    init(id: String, fields: [String: Register]) {
        self.id = id
        name = fields[F.name]?.value.string ?? ""
        if let p = fields[F.pos] { position = Position(json: p.value); positionStamp = p.hlc }
        status = fields[F.status]?.value.string.flatMap(TagStatus.init(rawValue:)) ?? .active
        location = fields[F.location]?.value.decode(TagLocation.self)
        deleted = fields[F.deleted]?.value.bool ?? false
    }
}

public enum GroupBy: String, Sendable, CaseIterable, Codable {
    case none, project, tag, folder, due, deferDate = "defer", flagged, completed
    public var label: String {
        switch self {
        case .none: "Ungrouped"; case .project: "Project"; case .tag: "Tag"; case .folder: "Folder"
        case .due: "Due"; case .deferDate: "Defer"; case .flagged: "Flagged"; case .completed: "Completed"
        }
    }
}

public enum SortBy: String, Sendable, CaseIterable, Codable {
    case manual, due, deferDate = "defer", planned, added, changed, completed, title, flagged
    public var label: String {
        switch self {
        case .manual: "Project order"; case .due: "Due"; case .deferDate: "Defer"; case .planned: "Planned"
        case .added: "Added"; case .changed: "Changed"; case .completed: "Completed"; case .title: "Name"; case .flagged: "Flagged"
        }
    }
}

public struct Perspective: Identifiable, Hashable, Sendable {
    public var id: String
    public var name = ""
    public var icon = "line.3.horizontal.decrease.circle"
    public var order = "V"
    /// Rules use OmniFocus's own `archivedFilterRules` JSON dialect, so imported
    /// perspectives keep working and unknown rule types survive round-trips untouched.
    public var rules: [JSON] = []
    public var aggregation = "all"
    public var groupBy: GroupBy = .project
    public var sortBy: SortBy = .manual
    public var deleted = false

    public init(id: String) { self.id = id }

    init(id: String, fields: [String: Register]) {
        self.id = id
        name = fields[F.name]?.value.string ?? ""
        icon = fields[F.icon]?.value.string ?? icon
        order = Position(json: fields[F.pos]?.value).order
        rules = fields[F.rules]?.value.array ?? []
        aggregation = fields[F.aggregation]?.value.string ?? "all"
        groupBy = fields[F.groupBy]?.value.string.flatMap(GroupBy.init(rawValue:)) ?? .project
        sortBy = fields[F.sortBy]?.value.string.flatMap(SortBy.init(rawValue:)) ?? .manual
        deleted = fields[F.deleted]?.value.bool ?? false
    }
}

public struct FocusSession: Hashable, Sendable {
    public var at: Date
    public var minutes: Int
    public init(at: Date, minutes: Int) { self.at = at; self.minutes = minutes }
}

extension Tx {
    /// Records a finished pomodoro on an action.
    public mutating func logPomodoro(_ id: String, at: Date, minutes: Int) {
        guard base.tasks[id] != nil else { return }
        set(.task, id, F.pomodoroPrefix + IDs.make(), .object(["at": .date(at), "min": .number(Double(minutes))]))
    }
}
