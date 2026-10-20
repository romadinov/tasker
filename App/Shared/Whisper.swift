import Foundation
import Observation
import WhisperKit

/// On-device Whisper (WhisperKit, Core ML). The model is downloaded once (~630 MB on the Mac) into
/// Application Support and then loaded on first use.
@MainActor @Observable
final class WhisperModel {
    static let shared = WhisperModel()

    enum Status: Equatable { case notDownloaded, downloading(Double), loading, ready, failed(String) }
    private(set) var status: Status
    private var kit: WhisperKit?
    private var preparing: Task<WhisperKit?, Never>?

    /// Large-v3 turbo on the Mac (best quality, fast on Apple silicon); on iPhone/iPad, what WhisperKit
    /// recommends for the device.
    static var variant: String {
        #if os(macOS)
        "openai_whisper-large-v3-v20240930_turbo_632MB"
        #else
        WhisperKit.recommendedModels().default
        #endif
    }

    static var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return base.appendingPathComponent("Tasker/Whisper", isDirectory: true)
        #else
        return base.appendingPathComponent("Whisper", isDirectory: true)
        #endif
    }

    private static let folderKey = "whisper.modelFolder"
    private static var savedFolder: URL? {
        guard let p = UserDefaults.standard.string(forKey: folderKey), p.contains(variant),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    var isDownloaded: Bool { Self.savedFolder != nil }
    /// True until the model has loaded once on this device (Core ML compiles it the first time).
    var firstLoad: Bool { !UserDefaults.standard.bool(forKey: "whisper.loadedOnce") }

    init() { status = Self.savedFolder == nil ? .notDownloaded : .loading }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly.
    @discardableResult
    func prepare() async -> WhisperKit? {
        if let kit { return kit }
        if let preparing { return await preparing.value }
        let t = Task<WhisperKit?, Never> { @MainActor in
            do {
                var folder = Self.savedFolder
                if folder == nil {
                    status = .downloading(0)
                    try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
                    let url = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.downloadBase) { p in
                        Task { @MainActor in WhisperModel.shared.status = .downloading(p.fractionCompleted) }
                    }
                    UserDefaults.standard.set(url.path, forKey: Self.folderKey)
                    folder = url
                }
                status = .loading
                let k = try await WhisperKit(WhisperKitConfig(modelFolder: folder!.path, verbose: false, logLevel: .error,
                                                              prewarm: false, load: true, download: false))
                kit = k
                UserDefaults.standard.set(true, forKey: "whisper.loadedOnce")
                status = .ready
                return k
            } catch {
                status = .failed(error.localizedDescription)
                return nil
            }
        }
        preparing = t
        let k = await t.value
        preparing = nil
        return k
    }

    /// Transcribes 16 kHz mono samples. `language` nil = detect; if the detected language isn't one
    /// of `expected`, it is redone in `fallback` (short phrases are easy to mis-detect).
    func transcribe(_ samples: [Float], language: String?, expected: Set<String>, fallback: String) async -> String {
        guard let kit = await prepare(), !samples.isEmpty else { return "" }
        func run(_ lang: String?) async -> (String, String?) {
            let options = DecodingOptions(language: lang, temperatureFallbackCount: 2, usePrefillPrompt: lang != nil,
                                          detectLanguage: lang == nil, skipSpecialTokens: true, withoutTimestamps: true)
            let results = (try? await kit.transcribe(audioArray: samples, decodeOptions: options)) ?? []
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (text, results.first?.language)
        }
        var (text, detected) = await run(language)
        if language == nil, let d = detected, !expected.contains(d) { (text, _) = await run(fallback) }
        return Self.clean(text)
    }

    /// Whisper sometimes "hears" stock phrases in near-silence; drop those.
    static func clean(_ s: String) -> String {
        let junk = ["Продолжение следует", "Субтитры", "Thank you for watching", "Thanks for watching", "[BLANK_AUDIO]", "(music)"]
        var t = s
        for j in junk where t.localizedCaseInsensitiveContains(j) { t = t.replacingOccurrences(of: j, with: "", options: .caseInsensitive) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "?!"))))
            .isEmpty ? "" : t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
