import SwiftUI
import TaskerCore

/// Rule builder. Rules are stored in OmniFocus's `archivedFilterRules` JSON dialect.
struct PerspectiveEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var perspective: Perspective

    static let icons = ["line.3.horizontal.decrease.circle", "star", "sun.max", "briefcase", "house", "person.2", "hourglass",
                        "checkmark.circle", "bolt", "cart", "phone", "envelope", "laptopcomputer", "leaf", "heart", "flag", "calendar", "brain"]

    var body: some View {
        let isNew = !model.snapshot.perspectives.contains { $0.id == perspective.id }
        let count = PerspectiveEngine(model.snapshot).count(perspective)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $perspective.name)
                    Picker("Icon", selection: $perspective.icon) {
                        ForEach(Self.icons, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) }
                    }
                }
                Section {
                    RuleList(rules: $perspective.rules, aggregation: $perspective.aggregation)
                } header: {
                    Text("Include actions matching")
                } footer: {
                    Text("\(count) matching items")
                }
                Section("Presentation") {
                    Picker("Group by", selection: $perspective.groupBy) { ForEach(GroupBy.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Picker("Sort by", selection: $perspective.sortBy) { ForEach(SortBy.allCases, id: \.self) { Text($0.label).tag($0) } }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Perspective" : "Edit Perspective")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let p = perspective
                        model.perform(isNew ? "New Perspective" : "Edit Perspective") { tx in
                            if isNew { tx.createPerspective(p) } else { tx.writePerspective(p) }
                        }
                        model.sidebar = .perspective(p.id)
                        dismiss()
                    }
                    .disabled(perspective.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }
}

enum RuleType: String, CaseIterable, Identifiable {
    case availability, status, anyTags, allTags, tagStatus, untagged, projectStatus, focus
    case hasDue, hasDefer, repeats, isProject, isGroup, noProject, search, date, group, unsupported
    var id: String { rawValue }

    var label: String {
        switch self {
        case .availability: "Availability"; case .status: "Status"; case .anyTags: "Has any of tags"; case .allTags: "Has all of tags"
        case .tagStatus: "Has a tag with status"; case .untagged: "Is untagged"; case .projectStatus: "Project status"
        case .focus: "Within projects / folders"; case .hasDue: "Has a due date"; case .hasDefer: "Has a defer date"
        case .repeats: "Repeats"; case .isProject: "Is a project"; case .isGroup: "Is an action group"; case .noProject: "Is in the Inbox"
        case .search: "Text contains"; case .date: "Date"; case .group: "Group of rules"; case .unsupported: "Imported rule"
        }
    }

    static var pickable: [RuleType] { allCases.filter { $0 != .unsupported } }

    static func of(_ rule: JSON) -> RuleType {
        guard let o = rule.object else { return .unsupported }
        if o["aggregateRules"] != nil { return .group }
        if o["actionAvailability"] != nil { return .availability }
        if o["actionStatus"] != nil { return .status }
        if o["actionHasAnyOfTags"] != nil { return .anyTags }
        if o["actionHasAllOfTags"] != nil { return .allTags }
        if o["actionHasTagWithStatus"] != nil { return .tagStatus }
        if o["actionIsUntagged"] != nil { return .untagged }
        if o["actionHasProjectWithStatus"] != nil { return .projectStatus }
        if o["actionWithinFocus"] != nil { return .focus }
        if o["actionHasDueDate"] != nil { return .hasDue }
        if o["actionHasDeferDate"] != nil { return .hasDefer }
        if o["actionRepeats"] != nil { return .repeats }
        if o["actionIsProject"] != nil { return .isProject }
        if o["actionIsGroup"] != nil { return .isGroup }
        if o["actionHasNoProject"] != nil { return .noProject }
        if o["actionMatchingSearch"] != nil { return .search }
        if o["actionDateField"] != nil { return .date }
        return .unsupported
    }

    var defaultRule: JSON {
        switch self {
        case .availability: .object(["actionAvailability": "available"])
        case .status: .object(["actionStatus": "flagged"])
        case .anyTags: .object(["actionHasAnyOfTags": .array([])])
        case .allTags: .object(["actionHasAllOfTags": .array([])])
        case .tagStatus: .object(["actionHasTagWithStatus": "active"])
        case .untagged: .object(["actionIsUntagged": true])
        case .projectStatus: .object(["actionHasProjectWithStatus": "active"])
        case .focus: .object(["actionWithinFocus": .array([])])
        case .hasDue: .object(["actionHasDueDate": true])
        case .hasDefer: .object(["actionHasDeferDate": true])
        case .repeats: .object(["actionRepeats": true])
        case .isProject: .object(["actionIsProject": true])
        case .isGroup: .object(["actionIsGroup": true])
        case .noProject: .object(["actionHasNoProject": true])
        case .search: .object(["actionMatchingSearch": .array([""])])
        case .date: .object(["actionDateField": "due", "actionDateIsInTheNext": .object(["amount": 7, "unit": "day"])])
        case .group: .object(["aggregateType": "any", "aggregateRules": .array([])])
        case .unsupported: .object([:])
        }
    }
}

struct RuleList: View {
    @Binding var rules: [JSON]
    @Binding var aggregation: String
    var depth = 0

    var body: some View {
        Picker(depth == 0 ? "Match" : "Match", selection: $aggregation) {
            Text("All of the following").tag("all")
            Text("Any of the following").tag("any")
            Text("None of the following").tag("none")
        }
        ForEach(rules.indices, id: \.self) { i in
            RuleRow(rule: Binding(get: { rules.indices.contains(i) ? rules[i] : .null }, set: { if rules.indices.contains(i) { rules[i] = $0 } }),
                    depth: depth, remove: { rules.remove(at: i) })
        }
        Menu {
            ForEach(RuleType.pickable) { t in Button(t.label) { rules.append(t.defaultRule) } }
        } label: { Label("Add rule", systemImage: "plus.circle") }
        .padding(.leading, CGFloat(depth) * 16)
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: JSON
    let depth: Int
    let remove: () -> Void

    var body: some View {
        let type = RuleType.of(rule)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if type == .unsupported || !PerspectiveEngine.isSupported(rule) {
                    Label("Imported rule (kept, not applied)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Picker("", selection: Binding(get: { type }, set: { rule = $0.defaultRule })) {
                        ForEach(RuleType.pickable) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if type != .group && type != .unsupported { editor(type) }
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            if type == .group || type == .unsupported { editor(type) }
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    @ViewBuilder
    func editor(_ type: RuleType) -> some View {
        switch type {
        case .availability: choice("actionAvailability", [("available", "Available"), ("remaining", "Remaining"), ("firstAvailable", "First available (next action)"), ("completed", "Completed"), ("dropped", "Dropped")])
        case .status: choice("actionStatus", [("flagged", "Flagged"), ("due", "Due or due soon")])
        case .tagStatus: choice("actionHasTagWithStatus", [("active", "Active"), ("onHold", "On hold"), ("remaining", "Active or on hold"), ("dropped", "Dropped")])
        case .projectStatus: choice("actionHasProjectWithStatus", [("active", "Active"), ("onHold", "On hold"), ("remaining", "Active or on hold"), ("stalled", "Stalled"), ("pending", "Pending (deferred)"), ("completed", "Completed"), ("dropped", "Dropped")])
        case .anyTags: tagPicker("actionHasAnyOfTags")
        case .allTags: tagPicker("actionHasAllOfTags")
        case .focus: focusPicker()
        case .hasDue: boolean("actionHasDueDate")
        case .hasDefer: boolean("actionHasDeferDate")
        case .repeats: boolean("actionRepeats")
        case .isProject: boolean("actionIsProject")
        case .isGroup: boolean("actionIsGroup")
        case .noProject: boolean("actionHasNoProject")
        case .untagged: EmptyView()
        case .search:
            TextField("Words", text: Binding(get: { rule["actionMatchingSearch"]?.array?.first?.string ?? "" },
                                             set: { rule = .object(["actionMatchingSearch": .array([.string($0)])]) }))
        case .date: dateEditor()
        case .group:
            RuleList(rules: Binding(get: { rule["aggregateRules"]?.array ?? [] }, set: { setKey("aggregateRules", .array($0)) }),
                     aggregation: Binding(get: { rule["aggregateType"]?.string ?? "any" }, set: { setKey("aggregateType", .string($0)) }),
                     depth: depth + 1)
        case .unsupported:
            Text(rule.text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    func setKey(_ key: String, _ value: JSON) {
        var o = rule.object ?? [:]; o[key] = value; rule = .object(o)
    }

    func choice(_ key: String, _ options: [(String, String)]) -> some View {
        Picker("", selection: Binding(get: { rule[key]?.string ?? options[0].0 }, set: { setKey(key, .string($0)) })) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden().fixedSize()
    }

    func boolean(_ key: String) -> some View {
        Picker("", selection: Binding(get: { rule[key]?.bool ?? true }, set: { setKey(key, .bool($0)) })) {
            Text("Yes").tag(true); Text("No").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    func tagPicker(_ key: String) -> some View {
        let s = model.snapshot
        let selected = Set(rule[key]?.array?.compactMap(\.string) ?? [])
        return Menu(selected.isEmpty ? "Choose tags" : s.tagNames(Array(selected).sorted()).joined(separator: ", ")) {
            ForEach(s.orderedTags, id: \.tag.id) { e in
                let on = selected.contains(e.tag.id)
                Button { var n = selected; if on { n.remove(e.tag.id) } else { n.insert(e.tag.id) }; setKey(key, .array(n.sorted().map(JSON.string))) } label: {
                    Label(String(repeating: "   ", count: e.depth) + e.tag.name, systemImage: on ? "checkmark" : "")
                }
            }
        }
    }

    func focusPicker() -> some View {
        let s = model.snapshot
        let selected = Set(rule["actionWithinFocus"]?.array?.compactMap(\.string) ?? [])
        let names = selected.compactMap { s.folders[$0]?.name ?? s.tasks[$0]?.title }.sorted()
        func toggle(_ id: String) {
            var n = selected; if n.contains(id) { n.remove(id) } else { n.insert(id) }
            setKey("actionWithinFocus", .array(n.sorted().map(JSON.string)))
        }
        return Menu(names.isEmpty ? "Everything" : names.joined(separator: ", ")) {
            Section("Folders") {
                ForEach(s.orderedFolders, id: \.folder.id) { e in
                    Button { toggle(e.folder.id) } label: { Label(String(repeating: "   ", count: e.depth) + e.folder.name, systemImage: selected.contains(e.folder.id) ? "checkmark" : "folder") }
                }
            }
            Section("Projects") {
                ForEach(s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true }) { p in
                    Button { toggle(p.id) } label: { Label(p.title, systemImage: selected.contains(p.id) ? "checkmark" : "circle.grid.2x2") }
                }
            }
        }
    }

    func dateEditor() -> some View {
        let field = rule["actionDateField"]?.string ?? "due"
        let condition: String = ["actionDateIsToday", "actionDateIsTomorrow", "actionDateIsYesterday", "actionDateIsInTheNext", "actionDateIsInThePast"]
            .first { rule[$0] != nil } ?? "actionDateIsInTheNext"
        let amount = rule[condition]?["amount"]?.int ?? 7
        func write(field: String, condition: String, amount: Int) {
            var o: [String: JSON] = ["actionDateField": .string(field)]
            o[condition] = condition.hasSuffix("Next") || condition.hasSuffix("Past") ? .object(["amount": .number(Double(amount)), "unit": "day"]) : true
            rule = .object(o)
        }
        return HStack {
            Picker("", selection: Binding(get: { field }, set: { write(field: $0, condition: condition, amount: amount) })) {
                Text("Due").tag("due"); Text("Defer").tag("defer"); Text("Planned").tag("planned")
                Text("Completed").tag("completed"); Text("Added").tag("added"); Text("Changed").tag("changed")
            }.labelsHidden().fixedSize()
            Picker("", selection: Binding(get: { condition }, set: { write(field: field, condition: $0, amount: amount) })) {
                Text("is today").tag("actionDateIsToday"); Text("is tomorrow").tag("actionDateIsTomorrow"); Text("was yesterday").tag("actionDateIsYesterday")
                Text("in the next").tag("actionDateIsInTheNext"); Text("in the past").tag("actionDateIsInThePast")
            }.labelsHidden().fixedSize()
            if condition.hasSuffix("Next") || condition.hasSuffix("Past") {
                Stepper("\(amount) days", value: Binding(get: { amount }, set: { write(field: field, condition: condition, amount: max(1, $0)) }), in: 1...365)
            }
        }
    }
}
