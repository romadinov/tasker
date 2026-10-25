import Foundation
import MetricKit
import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// The shared agent feedback loop (~/Dev/agent-feedback): the app writes improvement notes and crash
/// reports into its iCloud container's Documents folder; a Mac-side router tells the session working on
/// this repo. The app is the only writer of these files; the tool writes the status and ledger files.
enum Feedback {
    /// The CloudKit container doubles as the iCloud Drive container (`iCloud~com~romadinov~tasker` on the Mac).
    static let containerID = "iCloud.com.romadinov.tasker"

    /// Documents/ in the iCloud container, or the local Documents folder without iCloud Drive. Blocks; call off the main thread.
    static func documents() -> URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["TASKER_FEEDBACK_DIR"] { return URL(fileURLWithPath: dir) }
        #endif
        return FileManager.default.url(forUbiquityContainerIdentifier: containerID)?.appending(path: "Documents")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") build \(info?["CFBundleVersion"] as? String ?? "?")"
    }

    static var device: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(String(cString: model)), macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #endif
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f.string(from: date)
    }
}

/// "Improvement notes.md" (TaskPaper), append-only: one item per note with where it was written, the build,
/// the device and an optional screenshot in "Improvement notes/".
enum ImprovementNotes {
    static func add(_ text: String, where context: String, screenshot: Data?, date: Date = Date()) throws {
        let docs = Feedback.documents()
        let file = docs.appending(path: "Improvement notes.md")
        var tags: [(String, String)] = [("date", date.formatted(.iso8601.year().month().day())), ("where", context),
                                        ("build", Feedback.build), ("device", Feedback.device)]
        if let screenshot {
            let folder = docs.appending(path: "Improvement notes")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "Screenshot \(Feedback.stamp(date)).png"
            try screenshot.write(to: folder.appending(path: name))
            tags.append(("screenshot", "Improvement notes/\(name)"))
        }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        var entry = "\t- " + oneLine(lines.first ?? "") + " " + tags.map { "@\($0.0)(\(tagValue($0.1)))" }.joined(separator: " ")
        let rest = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !rest.isEmpty { entry += "\n" + rest.map { "\t\t" + $0 }.joined(separator: "\n") }

        // Another device may have appended meanwhile: start from the latest copy, never a stale local one.
        waitUntilCurrent(file)
        var inner: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordination) { url in
            do {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if content.isEmpty { content = "Improvement notes:\n" }
                if !content.hasSuffix("\n") { content += "\n" }
                content += entry + "\n"
                try Data(content.utf8).write(to: url, options: .atomic)
            } catch { inner = error }
        }
        if let error = coordination ?? inner { throw error }
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func tagValue(_ s: String) -> String {
        oneLine(s).replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
    }

    static func waitUntilCurrent(_ url: URL, timeout: TimeInterval = 8) {
        guard (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var copy = url
            copy.removeAllCachedResourceValues()
            if (try? copy.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

/// Crash, hang and resource reports from MetricKit, saved to "Crash reports/" one file per report. MetricKit
/// delivers a report on the launch after the problem; nothing is sent anywhere else.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()
    private var device = "Device"

    /// Call at launch, on the main thread.
    @MainActor func start() {
        #if os(macOS)
        device = Host.current().localizedName ?? "Mac"
        #else
        device = UIDevice.current.model
        #endif
        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { save(past) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let device = device
        Task.detached(priority: .utility) {
            let folder = Feedback.documents().appending(path: "Crash reports")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            for payload in payloads {
                let crashes = payload.crashDiagnostics?.count ?? 0
                let hangs = payload.hangDiagnostics?.count ?? 0
                let other = (payload.cpuExceptionDiagnostics?.count ?? 0) + (payload.diskWriteExceptionDiagnostics?.count ?? 0)
                guard crashes + hangs + other > 0 else { continue }
                let kind = crashes > 0 ? "Crash" : (hangs > 0 ? "Hang" : "Resource")
                let name = "\(kind) \(Feedback.stamp(payload.timeStampEnd)) \(device) build \(build).json".replacingOccurrences(of: "/", with: "-")
                let url = folder.appending(path: name)
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
                    try? payload.jsonRepresentation().write(to: target, options: .atomic)
                }
            }
        }
    }
}

/// A note in progress: the screenshot is taken before the form covers the window.
struct ImprovementNoteRequest: Identifiable {
    let id = UUID()
    let context: String
    let screenshot: PlatformImage?
}

extension AppModel {
    /// "Suggest an Improvement…": capture the window (after the menu that triggered this has closed), then show the form.
    func suggestImprovement() {
        let context = feedbackContext
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            improvementNote = ImprovementNoteRequest(context: context, screenshot: Self.captureWindow())
        }
    }

    /// Where the note was written: the view, plus the selected item.
    var feedbackContext: String {
        var parts = [sidebarTitle]
        if let id = selection.first, let t = snapshot.tasks[id] {
            parts.append("\(t.isProject ? "project" : "action") “\(t.title.prefix(60))”")
        }
        return parts.joined(separator: ", ")
    }

    private var sidebarTitle: String {
        switch sidebar {
        case .perspective(let id): return snapshot.perspectives.first { $0.id == id }?.name ?? "Perspective"
        default: return sidebar?.title ?? "Uberdoer"
        }
    }

    static func captureWindow() -> PlatformImage? {
        #if os(macOS)
        let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
        #else
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        #endif
    }
}

extension PlatformImage {
    var pngBytes: Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return pngData()
        #endif
    }
}

/// The note form: text, where it was written, and the screenshot (on by default).
struct ImprovementNoteView: View {
    let request: ImprovementNoteRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var attach = true
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What could be better? Bugs, ideas, wishes…", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                } footer: {
                    Text("Noted at: \(request.context)")
                }
                if let shot = request.screenshot {
                    Section {
                        Toggle("Attach screenshot", isOn: $attach)
                        if attach {
                            image(shot).resizable().scaledToFit().frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Suggest an Improvement")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(width: 480, height: 460)
        #endif
    }

    private func image(_ shot: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: shot)
        #else
        Image(uiImage: shot)
        #endif
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let note = text, context = request.context
        let png = attach ? request.screenshot?.pngBytes : nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try ImprovementNotes.add(note, where: context, screenshot: png)
            }.value
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
