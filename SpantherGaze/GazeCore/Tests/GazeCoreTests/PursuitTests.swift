@testable import GazeCore
import XCTest

final class PursuitTests: XCTestCase {
    /// iPhone 13 in landscape.
    let screen = Vec2(844, 390)
    let plan = PursuitPlan()

    func testAMinuteInThreeEqualParts() {
        XCTAssertEqual(plan.durationSec, 60)
        XCTAssertEqual(plan.partSec, 20)
        XCTAssertEqual(plan.part(at: 0), .horizontal)
        XCTAssertEqual(plan.part(at: 19.9), .horizontal)
        XCTAssertEqual(plan.part(at: 20), .vertical)
        XCTAssertEqual(plan.part(at: 39.9), .vertical)
        XCTAssertEqual(plan.part(at: 40), .eight)
        XCTAssertEqual(plan.part(at: 60), .eight)
    }

    func testStartsAndEndsAtRestInTheCentre() {
        XCTAssertEqual(plan.position(at: 0, in: screen), Vec2(422, 195))
        let end = plan.position(at: 60, in: screen)
        XCTAssertEqual(end.x, 422, accuracy: 1e-6)
        XCTAssertEqual(end.y, 195, accuracy: 1e-6)
        XCTAssertEqual(plan.position(at: 99, in: screen), plan.position(at: 60, in: screen), "it stays there afterwards")
        XCTAssertEqual(plan.position(at: -3, in: screen), plan.position(at: 0, in: screen))
        let first = plan.position(at: 1.0 / 60, in: screen).distance(to: plan.position(at: 0, in: screen))
        XCTAssertLessThan(first, 0.05, "no jump at the start")
    }

    func testEachPartMovesAlongItsOwnLine() {
        // Clear of the fades, the horizontal part does not move up or down, and the vertical one not sideways.
        var minX = 1.0, maxX = -1.0, minY = 1.0, maxY = -1.0
        for t in stride(from: 2.5, through: 18.5, by: 0.05) {
            let o = plan.offset(at: t)
            XCTAssertEqual(o.y, 0, accuracy: 1e-12)
            minX = min(minX, o.x); maxX = max(maxX, o.x)
        }
        XCTAssertEqual(minX, -plan.reachX, accuracy: 0.002)
        XCTAssertEqual(maxX, plan.reachX, accuracy: 0.002)
        for t in stride(from: 21.5, through: 38.5, by: 0.05) {
            let o = plan.offset(at: t)
            XCTAssertEqual(o.x, 0, accuracy: 1e-12)
            minY = min(minY, o.y); maxY = max(maxY, o.y)
        }
        XCTAssertEqual(minY, -plan.reachY, accuracy: 0.002)
        XCTAssertEqual(maxY, plan.reachY, accuracy: 0.002)
    }

    func testTheEightCrossesTheCentreTwiceAFigure() {
        // One figure takes 10 s: x goes there and back once, y twice, and they meet in the centre at 0 and 5 s.
        let t0 = 42.0
        var crossings = 0
        var last = plan.offset(at: t0).x
        for t in stride(from: t0 + 0.01, through: t0 + 10, by: 0.01) {
            let x = plan.offset(at: t).x
            if (last < 0) != (x < 0) {
                crossings += 1
                XCTAssertEqual(plan.offset(at: t).y, 0, accuracy: 0.01, "crosses through the centre")
            }
            last = x
        }
        XCTAssertEqual(crossings, 2)
        let quarter = plan.offset(at: 40 + 12.5)   // a quarter of a figure after the 50 s mark
        XCTAssertEqual(quarter.x, plan.reachX, accuracy: 1e-9)
        XCTAssertEqual(quarter.y, 0, accuracy: 1e-9)
    }

    func testThePathStaysOnTheScreenAndNeverJumps() {
        var last = plan.position(at: 0, in: screen)
        var lastStep = Vec2.zero
        var fastest = 0.0
        for i in 1...3600 {
            let t = Double(i) / 60
            let p = plan.position(at: t, in: screen)
            XCTAssertTrue(p.x >= 844 * 0.1 && p.x <= 844 * 0.9 && p.y >= 390 * 0.15 && p.y <= 390 * 0.85, "t = \(t)")
            let step = p - last
            fastest = max(fastest, step.length * 60)
            // The speed changes smoothly too: no frame turns the target on the spot.
            XCTAssertLessThan((step - lastStep).length, 0.2, "t = \(t)")
            last = p
            lastStep = step
        }
        XCTAssertLessThan(fastest, 300, "pt per second; about 5 cm/s on the phone")
        XCTAssertGreaterThan(fastest, 150)
    }

    func testFramesAroundAChangeOfPartAreNotScored() {
        XCTAssertFalse(plan.scored(at: 0.5))
        XCTAssertTrue(plan.scored(at: 1.0))
        XCTAssertTrue(plan.scored(at: 18.9))
        XCTAssertFalse(plan.scored(at: 19.5))
        XCTAssertFalse(plan.scored(at: 20.9))
        XCTAssertTrue(plan.scored(at: 21.0))
        XCTAssertFalse(plan.scored(at: 40.2))
        XCTAssertTrue(plan.scored(at: 59.9))
        XCTAssertTrue(plan.scored(at: 60))
        XCTAssertFalse(plan.scored(at: 60.1))
    }

    func testTheOnTargetRadiusGrowsWithTheCalibrationMiss() {
        XCTAssertEqual(PursuitPlan.onTargetRadius(measuredErrorPt: nil), 90, "by finger")
        XCTAssertEqual(PursuitPlan.onTargetRadius(measuredErrorPt: 10), 90)
        XCTAssertEqual(PursuitPlan.onTargetRadius(measuredErrorPt: 60), 120)
        XCTAssertEqual(PursuitPlan.onTargetRadius(measuredErrorPt: 400), 175)
    }

    func testTallyCountsFramesNearTheTarget() {
        var t = PursuitTally(radiusPt: 100)
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(t.all.share)
        XCTAssertNil(t.meanDistancePt)
        t.add(part: .horizontal, distance: 20)
        t.add(part: .horizontal, distance: 100)
        t.add(part: .horizontal, distance: 180)
        t.add(part: .vertical, distance: 40)
        t.add(part: .vertical, distance: nil)
        t.add(part: .eight, distance: 101)
        XCTAssertFalse(t.isEmpty)
        XCTAssertEqual(t.all, PursuitTally.Count(frames: 6, onTarget: 3))
        XCTAssertEqual(t.all.share ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(t.horizontal.share ?? 0, 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(t.vertical.share ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(t.eight.share ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(t.lost, 1)
        XCTAssertEqual(t.lostShare ?? 0, 1.0 / 6, accuracy: 1e-12)
        let mean: Double = 441.0 / 5
        XCTAssertEqual(t.meanDistancePt ?? 0, mean, accuracy: 1e-9, "only frames with a gaze point")
    }

    /// Plays the minute at 60 frames a second with a gaze given by `gaze(t)` and returns the tally.
    private func play(radius: Double = 90, _ gaze: (Double) -> Vec2?) -> PursuitTally {
        var tally = PursuitTally(radiusPt: radius)
        for i in 0...3600 {
            let t = Double(i) / 60
            guard plan.scored(at: t) else { continue }
            let target = plan.position(at: t, in: screen)
            tally.add(part: plan.part(at: t), distance: gaze(t).map { $0.distance(to: target) })
        }
        return tally
    }

    func testAFollowerScoresFullAndAStareAtTheCentreScoresLow() {
        let perfect = play { self.plan.position(at: $0, in: self.screen) }
        XCTAssertEqual(perfect.all.share, 1)
        XCTAssertEqual(perfect.meanDistancePt ?? 1, 0, accuracy: 1e-9)
        // Eyes that follow 150 ms behind, with a constant 40 pt miss of the calibration: still on the target.
        let lagging = play { self.plan.position(at: $0 - 0.15, in: self.screen) + Vec2(32, 24) }
        XCTAssertEqual(lagging.all.share ?? 0, 1, accuracy: 1e-12)
        XCTAssertGreaterThan(lagging.meanDistancePt ?? 0, 30)
        // Not following at all: the target is near the centre only a part of the time.
        let stare = play { _ in Vec2(422, 195) }
        XCTAssertLessThan(stare.all.share ?? 1, 0.45)
        XCTAssertGreaterThan(stare.all.share ?? 0, 0.1)
        // No gaze for the first half of the minute.
        let half = play { $0 < 30 ? nil : self.plan.position(at: $0, in: self.screen) }
        XCTAssertEqual(half.all.share ?? 0, 0.5, accuracy: 0.03)
        XCTAssertEqual(half.lostShare ?? 0, 0.5, accuracy: 0.03)
        XCTAssertEqual(half.horizontal.share, 0)
        XCTAssertEqual(half.eight.share, 1)
    }

    func testSummaryOfAWarmUp() {
        var t = PursuitTally(radiusPt: 100)
        for _ in 0..<8 { t.add(part: .horizontal, distance: 60) }
        for _ in 0..<2 { t.add(part: .horizontal, distance: 150) }
        for _ in 0..<5 { t.add(part: .vertical, distance: 30) }
        for _ in 0..<5 { t.add(part: .vertical, distance: nil) }
        for _ in 0..<10 { t.add(part: .eight, distance: 90) }
        let s = SessionSummary.pursuit(id: "p", childCode: "К-07", start: Date(timeIntervalSince1970: 0), durationSec: 60,
                                       byEye: true, calibrationErrorCm: 0.9, tally: t, ptPerCm: 60)
        XCTAssertEqual(s.game, .pursuit)
        XCTAssertEqual(s.holdShare ?? 0, 23.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(s.pursuitHorizontal ?? 0, 0.8, accuracy: 1e-12)
        XCTAssertEqual(s.pursuitVertical ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.pursuitEight ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(s.pursuitLostShare ?? 0, 5.0 / 30, accuracy: 1e-12)
        let sumPt: Double = 480 + 300 + 150 + 900
        let meanPt = sumPt / 25
        XCTAssertEqual(s.pursuitMeanCm ?? 0, meanPt / 60, accuracy: 1e-9)
        XCTAssertNil(s.targetScale)
        XCTAssertNil(s.meteors)
        XCTAssertNil(s.accuracy)
        XCTAssertNil(s.decoyErrors)
    }
}
