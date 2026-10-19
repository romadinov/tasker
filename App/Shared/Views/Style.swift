import SwiftUI
import TaskerCore

enum Palette {
    static let overdue = Color.red
    static let dueSoon = Color.orange
    static let flag = Color.orange
    static let deferred = Color.secondary
    static let project = Color.purple
    static let tag = Color.teal
    static let folder = Color.blue
}

enum Fmt {
    static func relative(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = cal.dateComponents([.hour, .minute], from: d)
        let hasTime = !(time.hour == 0 && time.minute == 0)
        let t = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return hasTime ? "Today \(t)" : "Today" }
        if cal.isDateInTomorrow(d) { return hasTime ? "Tomorrow \(t)" : "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        if days > 0 && days < 7 { return d.formatted(.dateTime.weekday(.wide)) + (hasTime ? " \(t)" : "") }
        return d.formatted(.dateTime.day().month(.abbreviated).year(cal.isDate(d, equalTo: now, toGranularity: .year) ? .omitted : .defaultDigits))
    }

    static func estimate(_ m: Int) -> String {
        m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") : "\(m)m"
    }
}

/// Small rounded label used for dates and tags in rows.
struct Badge: View {
    var text: String
    var systemImage: String?
    var color: Color = .secondary
    var filled = false
    /// On a selected (highlighted) row fixed colours become unreadable on the accent background,
    /// so badges switch to the highlight's own text colour.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onHighlight = prominence == .increased
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            if !text.isEmpty { Text(text).lineLimit(1) }
        }
        .font(.caption)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .foregroundStyle(onHighlight ? AnyShapeStyle(.primary) : AnyShapeStyle(filled ? Color.white : color))
        .background(Capsule().fill(onHighlight ? AnyShapeStyle(Color.primary.opacity(filled ? 0.28 : 0.16))
                                               : AnyShapeStyle(filled ? color : color.opacity(0.12))))
    }
}

struct ProjectIcon: View {
    var project: TaskItem
    var body: some View {
        let name: String = project.singleActions ? "list.bullet.circle" : (project.sequential ? "arrow.down.right.circle" : "circle.grid.2x2")
        Image(systemName: project.status == .onHold ? "pause.circle" : (project.status == .dropped ? "xmark.circle" : (project.status == .done ? "checkmark.circle" : name)))
            .foregroundStyle(project.status == .active ? Palette.project : .secondary)
    }
}
