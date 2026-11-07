import AVFoundation
import QuartzCore

/// Short metronome clicks for the wink test, started on the audio device clock so each one is heard on its beat.
/// The click is synthesised here (a 35 ms tone with a fast decay), so the app ships no sound files.
final class ClickPlayer {
    private var normal: [AVAudioPlayer] = []
    private var accent: [AVAudioPlayer] = []
    private var next = 0
    /// Seconds the audio route adds before a sound is heard: about 0.01 on the speaker, 0.15-0.25 on Bluetooth.
    /// Clicks start this much earlier, and the session CSV records it (`audio_latency_s`).
    private(set) var outputLatency = 0.0

    init() {
        let session = AVAudioSession.sharedInstance()
        // Playback, so the clicks sound with the ring/silent switch off; mixing, so other audio is not stopped.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        outputLatency = session.outputLatency
        normal = Self.pool(Self.click(frequency: 1200))
        accent = Self.pool(Self.click(frequency: 2000))
    }

    /// Plays a click heard at `hostTime` (the CACurrentMediaTime clock, which ARKit frame timestamps share).
    /// `pan`: -1 left ... 1 right. The count-in uses the higher `accent` click.
    func play(at hostTime: Double, pan: Float = 0, accent useAccent: Bool = false) {
        let list = useAccent ? accent : normal
        guard !list.isEmpty else { return }
        let p = list[next % list.count]
        next += 1
        p.currentTime = 0
        p.pan = pan
        let delay = hostTime - CACurrentMediaTime() - outputLatency
        if delay > 0.005 {
            p.play(atTime: p.deviceCurrentTime + delay)
        } else {
            p.play()
        }
    }

    func stop() { (normal + accent).forEach { $0.stop() } }

    private static func pool(_ data: Data) -> [AVAudioPlayer] {
        (0..<3).compactMap { _ in
            let p = try? AVAudioPlayer(data: data)
            p?.prepareToPlay()
            return p
        }
    }

    /// A mono 16-bit WAV: a sine at `frequency` with a 1 ms attack and an exponential decay.
    static func click(frequency: Double, duration: Double = 0.035, sampleRate: Int = 44_100) -> Data {
        let n = Int(Double(sampleRate) * duration)
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            let envelope = exp(-t * 90) * min(1, t / 0.001)
            let v = sin(2 * Double.pi * frequency * t) * envelope * 0.8
            var sample = Int16(max(-1, min(1, v)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
