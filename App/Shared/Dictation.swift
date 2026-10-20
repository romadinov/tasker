import AVFoundation
import Foundation
import Observation
import Speech
#if os(macOS)
import Carbon
#endif

/// Speech entry: live transcription with Apple's Speech framework (on-device when the language
/// supports it). Listening stops by itself after a short pause, or when `stop()` is called.
@MainActor @Observable
final class Dictation {
    enum State: Equatable { case idle, starting, listening, denied(String), failed(String) }

    private(set) var state: State = .idle
    /// What has been recognised so far in this session.
    private(set) var transcript = ""
    var isListening: Bool { state == .listening || state == .starting }

    /// Languages offered in the menu (those the recogniser supports), Russian and English first.
    static var languages: [Locale] {
        let supported = SFSpeechRecognizer.supportedLocales()
        let preferred = ["ru-RU", "en-US", "en-GB"].map(Locale.init(identifier:)).filter { supported.contains($0) }
        let rest = Locale.preferredLanguages.map(Locale.init(identifier:))
            .compactMap { l in supported.first { $0.language.languageCode == l.language.languageCode } }
        var out: [Locale] = []
        for l in preferred + rest where !out.contains(l) { out.append(l) }
        return out
    }

    /// The language to listen in: the one picked in the menu, else (Mac) the current keyboard layout's
    /// language, else the system language.
    var locale: Locale {
        get {
            if let id = UserDefaults.standard.string(forKey: "speech.locale") { return Locale(identifier: id) }
            return Self.defaultLocale
        }
        set { UserDefaults.standard.set(newValue.identifier, forKey: "speech.locale") }
    }
    var followsKeyboard: Bool { UserDefaults.standard.string(forKey: "speech.locale") == nil }
    func followKeyboard() { UserDefaults.standard.removeObject(forKey: "speech.locale") }

    static var defaultLocale: Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        func match(_ code: String) -> Locale? {
            let lang = Locale(identifier: code).language.languageCode
            return supported.first { $0.identifier == code } ?? supported.first { $0.language.languageCode == lang && $0.region == Locale.current.region }
                ?? supported.first { $0.language.languageCode == lang }
        }
        #if os(macOS)
        if let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first, let l = match(first) { return l }
        #endif
        for code in Locale.preferredLanguages { if let l = match(code) { return l } }
        return Locale(identifier: "en-US")
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onFinish: ((String) -> Void)?

    /// Starts listening. `onFinish` gets the final text once listening ends (pause, `stop()`, or error).
    func start(onFinish: @escaping (String) -> Void) {
        guard !isListening else { return }
        self.onFinish = onFinish
        transcript = ""
        state = .starting
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.state = .denied("Speech recognition is off for Uberdoer. Allow it in System Settings → Privacy & Security → Speech Recognition.")
                    return
                }
                #if os(iOS)
                let micOK = await AVAudioApplication.requestRecordPermission()
                #else
                let micOK = await AVCaptureDevice.requestAccess(for: .audio)
                #endif
                guard micOK else {
                    self.state = .denied("Microphone access is off for Uberdoer. Allow it in System Settings → Privacy & Security → Microphone.")
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            state = .failed("Speech recognition for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) isn't available right now.")
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            state = .listening
            armSilenceTimer(initial: true)

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        self.armSilenceTimer(initial: false)
                        if result.isFinal { self.finish() }
                    } else if error != nil, self.isListening {
                        self.finish()
                    }
                }
            }
        } catch {
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            teardown()
        }
    }

    /// Stops after ~1.6 s without new words (8 s grace before the first word).
    private func armSilenceTimer(initial: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: initial ? 8 : 1.6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        guard isListening else { return }
        request?.endAudio()
        // Give the recogniser a moment to deliver the final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.finish() }
    }

    func cancel() {
        onFinish = nil
        teardown()
        state = .idle
    }

    private func finish() {
        guard isListening else { return }
        teardown()
        state = .idle
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = onFinish
        onFinish = nil
        done?(text)
    }

    private func teardown() {
        silenceTimer?.invalidate(); silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
