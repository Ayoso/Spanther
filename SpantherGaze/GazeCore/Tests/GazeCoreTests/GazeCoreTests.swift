import XCTest
@testable import GazeCore

final class TransformsTests: XCTestCase {
    func testRigidInverseUndoesTransform() {
        let m = Mat4.translation(Vec3(0.1, -0.2, 0.3)) * Mat4.rotationY(0.4) * Mat4.rotationX(-0.3)
        let p = Vec3(0.05, 0.02, -0.4)
        let back = m.rigidInverse.point(m.point(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-12)
        XCTAssertEqual(back.z, p.z, accuracy: 1e-12)
    }

    func testRayHitsScreenPlane() {
        // Eye 30 cm in front of the camera (camera space: +z towards the face), looking 2 cm right, 1 cm up.
        let hit = Transforms.intersectScreenPlane(origin: Vec3(0, 0, 0.3), direction: Vec3(0.02, 0.01, -0.3))
        XCTAssertEqual(hit?.x ?? .nan, 0.02, accuracy: 1e-12)
        XCTAssertEqual(hit?.y ?? .nan, 0.01, accuracy: 1e-12)
        XCTAssertNil(Transforms.intersectScreenPlane(origin: Vec3(0, 0, 0.3), direction: Vec3(0, 0, 1)), "looking away")
    }

    /// Synthetic face 30 cm in front of the camera whose eyes look straight at a point on the screen.
    func syntheticFrame(lookAtScreen p: Vec2, yaw: Double = 0) -> FaceFrame {
        let face = Mat4.translation(Vec3(0, 0, 0.3)) * Mat4.rotationY(yaw)
        // Point on the screen plane, expressed in face space.
        let target = face.rigidInverse.point(Vec3(p.x, p.y, 0))
        func eye(_ x: Double) -> Mat4 {
            let o = Vec3(x, 0.03, 0.02)
            let z = (target - o).normalized
            let up = Vec3(0, 1, 0)
            let xAxis = Vec3(up.y * z.z - up.z * z.y, up.z * z.x - up.x * z.z, up.x * z.y - up.y * z.x).normalized
            let yAxis = Vec3(z.y * xAxis.z - z.z * xAxis.y, z.z * xAxis.x - z.x * xAxis.z, z.x * xAxis.y - z.y * xAxis.x)
            return Mat4(columns: [xAxis.x, xAxis.y, xAxis.z, 0], [yAxis.x, yAxis.y, yAxis.z, 0], [z.x, z.y, z.z, 0], [o.x, o.y, o.z, 1])
        }
        return FaceFrame(timestamp: 0, faceTransform: face, leftEyeTransform: eye(0.032), rightEyeTransform: eye(-0.032),
                         lookAtPoint: target, cameraTransform: .identity)
    }

    func testFeaturesRecoverScreenPointInPortraitAxes() throws {
        for yaw in [0.0, 0.2, -0.25] {
            let g = try XCTUnwrap(GazeFeatures.make(syntheticFrame(lookAtScreen: Vec2(0.03, -0.05), yaw: yaw)))
            let expected = Transforms.cameraPlaneToPortrait(Vec2(0.03, -0.05))
            XCTAssertEqual(g.lookAtHit.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(g.lookAtHit.y, expected.y, accuracy: 1e-9)
            XCTAssertEqual(g.eyeAxisHit.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(g.eyeAxisHit.y, expected.y, accuracy: 1e-9)
            XCTAssertEqual(g.yaw, yaw, accuracy: 1e-9)
            XCTAssertEqual(g.distance, 0.3, accuracy: 1e-9)
        }
    }

    /// Turning the head while the eyes stay on the same screen point must not change the model's input:
    /// head pose is not a feature, the hits already account for it.
    func testHeadTurnDoesNotChangeFeaturesForTheSamePoint() throws {
        let straight = try XCTUnwrap(GazeFeatures.make(syntheticFrame(lookAtScreen: Vec2(0.01, -0.06), yaw: 0)))
        let turned = try XCTUnwrap(GazeFeatures.make(syntheticFrame(lookAtScreen: Vec2(0.01, -0.06), yaw: 0.25)))
        for set in GazeFeatures.FeatureSet.allCases {
            let a = straight.vector(set), b = turned.vector(set)
            XCTAssertEqual(a.count, b.count)
            for (x, y) in zip(a, b) where !(x.isNaN && y.isNaN) { XCTAssertEqual(x, y, accuracy: 1e-9, "\(set)") }
        }
        XCTAssertEqual(straight.vector(.lookAt).count, 5)
        XCTAssertEqual(straight.vector(.eyes).count, 7)
        XCTAssertEqual(straight.vector(.eyesAndPupils).count, 9)
        XCTAssertTrue(straight.vector(.eyesAndPupils)[7].isNaN, "no pupil result is NaN, not 0")
    }
}

final class CalibrationTests: XCTestCase {
    func testRidgeRecoversLinearMapping() throws {
        var rng = SeededRandom(seed: 1)
        var X: [[Double]] = [], Y: [Vec2] = []
        for t in CalibrationLayout.calibration {
            for _ in 0..<30 {
                let target = CalibrationLayout.point(t, in: Vec2(390, 844))
                // features: metres on the screen plane + small noise, plus an irrelevant head feature
                let fx = (target.x - 195) / 6000 + Double.random(in: -0.0002...0.0002, using: &rng)
                let fy = (target.y - 422) / 6000 + Double.random(in: -0.0002...0.0002, using: &rng)
                X.append([fx, fy, Double.random(in: -0.05...0.05, using: &rng)])
                Y.append(target)
            }
        }
        let model = try XCTUnwrap(RidgeModel.fit(features: X, targets: Y, lambda: 0.001))
        // unseen check points
        var err = 0.0
        for t in CalibrationLayout.validation {
            let target = CalibrationLayout.point(t, in: Vec2(390, 844))
            err += model.predict([(target.x - 195) / 6000, (target.y - 422) / 6000, 0]).distance(to: target)
        }
        XCTAssertLessThan(err / Double(CalibrationLayout.validation.count), 5, "mean error in pt")
    }

    /// Synthetic calibration: features in metres on the screen plane (like the lookAt hit) plus quadratic terms
    /// and a pupil pair that is missing on every other frame.
    func syntheticCalibration(seed: UInt64) -> (X: [[Double]], Y: [Vec2]) {
        var rng = SeededRandom(seed: seed)
        var X: [[Double]] = [], Y: [Vec2] = []
        for t in CalibrationLayout.calibration {
            let target = CalibrationLayout.point(t, in: Vec2(390, 844))
            for i in 0..<30 {
                let fx = (target.x - 195) / 6000 + Double.random(in: -0.0002...0.0002, using: &rng)
                let fy = (target.y - 422) / 6000 + Double.random(in: -0.0002...0.0002, using: &rng)
                let pupil = i % 2 == 0 ? [fx * 0.5, fy * 0.5] : [Double.nan, .nan]
                X.append([fx, fy, fx * fx, fy * fy, fx * fy] + pupil)
                Y.append(target)
            }
        }
        return (X, Y)
    }

    func testMissingPupilsCountAsAverage() throws {
        let (X, Y) = syntheticCalibration(seed: 3)
        let model = try XCTUnwrap(RidgeModel.fit(features: X, targets: Y, lambda: 0.001))
        XCTAssertFalse(model.wx.contains { $0.isNaN } || model.wy.contains { $0.isNaN })
        let x: [Double] = [0.01, -0.02, 0.0001, 0.0004, -0.0002]
        let withNaN = model.predict(x + [.nan, .nan])
        let withMean = model.predict(x + [model.mean[5], model.mean[6]])
        XCTAssertEqual(withNaN.x, withMean.x, accuracy: 1e-9)
        XCTAssertEqual(withNaN.y, withMean.y, accuracy: 1e-9)
        // Half the pupils missing still fits: check points without pupils land within 5 pt.
        var err = 0.0
        for t in CalibrationLayout.validation {
            let target = CalibrationLayout.point(t, in: Vec2(390, 844))
            let fx = (target.x - 195) / 6000, fy = (target.y - 422) / 6000
            err += model.predict([fx, fy, fx * fx, fy * fy, fx * fy, .nan, .nan]).distance(to: target)
        }
        XCTAssertLessThan(err / Double(CalibrationLayout.validation.count), 5, "mean error in pt")
    }

    /// The first iPhone session: a glance 10 cm to the side sent the aim 5000 pt off the screen through the
    /// quadratic terms. Features are now clamped near the calibrated range, and the glance counts as looking away.
    func testFarOffScreenGlanceIsClampedAndFlagged() throws {
        let (X, Y) = syntheticCalibration(seed: 4)
        let model = try XCTUnwrap(RidgeModel.fit(features: X, targets: Y, lambda: 0.001))
        let fx = -0.1, fy = 0.0   // 10 cm left of the camera, far past the screen edge (about 3 cm)
        let x = [fx, fy, fx * fx, fy * fy, fx * fy, Double.nan, .nan]
        let p = model.predict(x)
        XCTAssertGreaterThan(p.x, -0.5 * 390, "clamped near the screen, not thousands of points away")
        XCTAssertLessThan(p.x, 1.5 * 390)
        XCTAssertGreaterThan(p.y, -0.5 * 844)
        XCTAssertLessThan(p.y, 1.5 * 844)
        XCTAssertTrue(model.outOfRange(x, features: 0..<2, margin: RidgeModel.lookingAwayMargin))
        // A point inside the screen, and one just past its edge, are not looking away.
        XCTAssertFalse(model.outOfRange([0.02, 0.05, 0, 0, 0, .nan, .nan], features: 0..<2, margin: RidgeModel.lookingAwayMargin))
        XCTAssertFalse(model.outOfRange([0.04, -0.07, 0, 0, 0, .nan, .nan], features: 0..<2, margin: RidgeModel.lookingAwayMargin))
    }

    func testCheckPointsAreNotCalibrationPoints() {
        XCTAssertEqual(CalibrationLayout.calibration.count, 9)
        XCTAssertEqual(CalibrationLayout.validation.count, 13)
        for v in CalibrationLayout.validation {
            XCTAssertFalse(CalibrationLayout.calibration.contains { $0.distance(to: v) < 1e-9 })
        }
    }

    func testOneEuroSmoothsJitterAndFollowsMoves() {
        var f = OneEuroFilter2D()
        var rng = SeededRandom(seed: 2)
        var spread = 0.0
        for i in 0..<120 {
            let noisy = Vec2(200 + Double.random(in: -15...15, using: &rng), 300 + Double.random(in: -15...15, using: &rng))
            let out = f.filter(noisy, t: Double(i) / 60)
            if i > 30 { spread += out.distance(to: Vec2(200, 300)) }
        }
        XCTAssertLessThan(spread / 89, 6, "raw noise is ~8.7 pt RMS per axis")
        // a jump settles within a quarter second
        var last = Vec2.zero
        for i in 120..<135 { last = f.filter(Vec2(100, 600), t: Double(i) / 60) }
        XCTAssertLessThan(last.distance(to: Vec2(100, 600)), 20)
    }

    func testMetrics() {
        let r = Metrics.report(samples: [(Vec2(0, 0), [Vec2(60, 0), Vec2(60, 0)]), (Vec2(100, 100), [Vec2(100, 160), Vec2(100, 160)])],
                               ptPerCm: 60, viewingDistanceCm: 30)
        XCTAssertEqual(r.meanErrorPt, 60, accuracy: 1e-9)
        XCTAssertEqual(r.meanErrorCm, 1, accuracy: 1e-9)
        XCTAssertEqual(r.jitterPt, 0, accuracy: 1e-9)
        XCTAssertEqual(r.meanErrorDeg, atan(1.0 / 30) * 180 / .pi, accuracy: 1e-9)
    }
}

final class BalanceTests: XCTestCase {
    static func config() throws -> BalanceConfig {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SpantherGaze/Resources/balance.json")
        return try BalanceConfig.load(from: Data(contentsOf: url))
    }

    func testDifficultyCurveMatchesBalanceTable() throws {
        let c = try Self.config()
        let table: [Double] = [0, 0.03, 0.13, 0.26, 0.42, 0.58, 0.74, 0.87, 0.97, 1.0]
        for (i, expected) in table.enumerated() {
            XCTAssertEqual(c.difficulty(level: i + 1), expected, accuracy: 0.006, "level \(i + 1)")
        }
        XCTAssertEqual(BalanceConfig.lerp(c.spawnIntervalSec, c.difficulty(level: 5)), 2.6, accuracy: 0.05)
        XCTAssertEqual(c.maxAsteroids(d: 0, marginPt: 40), 2)
        XCTAssertEqual(c.maxAsteroids(d: 1, marginPt: 40), 3)
        XCTAssertEqual(c.maxAsteroids(d: 1, marginPt: 80), 2, "error above 60 pt caps at 2")
        XCTAssertEqual(c.hitMargin(measuredErrorPt: 10), 30)
        XCTAssertEqual(c.hitMargin(measuredErrorPt: 200), 115)
        XCTAssertEqual(c.classes["S"]?.dwellSec, 0.5)
        XCTAssertEqual(c.classes["XL"]?.dwellSec, 2.0)
    }
}

final class GameModelTests: XCTestCase {
    let screen = Vec2(390, 844)

    func parked(_ m: GameModel, _ cls: String, at p: Vec2) -> Asteroid {
        var a = m.spawn(className: cls)
        a.position = p
        a.velocity = .zero
        m.insert(a)
        return a
    }

    /// Steps at 60 Hz with the gaze fixed on `p` until the asteroid bursts. Returns the elapsed time.
    func timeToDestroy(_ cls: String) throws -> Double {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 3)
        let a = parked(m, cls, at: Vec2(195, 300))
        var t = 0.0
        while t < 5 {
            let ev = m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300)))
            t += 1.0 / 60
            if ev.contains(where: { if case .destroyed(let x, _) = $0 { return x.id == a.id }; return false }) { return t }
        }
        return .infinity
    }

    func testDwellTimePerClass() throws {
        XCTAssertEqual(try timeToDestroy("S"), 0.5, accuracy: 1.0 / 60 + 1e-9)
        XCTAssertEqual(try timeToDestroy("M"), 0.8, accuracy: 1.0 / 60 + 1e-9)
        XCTAssertEqual(try timeToDestroy("L"), 1.2, accuracy: 1.0 / 60 + 1e-9)
        XCTAssertEqual(try timeToDestroy("XL"), 2.0, accuracy: 1.0 / 60 + 1e-9)
    }

    func testHitZoneIsRadiusPlusMargin() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 40, seed: 4)
        let a = parked(m, "S", at: Vec2(195, 300))   // radius 32, zone 72
        m.update(dt: 0.1, gaze: .point(Vec2(195 + 70, 300)))
        XCTAssertGreaterThan(m.asteroids.first { $0.id == a.id }!.progress, 0)
        m.removeAll()
        let b = parked(m, "S", at: Vec2(195, 300))
        m.update(dt: 0.1, gaze: .point(Vec2(195 + 74, 300)))
        XCTAssertEqual(m.asteroids.first { $0.id == b.id }!.progress, 0)
    }

    func testBlinkFreezesAndLookingAwayDrainsOverOneSecond() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 5)
        let a = parked(m, "XL", at: Vec2(195, 300))
        for _ in 0..<60 { m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) }   // 1 s of 2 s
        let held = m.asteroids.first { $0.id == a.id }!.progress
        XCTAssertEqual(held, 0.5, accuracy: 0.01)
        for _ in 0..<6 { m.update(dt: 1.0 / 60, gaze: .lost) }                        // 100 ms blink
        XCTAssertEqual(m.asteroids.first { $0.id == a.id }!.progress, held, accuracy: 1e-9, "blink under 150 ms is ignored")
        for _ in 0..<33 { m.update(dt: 1.0 / 60, gaze: .point(Vec2(20, 800))) }       // 0.55 s away
        XCTAssertEqual(m.asteroids.first { $0.id == a.id }!.progress, 0.0, accuracy: 0.02, "drains 1.0 per second")
        XCTAssertEqual(m.asteroids.first { $0.id == a.id }!.slips, 1)
    }

    func testClosestRelativeToZoneWins() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 6)
        let small = parked(m, "S", at: Vec2(100, 300))   // zone 62
        let big = parked(m, "XL", at: Vec2(250, 300))    // zone 140
        // 50 pt from S (ratio 0.81), 100 pt from XL (ratio 0.71): XL wins
        m.update(dt: 0.1, gaze: .point(Vec2(150, 300)))
        XCTAssertEqual(m.asteroids.first { $0.id == small.id }!.progress, 0)
        XCTAssertGreaterThan(m.asteroids.first { $0.id == big.id }!.progress, 0)
    }

    func testGazeBrakeSlowsTarget() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 7)
        var a = m.spawn(className: "XL")
        a.position = Vec2(195, 100); a.velocity = Vec2(0, 100)
        m.insert(a)
        m.update(dt: 0.1, gaze: .point(Vec2(195, 100)))
        XCTAssertEqual(m.asteroids[0].position.y, 100 + 100 * 0.1 * 0.6, accuracy: 1e-9, "40% brake on levels 1-3")
    }

    func testShieldsRunOutRestartsLevelEasier() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 8)
        var events: [GameEvent] = []
        for _ in 0..<5 {
            var a = m.spawn(className: "S")
            a.position = Vec2(m.earthCenter.x, m.earthTopY + 5); a.velocity = .zero
            m.insert(a)
            events += m.update(dt: 1.0 / 60, gaze: .notLooking)
        }
        XCTAssertTrue(events.contains { if case .shieldsDepleted = $0 { return true }; return false })
        XCTAssertEqual(m.shields, 5)
        XCTAssertEqual(m.level, 1)
    }

    func testLongDropoutPausesGame() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 9)
        var a = m.spawn(className: "M"); a.position = Vec2(195, 100); a.velocity = Vec2(0, 50); m.insert(a)
        for _ in 0..<70 { m.update(dt: 1.0 / 60, gaze: .lost) }
        XCTAssertTrue(m.pausedForFace)
        let y = m.asteroids[0].position.y
        m.update(dt: 0.1, gaze: .lost)
        XCTAssertEqual(m.asteroids[0].position.y, y, "frozen while the face is gone")
        m.update(dt: 0.1, gaze: .notLooking)
        XCTAssertFalse(m.pausedForFace)
    }

    func testSimulatedLevelOneIsWinnableWithPerfectGaze() throws {
        // A bot that looks at the lowest asteroid should clear level 1 (BALANCE.md target: >= 90%).
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 10)
        var ended: (Int, Double, Int)?
        var t = 0.0
        while ended == nil && t < 120 {
            let target = m.asteroids.max { $0.position.y < $1.position.y }
            if m.starved { m.reload() }   // the bot blinks three times as soon as it runs dry
            for e in m.update(dt: 1.0 / 60, gaze: target.map { .point($0.position) } ?? .notLooking) {
                if case let .levelEnded(level, ratio, next) = e { ended = (level, ratio, next) }
            }
            t += 1.0 / 60
        }
        let e = try XCTUnwrap(ended)
        XCTAssertGreaterThanOrEqual(e.1, 0.9)
        XCTAssertEqual(e.2, 2)
    }
}

final class EnergyTests: XCTestCase {
    let screen = Vec2(390, 844)

    func testBalanceJsonHasEnergyDefaults() throws {
        let e = try XCTUnwrap(try BalanceTests.config().energy)
        XCTAssertEqual(e.max, 10)
        XCTAssertEqual(e.cost("S"), 1); XCTAssertEqual(e.cost("M"), 2); XCTAssertEqual(e.cost("L"), 3); XCTAssertEqual(e.cost("XL"), 5)
        XCTAssertEqual(e.reloadBlinks, 3)
        XCTAssertEqual(e.reloadWindowSec, 2.0)
    }

    func testPartialEnergyJsonKeepsDefaults() throws {
        let e = try JSONDecoder().decode(EnergyConfig.self, from: Data(#"{"max": 6, "blink": {"closeThreshold": 0.7}}"#.utf8))
        XCTAssertEqual(e.max, 6)
        XCTAssertEqual(e.cost("XL"), 5)
        XCTAssertEqual(e.blink.closeThreshold, 0.7)
        XCTAssertEqual(e.blink.openThreshold, 0.35)
    }

    func testBurstNeedsAllPressesInsideWindow() {
        var b = BurstCounter(count: 3, windowSec: 2)
        XCTAssertFalse(b.press(at: 0)); XCTAssertFalse(b.press(at: 1.0)); XCTAssertTrue(b.press(at: 1.9))
        XCTAssertEqual(b.pending(at: 2), 0, "starts over after a burst")
        XCTAssertFalse(b.press(at: 10)); XCTAssertFalse(b.press(at: 11.5)); XCTAssertFalse(b.press(at: 12.6), "first press fell out of the window")
        XCTAssertTrue(b.press(at: 13.0))
    }

    /// Feeds a 60 Hz eye-closure curve: open, then closed for each (start, duration) blink. Returns all updates.
    func run(_ d: inout BlinkDetector, blinks: [(Double, Double)], until end: Double, closed: Double = 0.9) -> [(Double, BlinkUpdate)] {
        var out: [(Double, BlinkUpdate)] = []
        var t = 0.0
        while t < end {
            let shut = blinks.contains { t >= $0.0 && t < $0.0 + $0.1 }
            out.append((t, d.update(time: t, left: shut ? closed : 0.05, right: shut ? closed : 0.08)))
            t += 1.0 / 60
        }
        return out
    }

    func testThreeQuickBlinksReload() {
        var d = BlinkDetector(EnergyConfig())
        let u = run(&d, blinks: [(0.5, 0.15), (0.9, 0.15), (1.3, 0.15)], until: 2)
        XCTAssertEqual(u.filter { $0.1.blinkEnded != nil }.count, 3)
        XCTAssertEqual(u.filter { $0.1.reload }.count, 1)
        let reloadAt = u.first { $0.1.reload }!.0
        XCTAssertEqual(reloadAt, 1.45, accuracy: 0.03, "fires when the third blink ends")
    }

    func testNaturalBlinksDoNotReload() {
        var d = BlinkDetector(EnergyConfig())
        // Kids blink roughly every 3-5 s.
        let u = run(&d, blinks: [(0.5, 0.15), (3.5, 0.12), (7, 0.18), (10.5, 0.15)], until: 12)
        XCTAssertEqual(u.filter { $0.1.blinkEnded != nil }.count, 4)
        XCTAssertFalse(u.contains { $0.1.reload })
    }

    func testOneFrameSpikeAndLongClosureAreNotBlinks() {
        var d = BlinkDetector(EnergyConfig())
        // 1 frame glitch, then two blinks, then eyes shut for a second (resets), then one more blink.
        let u = run(&d, blinks: [(0.3, 0.01), (0.6, 0.15), (1.0, 0.15), (1.4, 1.0), (2.6, 0.15)], until: 3.2)
        XCTAssertEqual(u.filter { $0.1.blinkEnded != nil }.count, 3)
        XCTAssertFalse(u.contains { $0.1.reload }, "long closure cleared the two blinks before it")
    }

    func testSquintIsNotABlinkButFreezesGaze() {
        var d = BlinkDetector(EnergyConfig())
        let u = run(&d, blinks: [(0.5, 0.3)], until: 1.2, closed: 0.45)
        XCTAssertFalse(u.contains { $0.1.blinkEnded != nil })
        XCTAssertTrue(u.contains { $0.1.freezeGaze })
    }

    func testGazeFreezeCoversBlinkPlusSettleTime() {
        var d = BlinkDetector(EnergyConfig())
        let u = run(&d, blinks: [(0.5, 0.15)], until: 1.0)
        let frozen = u.filter { $0.1.freezeGaze }.map { $0.0 }
        XCTAssertEqual(frozen.first ?? -1, 0.5, accuracy: 0.02)
        XCTAssertEqual(frozen.last ?? -1, 0.65 + 0.08, accuracy: 0.03, "holds 80 ms after the eyes open")
        XCTAssertFalse(u.first { $0.0 > 0.8 }!.1.freezeGaze)
    }

    /// 60 Hz run of an arbitrary closure curve (same value for both eyes).
    func run(_ d: inout BlinkDetector, until end: Double, _ f: (Double) -> Double) -> [(Double, BlinkUpdate)] {
        var out: [(Double, BlinkUpdate)] = []
        var t = 0.0
        while t < end { out.append((t, d.update(time: t, left: f(t), right: f(t)))); t += 1.0 / 60 }
        return out
    }

    func testLookingDownIsNotABlinkAndBlinksStillCountThere() {
        // Looking at Earth lowers the lids: eyeBlink sits at 0.45 from t = 1 s. Then three blinks from that level.
        var d = BlinkDetector(EnergyConfig())
        let blinks = [3.0, 3.4, 3.8]
        let u = run(&d, until: 5) { t in
            if blinks.contains(where: { t >= $0 && t < $0 + 0.15 }) { return 0.95 }
            return t < 1 ? 0.05 : 0.45
        }
        XCTAssertFalse(u.contains { $0.0 < 2.9 && $0.1.eyesClosed }, "a lowered lid is not a closed eye")
        let held = u.filter { $0.0 > 1 && $0.0 < 2.9 && $0.1.freezeGaze }.map { $0.0 }
        XCTAssertLessThanOrEqual((held.last ?? 1) - 1, 0.3 + 0.08 + 0.02, "gaze is held only briefly after looking down")
        XCTAssertEqual(u.filter { $0.1.blinkEnded != nil }.count, 3, "blinks end even though the eyes reopen only to 0.45")
        XCTAssertEqual(u.filter { $0.1.reload }.count, 1)
    }

    func testEyesHeldShutStayClosed() {
        var d = BlinkDetector(EnergyConfig())
        let u = run(&d, until: 3) { t in t >= 0.5 && t < 2.5 ? 0.9 : 0.05 }
        XCTAssertTrue(u.filter { $0.0 > 0.6 && $0.0 < 2.45 }.allSatisfy { $0.1.eyesClosed && $0.1.freezeGaze },
                      "the open level is capped, so shut eyes never become the new open")
        XCTAssertFalse(u.contains { $0.1.blinkEnded != nil }, "two seconds shut is not a blink")
        XCTAssertFalse(u.last!.1.eyesClosed)
    }

    func parked(_ m: GameModel, _ cls: String, at p: Vec2) -> Asteroid {
        var a = m.spawn(className: cls); a.position = p; a.velocity = .zero; m.insert(a); return a
    }

    func testKillSpendsEnergyByClass() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 11)
        XCTAssertEqual(m.energy, 10)
        _ = parked(m, "L", at: Vec2(195, 300))
        var spent: [Int] = []
        for _ in 0..<90 {
            for e in m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) { if case .energySpent(let c, _) = e { spent.append(c) } }
        }
        XCTAssertEqual(spent, [3])
        XCTAssertEqual(m.energy, 7)
    }

    func testEmptyPoolBlocksUntilReload() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 12)
        // Two XL kills empty the pool.
        for _ in 0..<2 {
            _ = parked(m, "XL", at: Vec2(195, 300))
            for _ in 0..<130 { m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) }
        }
        XCTAssertEqual(m.energy, 0)
        let s = parked(m, "S", at: Vec2(195, 300))
        var events: [GameEvent] = []
        for _ in 0..<60 { events += m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) }
        XCTAssertTrue(m.starved)
        XCTAssertTrue(events.contains { if case .starved(true) = $0 { return true }; return false })
        let rock = try XCTUnwrap(m.asteroids.first { $0.id == s.id })
        XCTAssertEqual(rock.progress, 0)
        XCTAssertTrue(rock.isStarved)

        XCTAssertTrue(m.reload())
        XCTAssertEqual(m.energy, 10)
        XCTAssertFalse(m.reload(), "already full")
        for _ in 0..<32 { m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) }
        XCTAssertNil(m.asteroids.first { $0.id == s.id }, "destroyed after the reload")
        XCTAssertFalse(m.starved)
        XCTAssertEqual(m.energy, 9)
    }

    func testCannotAffordBigButCanAffordSmall() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 13)
        _ = parked(m, "XL", at: Vec2(195, 300))
        for _ in 0..<130 { m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) }
        _ = parked(m, "L", at: Vec2(195, 300))
        for _ in 0..<80 { m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) }
        XCTAssertEqual(m.energy, 2)
        let xl = parked(m, "XL", at: Vec2(100, 200))
        m.update(dt: 0.2, gaze: .point(Vec2(100, 200)))
        XCTAssertTrue(m.starved)
        XCTAssertEqual(m.asteroids.first { $0.id == xl.id }!.progress, 0)
        m.removeAll()
        _ = parked(m, "M", at: Vec2(100, 200))
        m.update(dt: 0.2, gaze: .point(Vec2(100, 200)))
        XCTAssertFalse(m.starved)
        XCTAssertGreaterThan(m.asteroids[0].progress, 0)
    }

    /// Steps the model at 60 Hz with the gaze on `p` for `sec` seconds and returns the events.
    @discardableResult
    func look(_ m: GameModel, at p: Vec2, for sec: Double) -> [GameEvent] {
        var ev: [GameEvent] = []
        for _ in 0..<Int((sec * 60).rounded()) { ev += m.update(dt: 1.0 / 60, gaze: .point(p)) }
        return ev
    }

    func testStarvedLookHoldsProgressWithoutSlipAndCountsReaction() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 15)
        let A = Vec2(100, 250), B = Vec2(300, 250)
        _ = parked(m, "XL", at: A)
        look(m, at: A, for: 2.05)                      // XL killed: 10 -> 5
        XCTAssertEqual(m.energy, 5)
        let xl = parked(m, "XL", at: A)
        look(m, at: A, for: 1.8)                       // 0.9 of the way, still affordable
        _ = parked(m, "S", at: B)
        look(m, at: B, for: 0.55)                      // S killed: 5 -> 4; the XL drained to about 0.35
        XCTAssertEqual(m.energy, 4)
        let before = try XCTUnwrap(m.asteroids.first { $0.id == xl.id })
        XCTAssertEqual(before.progress, 0.35, accuracy: 0.03)
        look(m, at: A, for: 1.5)                       // back on the XL, which now costs more than the pool
        let after = try XCTUnwrap(m.asteroids.first { $0.id == xl.id })
        XCTAssertTrue(after.isStarved)
        XCTAssertEqual(after.progress, before.progress, accuracy: 1e-9, "waits for the reload instead of draining")
        XCTAssertEqual(after.slips, 0, "running out of energy is not an attention slip")

        // A meteor first looked at while starved still gets its reaction time.
        m.removeAll()
        let fresh = parked(m, "XL", at: A)
        look(m, at: A, for: 0.3)
        XCTAssertNotNil(m.asteroids.first { $0.id == fresh.id }?.firstLookTime)
    }

    func testStarvedTargetIsStillSlowedByGaze() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 16)
        for _ in 0..<2 { _ = parked(m, "XL", at: Vec2(195, 300)); look(m, at: Vec2(195, 300), for: 2.1) }
        XCTAssertEqual(m.energy, 0)
        m.removeAll()
        var a = m.spawn(className: "M")
        a.position = Vec2(195, 100); a.velocity = Vec2(0, 100)
        m.insert(a)
        m.update(dt: 0.1, gaze: .point(Vec2(195, 100)))
        XCTAssertTrue(m.starved)
        XCTAssertEqual(m.asteroids[0].position.y, 100 + 100 * 0.1 * 0.6, accuracy: 1e-9, "40% brake on levels 1-3")
    }

    func testCostNeverExceedsAFullPool() throws {
        var c = try BalanceTests.config()
        c.energy?.max = 4                               // XL costs 5 in the file
        let m = GameModel(config: c, screen: screen, marginPt: 30, seed: 17)
        XCTAssertEqual(m.cost(className: "XL"), 4)
        let xl = parked(m, "XL", at: Vec2(195, 300))
        look(m, at: Vec2(195, 300), for: 2.1)
        XCTAssertNil(m.asteroids.first { $0.id == xl.id }, "a full pool can always pay for any class")
        XCTAssertEqual(m.energy, 0)
    }

    func testNeedsReloadWhenStarvedOrEmpty() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, seed: 18)
        XCTAssertFalse(m.needsReload)
        for _ in 0..<2 { _ = parked(m, "XL", at: Vec2(195, 300)); look(m, at: Vec2(195, 300), for: 2.1) }
        m.removeAll()
        m.update(dt: 1.0 / 60, gaze: .notLooking)
        XCTAssertFalse(m.starved)
        XCTAssertTrue(m.needsReload, "nothing left for even an S")
        m.reload()
        XCTAssertFalse(m.needsReload)

        var c = try BalanceTests.config()
        c.energy = nil
        XCTAssertFalse(GameModel(config: c, screen: screen, marginPt: 30, seed: 19).needsReload)
    }

    /// A bot with perfect gaze that needs 1.5 s (three blinks) to reload after running dry should still clear
    /// all 10 levels at the 80% advance ratio. Guards the energy numbers in balance.json against making the
    /// game unwinnable. It reloads about twice a level at the start and about five times by level 10.
    func testAllLevelsStayWinnableWithRealisticReloads() throws {
        for seed in [1, 2] as [UInt64] {
            let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 45, seed: seed)
            var cleared: [Int: Double] = [:]
            var reloads: [Int] = []
            var drySince: Double?
            var count = 0
            var t = 0.0
            while cleared[10] == nil && t < 900 {
                if m.needsReload {
                    if drySince == nil { drySince = t }
                    if t - (drySince ?? t) >= 1.5 { if m.reload() { count += 1 }; drySince = nil }
                } else { drySince = nil }
                let target = m.asteroids.filter { $0.position.y > 0 }.max { $0.position.y < $1.position.y }
                for e in m.update(dt: 1.0 / 60, gaze: target.map { .point($0.position) } ?? .notLooking) {
                    if case let .levelEnded(level, ratio, _) = e { cleared[level] = ratio; reloads.append(count); count = 0 }
                    if case .shieldsDepleted = e { XCTFail("seed \(seed): shields ran out on level \(m.level)") }
                }
                t += 1.0 / 60
            }
            for level in 1...10 {
                XCTAssertGreaterThanOrEqual(cleared[level] ?? 0, 0.8, "seed \(seed) level \(level)")
            }
            XCTAssertGreaterThanOrEqual(reloads.first ?? 0, 1, "the pool should run dry at least once on level 1")
        }
    }

    func testNoEnergyConfigMeansNoLimit() throws {
        var c = try BalanceTests.config()
        c.energy = nil
        let m = GameModel(config: c, screen: screen, marginPt: 30, seed: 14)
        for _ in 0..<4 {
            m.removeAll()   // drop natural spawns so only the parked XL is under the gaze
            _ = parked(m, "XL", at: Vec2(195, 300))
            for _ in 0..<130 { m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 300))) }
        }
        XCTAssertEqual(m.destroyedThisLevel, 4, "20 energy worth of XL with no pool")
        XCTAssertFalse(m.starved)
    }
}
