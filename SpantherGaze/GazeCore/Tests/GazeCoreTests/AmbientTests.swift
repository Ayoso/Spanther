@testable import GazeCore
import XCTest

/// The calm pad: it must fade in and out without a click, stay quiet and bounded, and hold no sharp highs.
final class AmbientTests: XCTestCase {
    /// Renders `seconds` in buffers of 512 frames, as the audio thread would ask for them.
    private func render(_ pad: AmbientPad, seconds: Double, mono: Bool = false) -> (left: [Float], right: [Float]) {
        let total = Int(seconds * pad.sampleRate)
        var left = [Float](repeating: 9, count: total), right = [Float](repeating: 9, count: total)
        var done = 0
        while done < total {
            let n = min(512, total - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    pad.render(left: l.baseAddress! + done, right: mono ? nil : r.baseAddress! + done, frames: n)
                }
            }
            done += n
        }
        return (left, mono ? left : right)
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }

    private func biggestStep(_ x: [Float]) -> Float {
        var worst: Float = 0
        for i in 1..<x.count { worst = max(worst, abs(x[i] - x[i - 1])) }
        return worst
    }

    func testSilentUntilAskedToPlay() {
        let pad = AmbientPad(sampleRate: 48_000)
        XCTAssertTrue(pad.isSilent)
        let out = render(pad, seconds: 0.5)
        XCTAssertTrue(out.left.allSatisfy { $0 == 0 } && out.right.allSatisfy { $0 == 0 })
        XCTAssertEqual(pad.renderedFrames, 24_000)
        XCTAssertEqual(pad.peak, 0)
    }

    func testFadesInSmoothlyAndStaysQuietThroughAllFourChords() {
        let pad = AmbientPad(sampleRate: 48_000)
        pad.setPlaying(true)
        XCTAssertFalse(pad.isSilent)
        let started = Date()
        let out = render(pad, seconds: 60)   // more than the four chords of 14 s
        let took = Date().timeIntervalSince(started)
        print("ambient: 60 s of audio rendered in \(String(format: "%.2f", took)) s (\(String(format: "%.1f", took / 60 * 100))% of real time, unoptimised build)")
        for ch in [out.left, out.right] {
            XCTAssertEqual(ch[0], 0, accuracy: 1e-6, "starts from silence")
            XCTAssertLessThan(ch[..<480].map { abs($0) }.max() ?? 1, 0.001, "the first 10 ms are next to nothing")
            XCTAssertLessThan(ch.map { abs($0) }.max() ?? 1, 0.6, "never near full scale")
            XCTAssertLessThan(biggestStep(ch), 0.03, "no click anywhere, chord changes included")
            // Loud enough to hear, quiet enough to stay in the background.
            for second in stride(from: 6, to: 60, by: 6) {
                let level = rms(ch[(second * 48_000)..<((second + 1) * 48_000)])
                XCTAssertGreaterThan(level, 0.02, "second \(second)")
                XCTAssertLessThan(level, 0.2, "second \(second)")
            }
        }
        XCTAssertLessThan(rms(out.left[0..<24_000]), rms(out.left[96_000..<120_000]) * 0.5, "the first half second is a fade")
        XCTAssertEqual(pad.peak, max(out.left.map { abs($0) }.max() ?? 0, out.right.map { abs($0) }.max() ?? 0))
        XCTAssertNotEqual(out.left[100_000], out.right[100_000], "two channels, a little apart")
    }

    func testFadesOutToExactSilenceAndComesBack() {
        let pad = AmbientPad(sampleRate: 44_100)
        pad.setPlaying(true)
        _ = render(pad, seconds: 6)
        pad.setPlaying(false)
        XCTAssertFalse(pad.isSilent, "still fading")
        let tail = render(pad, seconds: 2)
        XCTAssertLessThan(biggestStep(tail.left), 0.03, "the fade out has no click")
        let afterFade = Int((AmbientPad.fadeOutSec + 0.05) * 44_100)
        XCTAssertTrue(tail.left[afterFade...].allSatisfy { $0 == 0 }, "silent \(AmbientPad.fadeOutSec) s after the pause")
        XCTAssertTrue(tail.right[afterFade...].allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(rms(tail.left[0..<4410]), 0.01, "but not cut off at once")
        XCTAssertTrue(pad.isSilent)
        // Back from the pause: it rises from silence again, without a jump.
        pad.setPlaying(true)
        let back = render(pad, seconds: 4)
        XCTAssertEqual(back.left[0], 0, accuracy: 1e-5)
        XCTAssertLessThan(biggestStep(back.left), 0.03)
        XCTAssertGreaterThan(rms(back.left[(3 * 44_100)...]), 0.02)
    }

    /// Energy above 4 kHz, through a second-order high-pass there, against all of it.
    func testNoFatiguingHighs() {
        let pad = AmbientPad(sampleRate: 48_000)
        pad.setPlaying(true)
        let x = render(pad, seconds: 30).left
        let w0 = 2 * Double.pi * 4000 / 48_000, q = 0.7071
        let alpha = sin(w0) / (2 * q), c = cos(w0)
        let b0 = (1 + c) / 2 / (1 + alpha), b1 = -(1 + c) / (1 + alpha), b2 = b0
        let a1 = -2 * c / (1 + alpha), a2 = (1 - alpha) / (1 + alpha)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, high = 0.0, all = 0.0
        for s in x[48_000...] {
            let v = Double(s)
            let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = y
            high += y * y
            all += v * v
        }
        XCTAssertGreaterThan(all, 0)
        XCTAssertLessThan(high / all, 0.0005, "less than a 2000th of the energy sits above 4 kHz")
    }

    func testTheSameSeedGivesTheSameMusic() {
        let a = AmbientPad(sampleRate: 44_100, seed: 5), b = AmbientPad(sampleRate: 44_100, seed: 5)
        let c = AmbientPad(sampleRate: 44_100, seed: 6)
        for p in [a, b, c] { p.setPlaying(true) }
        let ra = render(a, seconds: 4).left, rb = render(b, seconds: 4).left, rc = render(c, seconds: 4).left
        XCTAssertEqual(ra, rb)
        XCTAssertNotEqual(ra, rc)
    }

    func testEveryOutputRateAndOneChannel() {
        for rate in [8000.0, 16_000, 22_050, 24_000, 44_100, 48_000, 96_000] {
            let pad = AmbientPad(sampleRate: rate)
            XCTAssertEqual(pad.sampleRate, rate)
            pad.setPlaying(true)
            let out = render(pad, seconds: 8, mono: rate == 16_000)
            let n = Int(rate)
            XCTAssertLessThan(out.left.map { abs($0) }.max() ?? 1, 0.6, "\(rate)")
            XCTAssertGreaterThan(rms(out.left[(6 * n)..<(8 * n)]), 0.02, "\(rate)")
            XCTAssertLessThan(biggestStep(out.left), rate < 20_000 ? 0.12 : 0.05, "\(rate)")
        }
        XCTAssertEqual(AmbientPad(sampleRate: 0).sampleRate, 44_100, "a broken rate falls back")
        XCTAssertEqual(AmbientPad(sampleRate: .nan).sampleRate, 44_100)
    }

    func testTheLevelCannotClipEvenInTheWorstCase() {
        // If every tone of the loudest chord and three single notes peaked together.
        let loudest = AmbientPad.chords.map { $0.reduce(0, +) }.max() ?? 0
        let worst = (loudest * 1.15 + 3 * 0.48) * AmbientPad.master
        XCTAssertLessThan(worst, 0.75)
        for row in AmbientPad.chords { XCTAssertEqual(row.count, AmbientPad.pitches.count) }
        XCTAssertLessThan(AmbientPad.melody.max() ?? 9999, 600, "no single note above D5")
    }

    /// `AMBIENT_WAV=/path/pad.wav swift test --filter AmbientTests/testWritesAPreview` saves 50 s of the pad to listen to.
    func testWritesAPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_WAV"], !path.isEmpty else { return }
        let rate = 44_100
        let pad = AmbientPad(sampleRate: Double(rate))
        pad.setPlaying(true)
        var out = render(pad, seconds: 48)
        pad.setPlaying(false)
        let tail = render(pad, seconds: 2)
        out.left += tail.left
        out.right += tail.right
        var pcm = Data(capacity: out.left.count * 4)
        for i in out.left.indices {
            for v in [out.left[i], out.right[i]] {
                var s = Int16(max(-1, min(1, v)) * Float(Int16.max)).littleEndian
                withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
            }
        }
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        try wav.write(to: URL(fileURLWithPath: path))
    }
}
