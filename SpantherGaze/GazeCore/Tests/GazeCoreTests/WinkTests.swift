import XCTest
@testable import GazeCore

final class WinkTests: XCTestCase {
    private let fps = 60.0

    /// Feeds frames at 60 fps from `t0` up to (not including) `t1` and returns the events.
    private func run(_ d: inout WinkDetector, _ t0: Double, _ t1: Double, fps: Double = 60,
                     left: (Double) -> Double, right: (Double) -> Double) -> [WinkEvent] {
        var events: [WinkEvent] = []
        let n = Int(((t1 - t0) * fps).rounded())
        for i in 0..<n {
            let t = t0 + Double(i) / fps
            if let e = d.update(time: t, left: left(t), right: right(t)) { events.append(e) }
        }
        return events
    }

    private func closed(_ from: Double, _ to: Double, _ level: Double = 0.9, open: Double = 0.1) -> (Double) -> Double {
        { t in t >= from - 1e-9 && t < to - 1e-9 ? level : open }
    }

    func testLeftWinkIsReportedAtItsOnset() {
        var d = WinkDetector()
        let events = run(&d, 0, 2, left: closed(1.0, 1.3), right: { _ in 0.12 })
        XCTAssertEqual(events.count, 1)
        guard let e = events.first else { return }
        XCTAssertEqual(e.side, .left)
        XCTAssertEqual(e.onset, 1.0, accuracy: 1e-6)
        XCTAssertEqual(e.decided - e.onset, 0.05, accuracy: 1.0 / fps)
        XCTAssertEqual(e.otherPeak, 0.12, accuracy: 1e-9)
    }

    func testRightWinkKeepsTheOtherEyesSquint() {
        var d = WinkDetector()
        let events = run(&d, 0, 2, left: closed(1.0, 1.3, 0.45, open: 0.1), right: closed(1.0, 1.3, 0.95))
        XCTAssertEqual(events.map(\.side), [.right])
        XCTAssertEqual(events.first?.otherPeak ?? 0, 0.45, accuracy: 1e-9)
    }

    func testNaturalBlinkIsBothEyes() {
        var d = WinkDetector()
        let events = run(&d, 0, 2, left: closed(1.0, 1.12), right: closed(1.0, 1.12))
        XCTAssertEqual(events.map(\.side), [.both])
    }

    func testEyesClosingOneFrameApartAreStillABlink() {
        var d = WinkDetector()
        let events = run(&d, 0, 2, left: closed(1.0, 1.15), right: closed(1.0 + 1 / fps, 1.15))
        XCTAssertEqual(events.map(\.side), [.both])
        XCTAssertEqual(events.first?.onset ?? 0, 1.0, accuracy: 1e-6)
    }

    func testOtherEyeFollowingTwoFramesLaterIsStillAWink() {
        // Aziz's left winks on 2026-11-07: the right eye followed 33-50 ms later and reached about 0.8.
        var d = WinkDetector()
        let events = run(&d, 0, 2, left: closed(1.0, 1.3, 0.87), right: closed(1.0 + 2 / fps, 1.25, 0.79))
        XCTAssertEqual(events.map(\.side), [.left])
        XCTAssertEqual(events.first?.onset ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertEqual(events.first?.otherPeak ?? 0, 0.79, accuracy: 1e-9)
    }

    func testAt30FpsTheNextFrameIsStillABlink() {
        // One frame is 33 ms at 30 fps, so a blink whose eyes cross a few ms apart can land on two frames.
        var d = WinkDetector()
        let events = run(&d, 0, 2, fps: 30, left: closed(1.0, 1.2), right: closed(1.0 + 1.0 / 30, 1.2))
        XCTAssertEqual(events.map(\.side), [.both])
    }

    func testOtherEyeClosingLateDoesNotTurnAWinkIntoABlink() {
        var d = WinkDetector()
        // The left eye winks; the right one squints shut 0.1 s later and both open together.
        let events = run(&d, 0, 2, left: closed(1.0, 1.4), right: closed(1.1, 1.4, 0.7))
        XCTAssertEqual(events.map(\.side), [.left])
    }

    func testOneBadFrameIsIgnored() {
        var d = WinkDetector()
        let events = run(&d, 0, 2, left: closed(1.0, 1.0 + 1 / fps), right: { _ in 0.1 })
        XCTAssertTrue(events.isEmpty)
    }

    func testALongWinkIsOneEvent() {
        var d = WinkDetector()
        let events = run(&d, 0, 3, left: closed(1.0, 2.5), right: { _ in 0.1 })
        XCTAssertEqual(events.count, 1)
    }

    func testWinksInARow() {
        var d = WinkDetector()
        let left = closed(1.0, 1.25), right = closed(2.0, 2.25)
        let events = run(&d, 0, 3, left: left, right: right)
        XCTAssertEqual(events.map(\.side), [.left, .right])
    }

    func testLoweredLidsRaiseTheCloseLevel() {
        var d = WinkDetector()
        // Looking down: both lids rest at 0.5, so 0.7 is not yet closed (needs 0.5 + 0.3) but 0.95 is.
        let half = run(&d, 0, 2, left: { t in t >= 1.0 && t < 1.3 ? 0.7 : 0.5 }, right: { _ in 0.5 })
        XCTAssertTrue(half.isEmpty)
        let full = run(&d, 2, 4, left: { t in t >= 3.0 && t < 3.3 ? 0.95 : 0.5 }, right: { _ in 0.5 })
        XCTAssertEqual(full.map(\.side), [.left])
    }

    func testFaceLostDropsAHalfSeenWink() {
        var d = WinkDetector()
        var events = run(&d, 0, 1.0 + 1 / fps, left: closed(1.0, 1.3), right: { _ in 0.1 })
        d.faceLost()
        events += run(&d, 1.5, 2, left: { _ in 0.1 }, right: { _ in 0.1 })
        XCTAssertTrue(events.isEmpty)
    }

    func testWinkTestPlanBlocks() {
        let plan = WinkTestPlan()
        XCTAssertEqual(plan.cues.count, 60)
        XCTAssertEqual(plan.countIn, [0, 1, 2, 3])
        XCTAssertEqual(plan.clicks.count, 64)
        XCTAssertTrue(plan.cues[0..<20].allSatisfy { $0.side == .left && $0.block == 0 })
        XCTAssertTrue(plan.cues[20..<40].allSatisfy { $0.side == .right && $0.block == 1 })
        XCTAssertEqual(plan.cues[40..<44].map(\.side), [.left, .right, .left, .right])
        XCTAssertEqual(plan.cues[0].offset, 4)
        XCTAssertEqual(plan.cues[20].offset, 28)   // 4 count-in + 20 + 4 rest
        XCTAssertEqual(plan.cues[40].offset, 52)
        XCTAssertEqual(plan.durationSec, 72)
    }

    func testStatsMatchEachCueToTheNearestWink() {
        let plan = WinkTestPlan(perBlock: 4, periodSec: 1.0, restBeats: 2, countInBeats: 2)
        let t0 = 100.0
        let beats = plan.cues.map { t0 + $0.offset }
        var events: [WinkEvent] = []
        // Left block: answered 60 and 100 ms late, alternately.
        for (i, c) in plan.cues.enumerated() where c.block == 0 {
            let late = i % 2 == 0 ? 0.06 : 0.10
            events.append(WinkEvent(side: .left, onset: beats[i] + late, decided: beats[i] + late + 0.05, otherPeak: 0.3))
        }
        // Right block: two hits, one wink with the wrong eye, one blink.
        let right = plan.cues.indices.filter { plan.cues[$0].block == 1 }
        events.append(WinkEvent(side: .right, onset: beats[right[0]] + 0.08, decided: beats[right[0]] + 0.13, otherPeak: 0.4))
        events.append(WinkEvent(side: .right, onset: beats[right[1]] + 0.08, decided: beats[right[1]] + 0.13, otherPeak: 0.2))
        events.append(WinkEvent(side: .left, onset: beats[right[2]], decided: beats[right[2]] + 0.05, otherPeak: 0.1))
        events.append(WinkEvent(side: .both, onset: beats[right[3]], decided: beats[right[3]], otherPeak: 0))
        // Half a beat away from any cue: a stray wink and a natural blink. The alternating block gets no answer.
        events.append(WinkEvent(side: .right, onset: beats[0] - 1.5, decided: beats[0] - 1.45, otherPeak: 0.1))
        events.append(WinkEvent(side: .both, onset: beats[right[0]] - 0.5, decided: beats[right[0]] - 0.5, otherPeak: 0))

        let s = WinkStats.compute(cues: plan.cues, beats: beats, events: events)
        XCTAssertEqual(s.left.cues, 6)
        XCTAssertEqual(s.left.hits, 4)
        XCTAssertEqual(s.left.meanOffsetMs, 80, accuracy: 1e-6)
        XCTAssertEqual(s.left.sdOffsetMs, 20, accuracy: 1e-6)
        XCTAssertEqual(s.left.within100, 4)
        XCTAssertEqual(s.left.medianOtherPeak, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.left.meanDecisionMs, 50, accuracy: 1e-6)
        XCTAssertEqual(s.right.cues, 6)
        XCTAssertEqual(s.right.hits, 2)
        XCTAssertEqual(s.right.wrongEye, 1)
        XCTAssertEqual(s.right.bothEyes, 1)
        XCTAssertEqual(s.right.meanOffsetMs, 80, accuracy: 1e-6)
        XCTAssertEqual(s.strayOneEye, 1)
        XCTAssertEqual(s.strayBoth, 1)
    }

    func testScriptedPlayerThroughTheDetector() {
        let plan = WinkTestPlan()
        let start = 50.0
        let bot = WinkBot(plan: plan, start: start)
        var d = WinkDetector()
        let events = run(&d, start - 1, start + plan.durationSec + 1,
                         left: { bot.lids(at: $0).left }, right: { bot.lids(at: $0).right })
        let s = WinkStats.compute(cues: plan.cues, beats: plan.cues.map { start + $0.offset }, events: events)
        XCTAssertEqual(s.left.cues, 30)
        XCTAssertEqual(s.left.hits, 27)
        XCTAssertEqual(s.left.wrongEye, 1)
        XCTAssertEqual(s.left.bothEyes, 1)
        XCTAssertEqual(s.right.hits, 24)
        XCTAssertEqual(s.right.wrongEye, 2)
        XCTAssertEqual(s.right.bothEyes, 2)
        XCTAssertEqual(s.strayBoth, 10)
        XCTAssertEqual(s.strayOneEye, 0)
        // 80 ms late on average, plus up to one frame until the detector sees the lid down.
        XCTAssertEqual(s.left.meanOffsetMs, 80 + 1000 / fps / 2, accuracy: 1000 / fps / 2 + 5)
        XCTAssertEqual(s.right.meanOffsetMs, 80 + 1000 / fps / 2, accuracy: 1000 / fps / 2 + 5)
        XCTAssertLessThan(s.left.sdOffsetMs, 45)
        XCTAssertEqual(s.left.within100, 27)
        XCTAssertEqual(s.left.medianOtherPeak, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.left.meanDecisionMs, 50, accuracy: 1000 / fps)
    }
}
