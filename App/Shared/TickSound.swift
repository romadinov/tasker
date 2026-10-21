import AVFoundation
import Foundation

/// A soft mechanical tick-tock, synthesised once in memory (no audio file to ship).
@MainActor
final class TickSound {
    static let shared = TickSound()
    /// A one-second kitchen-timer loop (four identical clicks) played while focusing. One continuous sound,
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

    /// One second of a wind-up kitchen timer: four identical, dry mechanical clicks.
    private static func loopPlayer() -> AVAudioPlayer? {
        let rate = 44_100.0, total = Int(rate)
        var samples = [Int16](repeating: 0, count: total)
        // The same click every time (fixed noise seed): a short noise burst through a ringing resonance.
        var click = [Double](repeating: 0, count: Int(rate * 0.012))
        var seed: UInt32 = 0x5EED
        var y1 = 0.0, y2 = 0.0
        let f = 3400.0, r = 0.985
        let a1 = 2 * r * cos(2 * .pi * f / rate), a2 = -r * r
        for i in click.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = i < 60 ? Double(Int32(bitPattern: seed)) / Double(Int32.max) : 0
            let y = noise * 0.08 + a1 * y1 + a2 * y2
            y2 = y1; y1 = y
            click[i] = y * exp(-Double(i) / rate * 350)
        }
        let peak = click.map(abs).max() ?? 1
        for k in 0..<4 {
            let start = k * total / 4
            for (i, v) in click.enumerated() where start + i < total {
                samples[start + i] = Int16(v / peak * 0.3 * Double(Int16.max))
            }
        }
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
