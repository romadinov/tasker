import SwiftUI
import TaskerCore

/// Slim bar above every view while a pomodoro is active: phase, task, countdown, controls.
struct PomodoroBar: View {
    @Environment(AppModel.self) private var model
    private var timer: PomodoroTimer { PomodoroTimer.shared }

    var body: some View {
        if timer.isActive {
            let title = timer.taskID.flatMap { model.snapshot.tasks[$0]?.title } ?? "—"
            let tint: Color = timer.isBreak ? .green : (timer.phase == .ready ? .secondary : .red)
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(tint.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: timer.progress).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("🍅").font(.system(size: 10))
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(timer.phase == .ready ? "Break over — ready for the next one" : timer.phaseLabel + (timer.isPaused ? " (paused)" : ""))
                        .font(.caption).foregroundStyle(tint)
                    Button { if let id = timer.taskID { model.reveal(id) } } label: {
                        Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Show the action")
                }
                Spacer(minLength: 8)
                if timer.phase != .ready {
                    Text(timer.display).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
                }
                PomodoroControls(compact: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(tint.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// Pause/Resume, +5, Skip, Complete, Stop. Buttons (bar) or menu items (menu bar).
struct PomodoroControls: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var tickOn = TickSound.shared.enabled
    private var timer: PomodoroTimer { PomodoroTimer.shared }

    var body: some View {
        let buttons = Group {
            if timer.phase == .ready {
                Button { timer.startNext() } label: { Label("Start Next Pomodoro", systemImage: "play.fill") }
            } else if timer.isPaused {
                Button { timer.resume() } label: { Label("Resume", systemImage: "play.fill") }
            } else {
                Button { timer.pause() } label: { Label("Pause", systemImage: "pause.fill") }
            }
            Button { TickSound.shared.enabled.toggle(); tickOn = TickSound.shared.enabled } label: {
                Label(tickOn ? "Ticking Sound On" : "Ticking Sound Off", systemImage: tickOn ? "speaker.wave.2.fill" : "speaker.slash")
            }
            .help("Ticking sound while focusing")
            if timer.phase != .ready {
                Button { timer.addFiveMinutes() } label: { Label("+5 min", systemImage: "goforward.5") }
                Button { timer.skip() } label: { Label(timer.isBreak ? "Skip Break" : "Skip (don't count)", systemImage: "forward.end.fill") }
            }
            if let id = timer.taskID, model.snapshot.tasks[id]?.isCompleted == false {
                Button {
                    model.toggleComplete(id)
                    timer.stop()
                } label: { Label("Complete Action", systemImage: "checkmark.circle") }
            }
            Button(role: .destructive) { timer.stop() } label: { Label("Stop", systemImage: "stop.fill") }
        }
        if compact {
            HStack(spacing: 2) { buttons.labelStyle(.iconOnly).buttonStyle(.borderless) }
        } else {
            buttons
        }
    }
}

/// "🍅 3" on rows and cards (pomodoros done on the action), or the live countdown on the running one.
struct PomodoroBadge: View {
    let task: TaskItem
    private var timer: PomodoroTimer { PomodoroTimer.shared }

    var body: some View {
        if timer.isActive && timer.taskID == task.id && timer.phase != .ready {
            Badge(text: "🍅 " + timer.display, color: timer.isBreak ? .green : .red)
        } else if task.pomodoroCount > 0 {
            Badge(text: "🍅 \(task.pomodoroCount)", color: .secondary)
                .help("\(task.pomodoroCount) pomodoros, \(Fmt.estimate(task.focusMinutes)) focused")
        }
    }
}

struct PomodoroSettingsSection: View {
    @State private var work = PomodoroTimer.shared.workMinutes
    @State private var short = PomodoroTimer.shared.shortBreakMinutes
    @State private var long = PomodoroTimer.shared.longBreakMinutes
    @State private var every = PomodoroTimer.shared.longEvery
    @State private var tick = TickSound.shared.enabled

    var body: some View {
        Section("Pomodoro") {
            Stepper("Focus: \(work) min", value: $work, in: 5...90, step: 5)
            Stepper("Short break: \(short) min", value: $short, in: 1...30)
            Stepper("Long break: \(long) min", value: $long, in: 5...60, step: 5)
            Stepper("Long break after every \(every) pomodoros", value: $every, in: 2...8)
            Toggle("Ticking sound while focusing", isOn: $tick)
        }
        .onChange(of: tick) { _, v in TickSound.shared.enabled = v }
        .onChange(of: work) { _, v in PomodoroTimer.shared.workMinutes = v }
        .onChange(of: short) { _, v in PomodoroTimer.shared.shortBreakMinutes = v }
        .onChange(of: long) { _, v in PomodoroTimer.shared.longBreakMinutes = v }
        .onChange(of: every) { _, v in PomodoroTimer.shared.longEvery = v }
    }
}
