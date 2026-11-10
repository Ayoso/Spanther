@testable import GazeCore
import XCTest

/// «Мелкие цели»: the drawn sizes and the hit zones shrink together, down to a floor set by the calibration.
final class SmallTargetTests: XCTestCase {
    /// iPhone 13 in landscape, the app's only orientation.
    let screen = Vec2(844, 390)

    private func parked(_ m: GameModel, _ cls: String, at p: Vec2) -> Asteroid {
        var a = m.spawn(className: cls)
        a.position = p
        a.velocity = .zero
        m.insert(a)
        return a
    }

    private func progress(_ m: GameModel, _ a: Asteroid) -> Double { m.asteroids.first { $0.id == a.id }?.progress ?? -1 }

    func testBalanceJsonAsksForThirtyPercentSmaller() throws {
        let c = try BalanceTests.config()
        XCTAssertEqual(c.smallTargetScale, 0.7, accuracy: 1e-12)
        XCTAssertEqual(c.zoneFloorFactor, 1.25, accuracy: 1e-12)
        XCTAssertEqual(c.zoneFloor(measuredErrorPt: 40, scale: 0.7), 50, accuracy: 1e-9)
        XCTAssertEqual(c.zoneFloor(measuredErrorPt: 40, scale: 1), 0, "regular targets keep the zone they had")
        XCTAssertEqual(c.zoneFloor(measuredErrorPt: nil, scale: 0.7), 0, "no measured miss by finger")
        XCTAssertEqual(c.zoneFloor(measuredErrorPt: .nan, scale: 0.7), 0)
        XCTAssertEqual(c.zoneFloor(measuredErrorPt: -5, scale: 0.7), 0)
    }

    func testAMistunedFileCannotMakeTargetsVanishOrGrow() throws {
        var c = try BalanceTests.config()
        c.targetScale = 0.1
        XCTAssertEqual(c.smallTargetScale, 0.4)
        c.targetScale = 3
        XCTAssertEqual(c.smallTargetScale, 1)
        c.targetScale = nil
        XCTAssertEqual(c.smallTargetScale, 1)
        c.minZonePerError = nil
        XCTAssertEqual(c.zoneFloorFactor, 1.25)
        c.minZonePerError = -2
        XCTAssertEqual(c.zoneFloorFactor, 0)
        XCTAssertEqual(GameModel(config: c, screen: screen, marginPt: 30, targetScale: 0.05, seed: 1).targetScale, 0.4)
        XCTAssertEqual(GameModel(config: c, screen: screen, marginPt: 30, targetScale: 9, seed: 1).targetScale, 1)
    }

    func testMeteorsAndTheirZonesShrinkTogether() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 40, targetScale: 0.7, seed: 31)
        XCTAssertEqual(m.spawn(className: "S").radius, 32 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(m.spawn(className: "M").radius, 50 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(m.spawn(className: "L").radius, 75 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(m.spawn(className: "XL").radius, 110 * 0.7, accuracy: 1e-9)
        let a = parked(m, "S", at: Vec2(195, 200))
        XCTAssertEqual(m.zone(radius: a.radius), (32 + 40) * 0.7, accuracy: 1e-9)   // 50.4 where it was 72
        m.update(dt: 0.1, gaze: .point(Vec2(195 + 49, 200)))
        XCTAssertGreaterThan(progress(m, a), 0, "49 pt: inside the smaller zone")
        m.removeAll()
        let b = parked(m, "S", at: Vec2(195, 200))
        m.update(dt: 0.1, gaze: .point(Vec2(195 + 52, 200)))
        XCTAssertEqual(progress(m, b), 0, "52 pt was inside the regular zone and is outside the smaller one")
    }

    func testAZoneNeverFallsUnderTheFloor() throws {
        // A calibration that missed by 60 pt: the floor is 75 pt.
        let c = try BalanceTests.config()
        let floor = c.zoneFloor(measuredErrorPt: 60, scale: 0.7)
        XCTAssertEqual(floor, 75, accuracy: 1e-9)
        let m = GameModel(config: c, screen: screen, marginPt: 60, targetScale: 0.7, zoneFloorPt: floor, seed: 32)
        XCTAssertEqual(m.zone(radius: 32 * 0.7), 75, accuracy: 1e-9, "S: (32 + 60) x 0.7 = 64.4, lifted to the floor")
        XCTAssertEqual(m.zone(radius: 110 * 0.7), (110 + 60) * 0.7, accuracy: 1e-9, "XL stays 30% smaller")
        let a = parked(m, "S", at: Vec2(300, 200))
        m.update(dt: 0.1, gaze: .point(Vec2(300 + 70, 200)))
        XCTAssertGreaterThan(progress(m, a), 0)
    }

    func testRegularTargetsAreUnchanged() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 40, seed: 33)
        XCTAssertEqual(m.targetScale, 1)
        XCTAssertEqual(m.spawn(className: "S").radius, 32)
        XCTAssertEqual(m.zone(radius: 32), 72)
    }

    func testSmallMeteorsBurnInTheSameTime() throws {
        let m = GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, targetScale: 0.7, seed: 34)
        let a = parked(m, "S", at: Vec2(195, 200))
        var t = 0.0, burned: Double?
        while burned == nil, t < 3 {
            for e in m.update(dt: 1.0 / 60, gaze: .point(Vec2(195, 200))) {
                if case .destroyed(let x, _) = e, x.id == a.id { burned = t + 1.0 / 60 }
            }
            t += 1.0 / 60
        }
        XCTAssertEqual(try XCTUnwrap(burned), 0.5, accuracy: 1.0 / 60 + 1e-9)
    }

    /// A player whose aim is off by the calibration's measured miss, in one direction, still clears level 1.
    func testLevelOneStaysWinnableWhenTheAimIsOffByTheMeasuredMiss() throws {
        let c = try BalanceTests.config()
        let miss = 45.0
        let m = GameModel(config: c, screen: screen, marginPt: c.hitMargin(measuredErrorPt: miss), targetScale: c.smallTargetScale,
                          zoneFloorPt: c.zoneFloor(measuredErrorPt: miss, scale: c.smallTargetScale), seed: 35)
        var ended: (ratio: Double, next: Int)?
        var t = 0.0
        while ended == nil, t < 120 {
            let target = m.asteroids.max { $0.position.y < $1.position.y }
            if m.starved { m.reload() }
            let gaze: GazeInput = target.map { .point($0.position + Vec2(miss * 0.8, miss * 0.6)) } ?? .notLooking
            for e in m.update(dt: 1.0 / 60, gaze: gaze) {
                if case let .levelEnded(_, ratio, next) = e { ended = (ratio, next) }
            }
            t += 1.0 / 60
        }
        let e = try XCTUnwrap(ended)
        XCTAssertGreaterThanOrEqual(e.ratio, 0.9)
        XCTAssertEqual(e.next, 2)
    }
}

/// The red signs: a look that rests on one for a quarter of a second is an error; passing it by is right.
final class DecoyTests: XCTestCase {
    let screen = Vec2(844, 390)
    /// 50 frames a second keeps the sums clear of the 0.25 s threshold.
    let dt = 0.02

    private func model(seed: UInt64, decoys: Bool = true, scale: Double = 1) throws -> GameModel {
        GameModel(config: try BalanceTests.config(), screen: screen, marginPt: 30, targetScale: scale, decoys: decoys, seed: seed)
    }

    private func parked(_ m: GameModel, at p: Vec2) -> Decoy {
        var s = m.spawnDecoy()
        s.position = p
        s.velocity = .zero
        m.insert(s)
        return s
    }

    private func parkedMeteor(_ m: GameModel, at p: Vec2) -> Asteroid {
        var a = m.spawn(className: "XL")
        a.position = p
        a.velocity = .zero
        m.insert(a)
        return a
    }

    private func errors(_ events: [GameEvent]) -> [DecoyRecord] {
        events.compactMap { if case .decoyLooked(_, let r) = $0 { return r }; return nil }
    }

    /// Steps `seconds` of play with the same gaze and returns what happened.
    private func run(_ m: GameModel, _ seconds: Double, _ gaze: GazeInput, held: Bool = false) -> [GameEvent] {
        var all: [GameEvent] = []
        for _ in 0..<Int((seconds / dt).rounded()) { all += m.update(dt: dt, gaze: gaze, held: held) }
        return all
    }

    func testBalanceJsonDescribesTheSigns() throws {
        let d = try XCTUnwrap(try BalanceTests.config().decoys)
        XCTAssertEqual(d.errorDwellSec, 0.25)
        XCTAssertEqual(d.sizePt, 84)
        XCTAssertEqual(d.maxOnScreen, 1)
        XCTAssertEqual(d.firstAfterSec, 6)
    }

    func testPartialJsonKeepsDefaults() throws {
        let d = try JSONDecoder().decode(DecoyConfig.self, from: Data(#"{"errorDwellSec": 0.3}"#.utf8))
        XCTAssertEqual(d.errorDwellSec, 0.3)
        XCTAssertEqual(d.sizePt, 84)
        XCTAssertEqual(d.travelSec, [7.0, 5.0])
        XCTAssertEqual(d.intervalSec, [8.0, 6.0])
    }

    func testNoSignsUnlessThePlayAsksForThem() throws {
        let m = try model(seed: 41, decoys: false)
        let events = run(m, 30, .notLooking)
        XCTAssertFalse(events.contains { if case .decoySpawned = $0 { return true }; return false })
        XCTAssertTrue(m.decoys.isEmpty)
        XCTAssertNil(m.decoyConfig)
    }

    func testSignsComeAfterSixSecondsAndThenEveryFewSeconds() throws {
        let m = try model(seed: 42)
        var times: [Double] = []
        var t = 0.0
        while t < 60 {
            for e in m.update(dt: dt, gaze: .notLooking) {
                if case .decoySpawned(let s) = e {
                    times.append(t)
                    XCTAssertEqual(s.radius, 42)
                }
            }
            XCTAssertLessThanOrEqual(m.decoys.count, 1, "one at a time")
            t += dt
        }
        XCTAssertEqual(try XCTUnwrap(times.first), 6, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(times.count, 5)
        for (a, b) in zip(times, times.dropFirst()) {
            // 8 s at level 1, give or take a fifth; never before the one before it has gone (7 s of flight).
            XCTAssertGreaterThan(b - a, 6.3)
            XCTAssertLessThan(b - a, 9.7)
        }
    }

    func testALookOfAQuarterSecondIsAnError() throws {
        let m = try model(seed: 43)
        let s = parked(m, at: Vec2(400, 150))
        XCTAssertTrue(errors(run(m, 0.24, .point(s.position))).isEmpty, "0.24 s is under the threshold")
        XCTAssertEqual(m.decoys.first?.isLookedAt, true)
        XCTAssertEqual(m.decoys.first?.dwellSec ?? 0, 0.24, accuracy: 1e-9)
        let found = errors(run(m, 0.02, .point(s.position)))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.looked, true)
        XCTAssertEqual(found.first?.lookSec ?? -1, 0, accuracy: 1e-9, "looked at from the moment it appeared")
        XCTAssertEqual(found.first?.lifetimeSec ?? -1, 0.26, accuracy: 1e-9)
        XCTAssertTrue(m.decoys.isEmpty, "the sign leaves once the error is counted")
    }

    func testTheLookMayRestAnywhereInItsZone() throws {
        let m = try model(seed: 44)
        let s = parked(m, at: Vec2(400, 150))   // radius 42, zone 72
        XCTAssertEqual(errors(run(m, 0.3, .point(Vec2(400 + 70, 150)))).count, 1)
        let far = parked(m, at: Vec2(400, 150))
        XCTAssertTrue(errors(run(m, 0.5, .point(Vec2(400 + 75, 150)))).isEmpty)
        XCTAssertEqual(m.decoys.first { $0.id == far.id }?.isLookedAt, false)
        _ = s
    }

    func testTwoShortGlancesAreNotAnError() throws {
        let m = try model(seed: 45)
        let s = parked(m, at: Vec2(400, 150))
        var all = run(m, 0.2, .point(s.position))
        all += run(m, 0.1, .point(Vec2(100, 300)))
        XCTAssertEqual(m.decoys.first?.dwellSec, 0, "looking away starts the count again")
        all += run(m, 0.2, .point(s.position))
        XCTAssertTrue(errors(all).isEmpty)
        XCTAssertEqual(m.decoys.count, 1)
    }

    func testABlinkNeitherGrowsNorEndsTheLook() throws {
        let m = try model(seed: 46)
        let s = parked(m, at: Vec2(400, 150))
        var all = run(m, 0.2, .point(s.position))
        // The eyelid moves for 0.3 s: the app keeps the gaze point from before the blink and says so.
        all += run(m, 0.3, .point(s.position), held: true)
        XCTAssertTrue(errors(all).isEmpty, "a kept point is not a look")
        XCTAssertEqual(m.decoys.first?.dwellSec ?? 0, 0.2, accuracy: 1e-9)
        all += run(m, 0.04, .point(s.position))
        XCTAssertTrue(errors(all).isEmpty)
        all += run(m, 0.02, .point(s.position))
        let found = errors(all)
        XCTAssertEqual(found.count, 1, "0.2 s before the blink and 0.06 s after it")
        XCTAssertEqual(found.first?.lookSec ?? -1, 0, accuracy: 1e-9)
    }

    func testAShortDropoutKeepsTheCountAndALongOneEndsIt() throws {
        let m = try model(seed: 47)
        let s = parked(m, at: Vec2(400, 150))
        var all = run(m, 0.2, .point(s.position))
        all += run(m, 0.1, .lost)
        XCTAssertEqual(m.decoys.first?.dwellSec ?? 0, 0.2, accuracy: 1e-9, "0.1 s without tracking: the count waits")
        all += run(m, 0.3, .lost)
        XCTAssertEqual(m.decoys.first?.dwellSec, 0, "0.4 s without tracking: the look has ended")
        XCTAssertTrue(errors(all).isEmpty)
    }

    func testAKeptPointDoesNotStartALook() throws {
        let m = try model(seed: 48)
        let s = parked(m, at: Vec2(400, 150))
        XCTAssertTrue(errors(run(m, 1.0, .point(s.position), held: true)).isEmpty)
        XCTAssertEqual(m.decoys.first?.dwellSec, 0)
        XCTAssertNil(m.decoys.first?.lookStart)
    }

    func testTheNearerOfASignAndAMeteorTakesTheLook() throws {
        let m = try model(seed: 49)
        let rock = parkedMeteor(m, at: Vec2(250, 150))   // radius 110, zone 140
        let sign = parked(m, at: Vec2(450, 150))         // radius 42, zone 72
        // 110 pt from the meteor (0.79 of its zone), 90 pt from the sign (outside its zone): the meteor burns.
        m.update(dt: dt, gaze: .point(Vec2(360, 150)))
        XCTAssertGreaterThan(m.asteroids.first { $0.id == rock.id }?.progress ?? 0, 0)
        XCTAssertEqual(m.decoys.first { $0.id == sign.id }?.isLookedAt, false)
        // 180 pt from the meteor (outside even its lock zone... 1.29 of the zone, inside the lock), 20 pt from the
        // sign (0.28): the sign is nearer by far and takes the look.
        m.update(dt: dt, gaze: .point(Vec2(430, 150)))
        XCTAssertEqual(m.decoys.first { $0.id == sign.id }?.isLookedAt, true)
        XCTAssertEqual(m.asteroids.first { $0.id == rock.id }?.isTargeted, false)
    }

    func testAPassedSignBurnsOutAtEarthAndHarmsNothing() throws {
        let m = try model(seed: 50)
        var s = m.spawnDecoy()
        s.position = Vec2(m.earthCenter.x, m.earthTopY - 60)
        s.velocity = Vec2(0, 200)
        m.insert(s)
        let energy = m.energy
        var passed: [DecoyRecord] = []
        for e in run(m, 1.0, .notLooking) {
            if case .decoyPassed(let x, let r) = e, x.id == s.id { passed.append(r) }
        }
        XCTAssertEqual(passed.count, 1)
        XCTAssertEqual(passed.first?.looked, false)
        XCTAssertNil(passed.first?.lookSec)
        XCTAssertEqual(m.shields, 5, "a sign is harmless")
        XCTAssertEqual(m.reachedThisLevel, 0, "and is not a meteor that got through")
        XCTAssertEqual(m.destroyedThisLevel, 0)
        XCTAssertEqual(m.score, 0)
        XCTAssertEqual(m.energy, energy)
    }

    func testAnErrorCostsNothingInTheGame() throws {
        let m = try model(seed: 51)
        let s = parked(m, at: Vec2(400, 150))
        let energy = m.energy
        XCTAssertEqual(errors(run(m, 0.3, .point(s.position))).count, 1)
        XCTAssertEqual(m.shields, 5)
        XCTAssertEqual(m.score, 0)
        XCTAssertEqual(m.energy, energy)
        XCTAssertEqual(m.destroyedThisLevel, 0)
    }

    func testSignsShrinkWithTheTargets() throws {
        let m = try model(seed: 52, scale: 0.7)
        XCTAssertEqual(m.spawnDecoy().radius, 42 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(m.zone(radius: 42 * 0.7), (42 + 30) * 0.7, accuracy: 1e-9)
    }

    func testSignsFlyToEarthLikeMeteors() throws {
        let m = try model(seed: 53)
        for _ in 0..<200 {
            let s = m.spawnDecoy()
            let landing = s.position + s.velocity * 7.0
            XCTAssertEqual(landing.y, m.earthSurfaceY(atX: landing.x), accuracy: 1e-6)
            XCTAssertTrue(s.position.y < 0 || s.position.x < 0 || s.position.x > 844, "starts just off the screen")
        }
    }

    func testAWholePlayKeepsCountingAcrossLevels() throws {
        // A player who burns every meteor and never looks at a sign: every sign passes, none is an error.
        let m = try model(seed: 54)
        var tally = MeteorTally()
        var t = 0.0
        while t < 100 {
            let target = m.asteroids.max { $0.position.y < $1.position.y }
            if m.starved { m.reload() }
            for e in m.update(dt: 1.0 / 60, gaze: target.map { .point($0.position) } ?? .notLooking) {
                switch e {
                case .destroyed(_, let r), .hitEarth(_, let r): tally.add(r)
                case .decoyLooked(_, let r), .decoyPassed(_, let r): tally.add(r)
                default: break
                }
            }
            t += 1.0 / 60
        }
        let s = tally.summary(id: "x", childCode: "", start: Date(timeIntervalSince1970: 0), durationSec: 100, byEye: true,
                              calibrationErrorCm: 1)
        XCTAssertGreaterThanOrEqual(s.decoys ?? 0, 8)
        XCTAssertLessThanOrEqual(s.decoyErrors ?? 99, 1, "a sign that flies through a meteor's zone may catch one look")
        XCTAssertGreaterThanOrEqual(s.maxLevel ?? 0, 2, "the signs went on over the level change")
    }
}
