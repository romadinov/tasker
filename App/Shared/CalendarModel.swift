import EventKit
import Observation
import SwiftUI

/// Calendar events shown in Forecast (read-only), like OmniFocus.
@MainActor @Observable
final class CalendarModel {
    static let shared = CalendarModel()

    struct Event: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendarTitle: String
        let color: Color
        let location: String?
    }

    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let source: String
        let color: Color
    }

    @ObservationIgnored private let store = EKEventStore()
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var calendars: [CalendarInfo] = []
    /// Bumped whenever the calendar database changes, so views refetch.
    private(set) var revision = 0

    var enabled: Bool = UserDefaults.standard.object(forKey: "forecast.calendar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "forecast.calendar") }
    }
    var hiddenCalendars: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "forecast.hiddenCalendars") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenCalendars), forKey: "forecast.hiddenCalendars"); revision += 1 }
    }

    var hasAccess: Bool { status == .fullAccess }

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        if hasAccess { reload() }
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        status = EKEventStore.authorizationStatus(for: .event)
        reload()
    }

    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { calendars = []; return }
        store.refreshSourcesIfNecessary()
        calendars = store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, color: Color(cgColor: $0.cgColor)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        revision += 1
    }

    func events(from start: Date, to end: Date) -> [Event] {
        _ = revision
        guard enabled, hasAccess, end > start else { return [] }
        let cals = store.calendars(for: .event).filter { !hiddenCalendars.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { e in
                Event(id: (e.eventIdentifier ?? UUID().uuidString) + "@\(e.startDate.timeIntervalSince1970)",
                      title: e.title ?? "Untitled event", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                      calendarTitle: e.calendar.title, color: Color(cgColor: e.calendar.cgColor),
                      location: e.location?.isEmpty == false ? e.location : nil)
            }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
    }

    func events(on day: Date) -> [Event] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        return events(from: start, to: cal.date(byAdding: .day, value: 1, to: start)!)
    }
}

struct EventRow: View {
    @Environment(AppModel.self) private var model
    let event: CalendarModel.Event

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(timeText).monospacedDigit()
                    Text(event.calendarTitle)
                    if let l = event.location { Text(l).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("New Action from Event") {
                model.quickAdd(title: event.title, note: [event.calendarTitle, event.location].compactMap { $0 }.joined(separator: " · "),
                               projectID: nil, tagIDs: [], flagged: false, deferDate: nil,
                               dueDate: event.isAllDay ? Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: event.start) : event.start)
            }
        }
    }

    var timeText: String {
        if event.isAllDay { return "All day" }
        let s = event.start.formatted(date: .omitted, time: .shortened)
        let e = event.end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}

/// Settings section: enable events in Forecast and pick calendars.
struct CalendarSettingsSection: View {
    @State private var cal = CalendarModel.shared

    var body: some View {
        Section {
            Toggle("Show calendar events in Forecast", isOn: Binding(get: { cal.enabled }, set: { cal.enabled = $0 }))
            if cal.enabled {
                if cal.hasAccess {
                    ForEach(cal.calendars) { c in
                        Toggle(isOn: Binding(get: { !cal.hiddenCalendars.contains(c.id) }, set: { on in
                            if on { cal.hiddenCalendars.remove(c.id) } else { cal.hiddenCalendars.insert(c.id) }
                        })) {
                            HStack {
                                Circle().fill(c.color).frame(width: 10, height: 10)
                                Text(c.title)
                                Text(c.source).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                } else if cal.status == .notDetermined {
                    Button("Allow Calendar Access…") { Task { await cal.requestAccess() } }
                } else {
                    Text("Calendar access is off. Turn it on in System Settings → Privacy & Security → Calendars.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Calendar") }
    }
}
