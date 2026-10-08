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
