import XCTest
@testable import GazeCore

final class AdaptTests: XCTestCase {
    private let level = HeadPose(pitch: 0.03, yaw: -0.2)

    func testNoLabelsNoCorrection() {
        let a = GazeAdapter(reference: level)
        XCTAssertEqual(a.correction(pose: HeadPose(pitch: 0.3, yaw: 0.1)), .zero)
    }

    func testSolve3() {
        let x = GazeAdapter.solve3([2, 1, 0, 1, 3, 1, 0, 1, 4], [3, 5, 5])
        XCTAssertEqual(x?[0] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(x?[1] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(x?[2] ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(GazeAdapter.solve3([1, 2, 3, 2, 4, 6, 0, 0, 1], [1, 2, 3]))
    }

    func testSteadyBiasIsLearned() {
        var a = GazeAdapter(reference: level)
        // The model reads 30 pt left of and 20 pt below where the player looks, at the calibration grip.
        for i in 0..<20 {
            let target = Vec2(100 + Double(i) * 30, 200)
            XCTAssertTrue(a.learn(raw: target + Vec2(-30, 20), target: target, pose: level, time: Double(i)))
        }
        let c = a.correction(pose: level)
        XCTAssertEqual(c.x, 30, accuracy: 3)
        XCTAssertEqual(c.y, -20, accuracy: 2)
    }

    func testOneLabelMovesTheAimOnlyPartWay() {
        var a = GazeAdapter(reference: level)
        a.learn(raw: Vec2(300, 300), target: Vec2(360, 300), pose: level, time: 0)
        // Prior 60 pt and label noise 45 pt: one label of 60 pt moves the aim 60 * 60² / (60² + 45²) = 38 pt.
        XCTAssertEqual(a.correction(pose: level).x, 38.4, accuracy: 0.5)
    }

    func testTiltIsLearnedAndCorrectedBeforeTheNextLabel() {
        var a = GazeAdapter(reference: level)
        // The aim slides 6 pt per degree of pitch away from the calibration grip (1.2 cm at 10 degrees).
        let slope = 6.0 * 180 / Double.pi
        var t = 0.0
        for k in 0..<60 {
            let pitch = level.pitch + Double(k % 7 - 3) * 0.035
            let pose = HeadPose(pitch: pitch, yaw: level.yaw)
            let target = Vec2(400, 150 + Double(k % 5) * 40)
            let raw = target + Vec2(0, slope * (pitch - level.pitch))
            a.learn(raw: raw, target: target, pose: pose, time: t)
            t += 0.7
        }
        // A tilt it has not seen yet (12 degrees): the aim would be 72 pt off; the correction takes most of it.
        let tilted = HeadPose(pitch: level.pitch + 12 * Double.pi / 180, yaw: level.yaw)
        XCTAssertEqual(a.correction(pose: tilted).y, -72, accuracy: 8)
        XCTAssertEqual(a.correction(pose: tilted).x, 0, accuracy: 3)
        XCTAssertEqual(a.correction(pose: level).y, 0, accuracy: 3)
    }

    func testAGlanceElsewhereIsNotLearned() {
        var a = GazeAdapter(reference: level)
        XCTAssertFalse(a.learn(raw: Vec2(100, 100), target: Vec2(500, 300), pose: level, time: 0))
        XCTAssertEqual(a.rejected, 1)
        XCTAssertEqual(a.learned, 0)
        XCTAssertEqual(a.correction(pose: level), .zero)
    }

    func testOldEvidenceFades() {
        var a = GazeAdapter(reference: level)
        for i in 0..<20 { a.learn(raw: Vec2(240, 200), target: Vec2(200, 200), pose: level, time: Double(i)) }
        XCTAssertEqual(a.correction(pose: level).x, -40, accuracy: 4)
        // The grip changes: now the model is right. Two half-lives later most of the old bias is gone.
        for i in 0..<45 { a.learn(raw: Vec2(200, 200), target: Vec2(200, 200), pose: level, time: 20 + Double(i) * 0.7) }
        XCTAssertLessThan(abs(a.correction(pose: level).x), 8)
    }

    func testCorrectionIsCapped() {
        var cfg = GazeAdapterConfig()
        cfg.gatePt = 1000
        cfg.priorBiasPt = 1000
        cfg.maxCorrectionPt = 100
        var a = GazeAdapter(reference: level, config: cfg)
        for i in 0..<30 { a.learn(raw: Vec2(0, 0), target: Vec2(300, 400), pose: level, time: Double(i)) }
        XCTAssertEqual(a.correction(pose: level).length, 100, accuracy: 1e-6)
    }

    /// A player whose aim slides as the phone tilts back and forth over two minutes, with label noise like a real
    /// check (40 pt per axis). Online: each frame is scored with what was learned before it. The score is the
    /// systematic offset left after the correction; the noise stays either way.
    func testDriftingGripOnline() {
        var a = GazeAdapter(reference: level)
        var rng = SplitMix(seed: 7)
        var before = 0.0, after = 0.0, n = 0.0
        for k in 0..<160 {
            let t = Double(k) * 0.75
            let pitch = level.pitch + 0.17 * sin(t / 20)           // up to ±10 degrees, slowly
            let pose = HeadPose(pitch: pitch, yaw: level.yaw + 0.05 * sin(t / 33))
            let target = Vec2(150 + rng.next() * 500, 80 + rng.next() * 230)
            let drift = Vec2(25 + 200 * (pose.yaw - level.yaw), 350 * (pitch - level.pitch))
            let noise = Vec2(rng.gauss() * 40, rng.gauss() * 40)
            if k >= 20 {
                before += drift.length
                after += (drift + a.correction(pose: pose)).length
                n += 1
            }
            a.learn(raw: target + drift + noise, target: target, pose: pose, time: t)
        }
        before /= n
        after /= n
        XCTAssertLessThan(after, before * 0.5, "offset \(before) pt without, \(after) pt with the adapter")
        XCTAssertLessThan(after, 20)
    }
}

/// Small seeded generator for repeatable tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in 0..<1.
    mutating func next() -> Double { Double(nextUInt() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u = max(next(), 1e-12), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}
