import AVFoundation
import Foundation

/// A soft mechanical tick-tock, synthesised once in memory (no audio file to ship).
@MainActor
final class TickSound {
    static let shared = TickSound()
    private var tick: AVAudioPlayer?
    private var tock: AVAudioPlayer?
    private var flip = false

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pomodoro.tickSound") }
        set { UserDefaults.standard.set(newValue, forKey: "pomodoro.tickSound") }
    }

    private init() {
        tick = Self.player(frequency: 2600)
        tock = Self.player(frequency: 2100)
    }

    func play() {
        guard enabled else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        #endif
        flip.toggle()
        let p = flip ? tick : tock
        p?.currentTime = 0
        p?.play()
    }

    /// 30 ms decaying sine burst with a little noise, as a 16-bit mono WAV.
    private static func player(frequency: Double) -> AVAudioPlayer? {
        let rate = 44_100.0, count = Int(rate * 0.03)
        var samples = [Int16](repeating: 0, count: count)
        var seed: UInt32 = 12345
        for i in 0..<count {
            let t = Double(i) / rate
            let env = exp(-t * 180)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max) * 0.25
            let v = (sin(2 * .pi * frequency * t) + noise) * env * 0.35
            samples[i] = Int16(max(-1, min(1, v)) * Double(Int16.max))
        }
        var data = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        let bytes = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let p = try? AVAudioPlayer(data: data)
        p?.volume = 0.5
        p?.prepareToPlay()
        return p
    }
}
