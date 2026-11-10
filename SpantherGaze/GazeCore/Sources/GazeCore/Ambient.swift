import Foundation

// The calm music of the meteor game: a slow pad made here from soft tones, so the app ships no sound file for it.
// Four chords in D major fade into one another, and now and then a single quiet note sounds over them. There are no
// drums, no sharp attacks and nothing above about 2 kHz. The app only plays what `render` writes (Audio/AmbientPlayer).
//
// `render` runs on the audio thread: it takes no lock and makes no allocation, all its state sits in memory
// reserved by `init`. `setPlaying` may be called from any thread.

public final class AmbientPad: @unchecked Sendable {
    /// The pad's pitches (Hz): D3 G3 A3 B3 D4 E4 F#4 A4.
    static let pitches: [Double] = [146.83, 196.00, 220.00, 246.94, 293.66, 329.63, 369.99, 440.00]
    /// Four chords, a level per pitch: Dadd9, G6/9, D6 and Asus. Each lasts `chordSec` and fades into the next.
    static let chords: [[Float]] = [
        [1.00, 0.00, 0.75, 0.00, 0.60, 0.45, 0.50, 0.22],
        [0.35, 1.00, 0.00, 0.60, 0.60, 0.45, 0.00, 0.28],
        [0.80, 0.00, 0.00, 0.80, 0.55, 0.00, 0.50, 0.28],
        [0.00, 0.00, 1.00, 0.35, 0.60, 0.55, 0.00, 0.28],
    ]
    /// The single notes over the pad (Hz): D4 E4 F#4 A4 B4 D5, all from the same five-note scale.
    static let melody: [Double] = [293.66, 329.63, 369.99, 440.00, 493.88, 587.33]

    public static let chordSec = 14.0
    /// Seconds from silence to full level, and back.
    public static let fadeInSec = 2.5
    public static let fadeOutSec = 1.2
    /// The whole pad's level. With it no sample can pass 0.75 even if every tone peaked at once.
    static let master: Float = 0.13

    private static let tableSize = 2048
    private static let noteVoices = 3
    private static let controlEvery = 32

    public let sampleRate: Double
    /// The tones are made at `sampleRate / over` (about 11-12 kHz, plenty for sounds under 2 kHz) and drawn out to
    /// the full rate, which keeps the audio thread's work small.
    private let over: Int
    private let innerRate: Double

    private let pitchCount: Int
    private let chordCount: Int
    private let melodyCount: Int
    private let table: UnsafeMutablePointer<Float>
    /// `chordCount` rows of `pitchCount` levels, and the table step of each melody note.
    private let chordLevel: UnsafeMutablePointer<Float>
    private let melodyStep: UnsafeMutablePointer<Double>
    private let phase: UnsafeMutablePointer<Double>
    private let step: UnsafeMutablePointer<Double>
    private let level: UnsafeMutablePointer<Float>
    private let target: UnsafeMutablePointer<Float>
    private let lfoPhase: UnsafeMutablePointer<Double>
    private let lfoStep: UnsafeMutablePointer<Double>
    private let notePhase: UnsafeMutablePointer<Double>
    private let noteStep: UnsafeMutablePointer<Double>
    private let noteEnv: UnsafeMutablePointer<Float>
    private let notePeak: UnsafeMutablePointer<Float>
    private let notePan: UnsafeMutablePointer<Float>
    private let noteRising: UnsafeMutablePointer<Bool>
    /// 1 to play, 0 to fade out. Written by `setPlaying`, read by the audio thread.
    private let wanted: UnsafeMutablePointer<Float>
    /// The fade right now, 0...1, and what the audio thread has made so far (for the debug line and the tests).
    private let fade: UnsafeMutablePointer<Float>
    private let made: UnsafeMutablePointer<Int>
    private let loudest: UnsafeMutablePointer<Float>

    private var rng: UInt64
    private var chord = 0
    private var chordLeft: Int
    private var controlLeft = 0
    private var noteLeft: Int
    private var nextVoice = 0
    private var lastNote = -1
    private var sub = 0
    private var prevL: Float = 0, prevR: Float = 0, curL: Float = 0, curR: Float = 0
    private var lowL: Float = 0, lowR: Float = 0

    private let levelK: Float
    private let lowK: Float
    private let fadeUp: Float
    private let fadeDown: Float
    private let attackStep: Float
    private let decayMul: Float

    public init(sampleRate: Double, seed: UInt64 = 20_261_110) {
        let rate = sampleRate.isFinite && sampleRate >= 8000 ? sampleRate : 44_100
        self.sampleRate = rate
        over = max(1, Int(rate / 11_000))
        innerRate = rate / Double(over)
        let n = Self.pitches.count, size = Self.tableSize
        pitchCount = n
        chordCount = Self.chords.count
        melodyCount = Self.melody.count
        chordLevel = .allocate(capacity: Self.chords.count * n)
        for (c, row) in Self.chords.enumerated() {
            for p in 0..<n { chordLevel[c * n + p] = p < row.count ? row[p] : 0 }
        }
        melodyStep = .allocate(capacity: Self.melody.count)
        for (k, hz) in Self.melody.enumerated() { melodyStep[k] = Double(size) * hz / innerRate }

        // One cycle of the pad's tone: a sine with a few soft overtones, which is what makes it warm, not thin.
        table = .allocate(capacity: size + 1)
        var peak: Float = 0
        for i in 0...size {
            let x = 2 * Double.pi * Double(i) / Double(size)
            let v = Float(sin(x) + 0.28 * sin(2 * x) + 0.10 * sin(3 * x) + 0.03 * sin(4 * x))
            table[i] = v
            peak = max(peak, abs(v))
        }
        for i in 0...size { table[i] /= peak }

        phase = .allocate(capacity: 3 * n)
        step = .allocate(capacity: 3 * n)
        level = .allocate(capacity: n)
        target = .allocate(capacity: n)
        lfoPhase = .allocate(capacity: n)
        lfoStep = .allocate(capacity: n)
        notePhase = .allocate(capacity: Self.noteVoices)
        noteStep = .allocate(capacity: Self.noteVoices)
        noteEnv = .allocate(capacity: Self.noteVoices)
        notePeak = .allocate(capacity: Self.noteVoices)
        notePan = .allocate(capacity: Self.noteVoices)
        noteRising = .allocate(capacity: Self.noteVoices)
        wanted = .allocate(capacity: 1)
        fade = .allocate(capacity: 1)
        made = .allocate(capacity: 1)
        loudest = .allocate(capacity: 1)
        wanted.pointee = 0
        fade.pointee = 0
        made.pointee = 0
        loudest.pointee = 0

        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func roll(_ state: inout UInt64) -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(UInt64(1) << 53)
        }
        // Each pitch is three tones: one in the middle and two quieter ones a hair lower and higher (2 and 1.6
        // cents), one to the left and one to the right. They drift against each other, which gives the pad its
        // slow shimmer without ever cancelling the note.
        let lower = pow(2.0, -2.0 / 1200), higher = pow(2.0, 1.6 / 1200)
        for p in 0..<n {
            let perSample = Double(size) * Self.pitches[p] / innerRate
            step[3 * p] = perSample
            step[3 * p + 1] = perSample * lower
            step[3 * p + 2] = perSample * higher
            for k in 0..<3 { phase[3 * p + k] = roll(&state) * Double(size) }
            level[p] = 0
            target[p] = 0
            // Each pitch breathes at its own pace, 7 to 17 seconds, so the chord never stands still.
            lfoPhase[p] = roll(&state) * 2 * Double.pi
            lfoStep[p] = 2 * Double.pi / ((7 + 10 * roll(&state)) * innerRate)
        }
        for v in 0..<Self.noteVoices {
            notePhase[v] = 0
            noteStep[v] = 0
            noteEnv[v] = 0
            notePeak[v] = 0
            notePan[v] = 0.5
            noteRising[v] = false
        }
        rng = state
        chordLeft = Int(Self.chordSec * innerRate)
        noteLeft = Int(5 * innerRate)
        levelK = Float(1 - exp(-1 / (2.2 * innerRate)))
        lowK = Float(1 - exp(-2 * Double.pi * 2200 / rate))
        fadeUp = Float(1 / (Self.fadeInSec * rate))
        fadeDown = Float(1 / (Self.fadeOutSec * rate))
        attackStep = Float(1 / (0.5 * innerRate))
        decayMul = Float(exp(-1 / (2.4 * innerRate)))
    }

    deinit {
        table.deallocate()
        chordLevel.deallocate()
        melodyStep.deallocate()
        phase.deallocate()
        step.deallocate()
        level.deallocate()
        target.deallocate()
        lfoPhase.deallocate()
        lfoStep.deallocate()
        notePhase.deallocate()
        noteStep.deallocate()
        noteEnv.deallocate()
        notePeak.deallocate()
        notePan.deallocate()
        noteRising.deallocate()
        wanted.deallocate()
        fade.deallocate()
        made.deallocate()
        loudest.deallocate()
    }

    /// True: fade in and play. False: fade out; `isSilent` turns true when the fade has ended. Any thread.
    public func setPlaying(_ on: Bool) { wanted.pointee = on ? 1 : 0 }
    public var isWanted: Bool { wanted.pointee > 0.5 }
    /// Nothing is sounding and nothing was asked for: the player may stop pulling audio.
    public var isSilent: Bool { fade.pointee <= 0 && wanted.pointee < 0.5 }
    /// Samples made so far and the loudest of them (0...1), for the debug line.
    public var renderedFrames: Int { made.pointee }
    public var peak: Float { loudest.pointee }

    private func random() -> Double {
        rng &+= 0x9E37_79B9_7F4A_7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(UInt64(1) << 53)
    }

    @inline(__always)
    private func tone(_ ph: Double) -> Float {
        let i = Int(ph)
        let f = Float(ph - Double(i))
        return table[i] + (table[i + 1] - table[i]) * f
    }

    /// The slow things, a few hundred times a second: the chord, each pitch's breathing, the next single note.
    private func control() {
        let n = pitchCount, every = Self.controlEvery
        chordLeft -= every
        if chordLeft <= 0 {
            chord = (chord + 1) % chordCount
            chordLeft = Int(Self.chordSec * innerRate)
        }
        for p in 0..<n {
            var ph = lfoPhase[p] + lfoStep[p] * Double(every)
            if ph > 2 * Double.pi { ph -= 2 * Double.pi }
            lfoPhase[p] = ph
            target[p] = chordLevel[chord * n + p] * (1 + 0.15 * Float(sin(ph)))
        }
        noteLeft -= every
        if noteLeft <= 0 {
            var k = min(melodyCount - 1, Int(random() * Double(melodyCount)))
            if k == lastNote { k = (k + 1) % melodyCount }
            lastNote = k
            let v = nextVoice
            nextVoice = (nextVoice + 1) % Self.noteVoices
            noteStep[v] = melodyStep[k]
            notePeak[v] = Float(0.32 + 0.16 * random())
            notePan[v] = Float(0.3 + 0.4 * random())
            noteRising[v] = true
            noteLeft = Int((5 + 5 * random()) * innerRate)
        }
    }

    /// One sample at the inner rate, into `curL` and `curR`.
    private func tick() {
        if controlLeft <= 0 { control(); controlLeft = Self.controlEvery }
        controlLeft -= 1
        let n = pitchCount, size = Double(Self.tableSize)
        var l: Float = 0, r: Float = 0
        for p in 0..<n {
            let lv = level[p] + (target[p] - level[p]) * levelK
            level[p] = lv
            var c = phase[3 * p] + step[3 * p]
            if c >= size { c -= size }
            phase[3 * p] = c
            var a = phase[3 * p + 1] + step[3 * p + 1]
            if a >= size { a -= size }
            phase[3 * p + 1] = a
            var b = phase[3 * p + 2] + step[3 * p + 2]
            if b >= size { b -= size }
            phase[3 * p + 2] = b
            guard lv > 0.0005 else { continue }
            // Each channel's three shares add up to 1, so a pitch never sounds louder than its level.
            let tc = tone(c) * lv * 0.56, ta = tone(a) * lv, tb = tone(b) * lv
            l += tc + ta * 0.32 + tb * 0.12
            r += tc + ta * 0.12 + tb * 0.32
        }
        for v in 0..<Self.noteVoices {
            var e = noteEnv[v]
            if noteRising[v] {
                e += attackStep * notePeak[v]
                if e >= notePeak[v] { e = notePeak[v]; noteRising[v] = false }
            } else if e > 0 {
                e *= decayMul
                if e < 0.00002 { e = 0 }
            }
            noteEnv[v] = e
            guard e > 0 else { continue }
            var ph = notePhase[v] + noteStep[v]
            if ph >= size { ph -= size }
            notePhase[v] = ph
            let t = tone(ph) * e
            l += t * (1 - notePan[v])
            r += t * notePan[v]
        }
        curL = l * Self.master
        curR = r * Self.master
    }

    /// Fills `frames` samples of each channel (`right` nil: one channel, the two mixed). Audio thread.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        guard frames > 0 else { return }
        var g = fade.pointee
        let want = wanted.pointee
        var top = loudest.pointee
        if g <= 0, want < 0.5 {
            // Silent and not asked for: the music waits where it stopped.
            for i in 0..<frames { left[i] = 0 }
            if let right { for i in 0..<frames { right[i] = 0 } }
            lowL = 0; lowR = 0
            made.pointee += frames
            return
        }
        let inv = 1 / Float(over)
        for i in 0..<frames {
            if sub == 0 {
                prevL = curL; prevR = curR
                tick()
            }
            let f = Float(sub) * inv
            sub += 1
            if sub >= over { sub = 0 }
            if want > 0.5 { g = min(1, g + fadeUp) } else { g = max(0, g - fadeDown) }
            // A smooth step, so the fade neither starts nor ends with a corner.
            let shaped = g * g * (3 - 2 * g)
            lowL += (prevL + (curL - prevL) * f - lowL) * lowK
            lowR += (prevR + (curR - prevR) * f - lowR) * lowK
            let l = lowL * shaped, r = lowR * shaped
            if let right {
                left[i] = l
                right[i] = r
                top = max(top, max(abs(l), abs(r)))
            } else {
                let m = (l + r) * 0.5
                left[i] = m
                top = max(top, abs(m))
            }
        }
        fade.pointee = g
        loudest.pointee = top
        made.pointee += frames
    }
}
