import Foundation
#if os(macOS)
import AppKit
#endif
import Observation
import TaskerCore
import UserNotifications

/// Pomodoro timer for one action: work → break (long one after every fourth) → ready for the next.
/// The state is stored by end time, so it survives quitting the app and backgrounding on iOS;
/// a notification fires when a phase ends. Each finished work session is logged on the action.
@MainActor @Observable
final class PomodoroTimer {
    static let shared = PomodoroTimer()

    enum Phase: String, Codable { case idle, work, shortBreak, longBreak, ready }

    private(set) var phase: Phase = .idle
    private(set) var taskID: String?
    private(set) var endsAt: Date?
    private(set) var pausedRemaining: TimeInterval?
    private(set) var startedAt: Date?
    /// Work sessions finished in the current cycle (a long break follows every `longEvery`).
    private(set) var cycleCount = 0
    /// Ticks every second while running, to refresh countdowns.
    private(set) var now = Date()
    private var ticker: Timer?

    // Durations (per device).
    var workMinutes: Int { get { Self.int("pomodoro.work", 25) } set { UserDefaults.standard.set(newValue, forKey: "pomodoro.work") } }
    var shortBreakMinutes: Int { get { Self.int("pomodoro.short", 5) } set { UserDefaults.standard.set(newValue, forKey: "pomodoro.short") } }
    var longBreakMinutes: Int { get { Self.int("pomodoro.long", 15) } set { UserDefaults.standard.set(newValue, forKey: "pomodoro.long") } }
    var longEvery: Int { get { Self.int("pomodoro.longEvery", 4) } set { UserDefaults.standard.set(newValue, forKey: "pomodoro.longEvery") } }
    private static func int(_ k: String, _ d: Int) -> Int { let v = UserDefaults.standard.integer(forKey: k); return v > 0 ? v : d }

    var isActive: Bool { phase != .idle }
    var isRunning: Bool { endsAt != nil && pausedRemaining == nil }
    var isPaused: Bool { pausedRemaining != nil }
    var isBreak: Bool { phase == .shortBreak || phase == .longBreak }

    var remaining: TimeInterval {
        if let p = pausedRemaining { return p }
        guard let e = endsAt else { return 0 }
        return max(0, e.timeIntervalSince(now))
    }

    /// "24:13"
    var display: String {
        let r = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", r / 60, r % 60)
    }

    var phaseLabel: String {
        switch phase {
        case .idle: ""; case .work: "Focus"; case .shortBreak: "Break"; case .longBreak: "Long break"; case .ready: "Ready"
        }
    }

    /// 0…1 of the current phase.
    var progress: Double {
        let total = Double(minutes(for: phase) * 60)
        return total > 0 ? min(1, max(0, 1 - remaining / total)) : 0
    }

    private init() {
        restore()
        #if os(macOS)
        // Closing the lid (sleep) or locking the screen pauses the timer; it stays paused on wake.
        let pauseIt: @Sendable (Notification) -> Void = { _ in Task { @MainActor in PomodoroTimer.shared.pause(reason: "Mac slept") } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: pauseIt)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: pauseIt)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in PomodoroTimer.shared.pause(reason: "screen locked") }
        }
        #endif
    }

    // MARK: Controls

    func start(_ id: String) {
        if taskID != id { cycleCount = 0 }
        taskID = id
        begin(.work)
        requestNotifications()
    }

    /// Next work session on the same action (after a break, or from "Ready").
    func startNext() {
        guard let taskID else { return }
        start(taskID)
    }

    /// Why the timer was paused automatically (shown in the bar), nil when paused by hand.
    private(set) var pauseReason: String?

    func pause(reason: String? = nil) {
        guard isRunning else { return }
        pauseReason = reason
        pausedRemaining = remaining
        endsAt = nil
        cancelNotification()
        stopTicking()
        save()
    }

    func resume() {
        guard let p = pausedRemaining else { return }
        pauseReason = nil
        endsAt = Date().addingTimeInterval(p)
        pausedRemaining = nil
        scheduleNotification()
        startTicking()
        save()
    }

    func addFiveMinutes() {
        if let p = pausedRemaining { pausedRemaining = p + 300 }
        else if let e = endsAt { endsAt = e.addingTimeInterval(300); scheduleNotification() }
        save()
    }

    /// Skip the rest of a break (or end work early without logging it).
    func skip() {
        if phase == .work { phase = .ready; endsAt = nil; pausedRemaining = nil; cancelNotification(); stopTicking(); save() }
        else if isBreak { startNext() }
    }

    func stop() {
        phase = .idle; taskID = nil; endsAt = nil; pausedRemaining = nil; startedAt = nil; cycleCount = 0
        cancelNotification()
        stopTicking()
        save()
    }

    // MARK: Phases

    private func minutes(for p: Phase) -> Int {
        switch p { case .work: workMinutes; case .shortBreak: shortBreakMinutes; case .longBreak: longBreakMinutes; default: 0 }
    }

    private func begin(_ p: Phase) {
        phase = p
        startedAt = Date()
        endsAt = Date().addingTimeInterval(TimeInterval(minutes(for: p) * 60))
        pausedRemaining = nil
        now = Date()
        scheduleNotification()
        startTicking()
        save()
    }

    private func tick() {
        now = Date()
        if let e = endsAt, now >= e { phaseEnded(at: e) }
    }

    private func phaseEnded(at end: Date) {
        switch phase {
        case .work:
            if let id = taskID {
                let minutes = workMinutes
                AppModel.shared.perform("Pomodoro") { $0.logPomodoro(id, at: end, minutes: minutes) }
            }
            cycleCount += 1
            begin(cycleCount % longEvery == 0 ? .longBreak : .shortBreak)
        case .shortBreak, .longBreak:
            phase = .ready; endsAt = nil; stopTicking(); save()
        default:
            break
        }
    }

    #if DEBUG
    /// Test hook: end the current phase now.
    func debugEndPhase() { if endsAt != nil { phaseEnded(at: Date()) } }
    #endif

    /// Ticking sound follows "focus running"; App Nap stays off while a pomodoro is active, so the
    /// countdown (menu bar, notifications' timing) keeps up when Uberdoer isn't in front.
    private var activity: NSObjectProtocol?
    private func syncBackgroundState() {
        TickSound.shared.update(playing: phase == .work && isRunning)
        if isActive && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Pomodoro timer")
        } else if !isActive, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }
    }

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 1, repeats: true) { _ in Task { @MainActor in PomodoroTimer.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() { ticker?.invalidate(); ticker = nil }

    // MARK: Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotification() {
        cancelNotification()
        guard let e = endsAt, e > Date() else { return }
        let title = taskID.flatMap { AppModel.shared.snapshot.tasks[$0]?.title } ?? "Pomodoro"
        let c = UNMutableNotificationContent()
        switch phase {
        case .work:
            let long = (cycleCount + 1) % longEvery == 0
            c.title = "Pomodoro done 🍅"
            c.body = "\(title)\nTime for a \(long ? "long " : "")break (\(long ? longBreakMinutes : shortBreakMinutes) min)."
        default:
            c.title = "Break over"
            c.body = "Back to: \(title)"
        }
        c.sound = .default
        let req = UNNotificationRequest(identifier: "pomodoro", content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, e.timeIntervalSinceNow), repeats: false))
        UNUserNotificationCenter.current().add(req)
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pomodoro"])
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var phase: Phase; var taskID: String?; var endsAt: Date?; var pausedRemaining: TimeInterval?; var startedAt: Date?; var cycleCount: Int
    }

    private func save() {
        syncBackgroundState()
        let s = Saved(phase: phase, taskID: taskID, endsAt: endsAt, pausedRemaining: pausedRemaining, startedAt: startedAt, cycleCount: cycleCount)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "pomodoro.state")
    }

    /// Picks up where it was; a work session that ended while the app was closed is still logged.
    private func restore() {
        guard let d = UserDefaults.standard.data(forKey: "pomodoro.state"), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        phase = s.phase; taskID = s.taskID; endsAt = s.endsAt; pausedRemaining = s.pausedRemaining; startedAt = s.startedAt; cycleCount = s.cycleCount
        guard isActive else { return }
        if let e = endsAt {
            if e <= Date() {
                // Let the model finish starting before logging.
                DispatchQueue.main.async { self.phaseEnded(at: e) }
            } else {
                startTicking()
                DispatchQueue.main.async { self.syncBackgroundState() }
            }
        }
    }
}
