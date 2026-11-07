import XCTest
@testable import GazeCore

final class LockTests: XCTestCase {
    private let a = GazeLock.Target(id: 1, position: Vec2(100, 100), reach: 50)
    private let b = GazeLock.Target(id: 2, position: Vec2(200, 100), reach: 50)

    func testTheNearestTargetInReachIsLocked() {
        var lock = GazeLock()
        XCTAssertNil(lock.update(aim: Vec2(150, 200), time: 0, targets: [a, b]), "nothing in reach")
        XCTAssertEqual(lock.update(aim: Vec2(170, 110), time: 0.1, targets: [a, b]), 2)
        XCTAssertEqual(lock.since, 0.1)
    }

    func testTheLockHoldsPastTheReachUntilTheReleaseDistance() {
        var lock = GazeLock()
        lock.update(aim: Vec2(120, 100), time: 0, targets: [a, b])
        // 55 pt from A, past its 50 pt reach but inside 1.4 reaches; B is 45 pt away but not clearly closer.
        XCTAssertEqual(lock.update(aim: Vec2(155, 100), time: 0.1, targets: [a, b]), 1)
        XCTAssertEqual(lock.since, 0, "the same lock, not a new one")
        // 75 pt from A is past 1.4 reaches: A lets go and B, 25 pt away, takes the lock.
        XCTAssertEqual(lock.update(aim: Vec2(175, 100), time: 0.2, targets: [a, b]), 2)
        XCTAssertEqual(lock.update(aim: Vec2(100, 300), time: 0.3, targets: [a, b]), nil, "far from both")
    }

    func testAClearlyCloserTargetTakesTheLock() {
        var lock = GazeLock()
        let near = GazeLock.Target(id: 3, position: Vec2(140, 100), reach: 60)
        let first = GazeLock.Target(id: 1, position: Vec2(100, 100), reach: 60)
        lock.update(aim: Vec2(115, 100), time: 0, targets: [first, near])
        XCTAssertEqual(lock.locked, 1)
        // 22 pt from the locked one and 18 pt from the other: not clearly closer.
        XCTAssertEqual(lock.update(aim: Vec2(122, 100), time: 0.1, targets: [first, near]), 1)
        // 35 pt and 5 pt: it is.
        XCTAssertEqual(lock.update(aim: Vec2(135, 100), time: 0.2, targets: [first, near]), 3)
        XCTAssertEqual(lock.since, 0.2)
    }

    func testTheLockHoldsThroughAShortGapInTheAim() {
        var lock = GazeLock()
        lock.update(aim: Vec2(105, 100), time: 1, targets: [a])
        XCTAssertEqual(lock.update(aim: nil, time: 1.3, targets: [a]), 1)
        XCTAssertEqual(lock.update(aim: Vec2(110, 95), time: 1.32, targets: [a]), 1)
        XCTAssertEqual(lock.update(aim: nil, time: 1.6, targets: [a]), 1)
        XCTAssertNil(lock.update(aim: nil, time: 1.7, targets: [a]), "gone longer than 0.35 s")
    }

    func testATargetNoLongerPassedLetsGo() {
        var lock = GazeLock()
        lock.update(aim: Vec2(100, 100), time: 0, targets: [a, b])
        XCTAssertEqual(lock.locked, 1)
        // A was played: the aim still on its spot locks nothing, and the lock moves on once the aim reaches B.
        XCTAssertNil(lock.update(aim: Vec2(100, 100), time: 0.1, targets: [b]))
        XCTAssertNil(lock.since)
        XCTAssertEqual(lock.update(aim: Vec2(190, 100), time: 0.2, targets: [b]), 2)
        lock.reset()
        XCTAssertNil(lock.locked)
    }

    /// An aim that wavers around a note at the edge of its reach, as a slightly off calibration does: without the
    /// release margin the highlight would go on and off; with it, it stays on after the first lock.
    func testAWaveringAimDoesNotFlicker() {
        var lock = GazeLock()
        var rng = SplitMix(seed: 3)
        var changes = 0, last: Int?
        for k in 0..<120 {
            let aim = Vec2(100 + 45 + rng.gauss() * 6, 100 + rng.gauss() * 6)
            let id = lock.update(aim: aim, time: Double(k) / 60, targets: [a])
            if id != last { changes += 1; last = id }
        }
        XCTAssertEqual(last, 1)
        XCTAssertLessThanOrEqual(changes, 1, "locked once and held")
    }
}
