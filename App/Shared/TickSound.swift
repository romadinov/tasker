import AVFoundation
import Foundation

/// A soft mechanical tick-tock, synthesised once in memory (no audio file to ship).
@MainActor
final class TickSound {
    static let shared = TickSound()
    /// Two seconds of audio (tick at 0 s, tock at 1 s) looped while focusing. One continuous sound,
    /// unlike a sound per timer tick, keeps going when the app is in the background: on the Mac it isn't
    /// throttled by App Nap, on iOS the audio background mode keeps it playing.
    private var loop: AVAudioPlayer?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pomodoro.tickSound") }
        set { UserDefaults.standard.set(newValue, forKey: "pomodoro.tickSound"); update(playing: wanted) }
    }

    /// Whether the timer currently wants ticking (focus running); the sound plays if also enabled.
    private var wanted = false

    private init() { loop = Self.loopPlayer() }
    var isPlaying: Bool { loop?.isPlaying ?? false }

    func update(playing: Bool) {
        wanted = playing
        guard let loop else { return }
        if playing && enabled {
            guard !loop.isPlaying else { return }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            loop.currentTime = 0
            loop.play()
        } else if loop.isPlaying {
            loop.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    private static func loopPlayer() -> AVAudioPlayer? {
        let rate = 44_100.0, total = Int(rate * 2)
        var samples = [Int16](repeating: 0, count: total)
        func click(at start: Int, frequency: Double) {
            var seed: UInt32 = 12345
            for i in 0..<Int(rate * 0.03) where start + i < total {
                let t = Double(i) / rate
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max) * 0.25
                let v = (sin(2 * .pi * frequency * t) + noise) * exp(-t * 180) * 0.35
                samples[start + i] = Int16(max(-1, min(1, v)) * Double(Int16.max))
            }
        }
        click(at: 0, frequency: 2600)
        click(at: Int(rate), frequency: 2100)
        var data = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        let bytes = UInt32(total * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let p = try? AVAudioPlayer(data: data)
        p?.numberOfLoops = -1
        p?.volume = 0.5
        p?.prepareToPlay()
        return p
    }
}
