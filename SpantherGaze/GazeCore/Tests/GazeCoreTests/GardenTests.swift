import XCTest
@testable import GazeCore

final class GardenTests: XCTestCase {
    let screen = Vec2(844, 390)

    func testSameSeedSameGarden() {
        let a = Garden(size: screen, seed: 7), b = Garden(size: screen, seed: 7), c = Garden(size: screen, seed: 8)
        XCTAssertEqual(a.lianas, b.lianas)
        XCTAssertEqual(a.trees, b.trees)
        XCTAssertEqual(a.spores, b.spores)
        XCTAssertNotEqual(a.lianas, c.lianas)
    }

    /// The lianas stay on the screen, and the ones in the middle third end above the notes.
    func testLianasFrameThePlayArea() {
        let area = DistractionPlan.noteArea(screen)
        for seed in UInt64(1)...20 {
            let g = Garden(size: screen, seed: seed)
            XCTAssertEqual(g.lianas.count, 7)
            for i in g.lianas.indices {
                for t in stride(from: 0.0, through: 12, by: 0.7) {
                    let pts = g.lianaPoints(i, time: t)
                    for p in pts {
                        XCTAssertGreaterThan(p.x, -40)
                        XCTAssertLessThan(p.x, screen.x + 40)
                        XCTAssertLessThanOrEqual(p.y, screen.y * 0.62)
                    }
                }
                let x = g.lianas[i].anchorX
                if x > screen.x / 3, x < 2 * screen.x / 3 {
                    XCTAssertLessThan(g.lianas[i].length - 4, area.y.lowerBound, "seed \(seed) liana \(i)")
                }
            }
        }
    }

    func testTreesGrowLevelByLevel() {
        let g = Garden(size: screen, seed: 3)
        XCTAssertEqual(g.trees.count, 2)
        for t in g.trees.indices {
            let tree = g.trees[t]
            XCTAssertEqual(tree.maxDepth, 4)
            XCTAssertTrue(g.twigs(t, time: 0, growth: 0).isEmpty)
            XCTAssertEqual(g.twigs(t, time: 1.3, growth: 1).count, tree.segments.count)
            // Two of five levels: the trunk and the first branches, nothing deeper.
            let partial = g.twigs(t, time: 0, growth: 2.0 / 5)
            XCTAssertTrue(partial.allSatisfy { $0.depth <= 1 })
            XCTAssertEqual(partial.count, tree.segments.filter { $0.depth <= 1 }.count)
            // Every tip is reachable from the root along its parents.
            for (i, s) in tree.segments.enumerated() where s.isTip {
                let path = g.path(tree: t, to: i, time: 2)
                XCTAssertEqual(path.count, s.depth + 2)
                XCTAssertEqual(path.first, tree.root)
            }
            // The trees grow up from the bottom corners and stay in their half.
            for w in g.twigs(t, time: 4) {
                XCTAssertLessThan(w.b.y, screen.y + 10)
                if t == 0 { XCTAssertLessThan(w.b.x, screen.x / 2) } else { XCTAssertGreaterThan(w.b.x, screen.x / 2) }
            }
        }
    }

    func testPulseRunsDownThenFlashes() {
        let g = Garden(size: screen, seed: 5)
        let l = g.lianas[2]
        let start = l.pulseOffset + 3 * l.pulseEvery
        XCTAssertEqual(g.pulse(2, time: start).at ?? -1, 0, accuracy: 1e-9)
        let mid = g.pulse(2, time: start + Garden.pulseTravelSec / 2).at ?? -1
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)
        XCTAssertNil(g.pulse(2, time: start + Garden.pulseTravelSec + 0.1).at)
        XCTAssertNotNil(g.pulse(2, time: start + Garden.pulseTravelSec + 0.1).flash)
        XCTAssertNil(g.pulse(2, time: start + Garden.pulseTravelSec + Garden.pulseFlashSec + 0.1).flash)
    }

    func testSporesWrapAround() {
        let g = Garden(size: screen, seed: 9)
        for i in g.spores.indices {
            for t in stride(from: 0.0, through: 200, by: 3.3) {
                let p = g.spore(i, time: t).position
                XCTAssertGreaterThanOrEqual(p.y, -10)
                XCTAssertLessThanOrEqual(p.y, screen.y + 10)
            }
        }
        XCTAssertEqual(g.spores.filter(\.glows).count, 6)
    }

    func testDistractionsGetBusierWithTheLevel() {
        let g = Garden(size: screen, seed: 11)
        var counts: [RhythmLevel: Int] = [:]
        for level in RhythmLevel.allCases {
            let plan = DistractionPlan.make(level: level, garden: g, from: -1, to: 120, seed: 42)
            counts[level] = plan.count
            XCTAssertEqual(plan.map(\.start), plan.map(\.start).sorted())
            for d in plan {
                XCTAssertGreaterThanOrEqual(d.start, -1)
                XCTAssertLessThanOrEqual(d.start + d.duration, 120)
            }
            XCTAssertEqual(Set(plan.map(\.kind)).count, Distraction.Kind.allCases.count, "\(level) uses every kind")
        }
        // 120 s: easy about every 7.5 s, normal every 4.5 s, hard every 2.8 s.
        XCTAssertTrue((12...18).contains(counts[.easy]!), "easy \(counts[.easy]!)")
        XCTAssertTrue((21...31).contains(counts[.normal]!), "normal \(counts[.normal]!)")
        XCTAssertTrue((34...50).contains(counts[.hard]!), "hard \(counts[.hard]!)")
    }

    /// Below hard, fireflies and seeds keep out of the area the notes are in; on hard some cross it.
    func testDistractionsKeepToTheMarginsBelowHard() {
        let g = Garden(size: screen, seed: 13)
        let area = DistractionPlan.noteArea(screen)
        func inside(_ p: Vec2) -> Bool { area.x.contains(p.x) && area.y.contains(p.y) }
        for level in [RhythmLevel.easy, .normal] {
            for d in DistractionPlan.make(level: level, garden: g, from: 0, to: 300, seed: 5) where d.kind == .firefly || d.kind == .seed {
                for k in 0...40 {
                    let p = d.position(at: d.start + d.duration * Double(k) / 40)!
                    XCTAssertFalse(inside(p), "\(level) \(d.kind) at \(p)")
                }
            }
        }
        let hard = DistractionPlan.make(level: .hard, garden: g, from: 0, to: 300, seed: 5)
        let crossing = hard.filter { d in
            (d.kind == .firefly || d.kind == .seed) && (0...40).contains { inside(d.position(at: d.start + d.duration * Double($0) / 40)!) }
        }
        XCTAssertGreaterThan(crossing.count, 3)
    }

    func testStableSeedFromText() {
        XCTAssertEqual(DistractionPlan.seed("orbit"), DistractionPlan.seed("orbit"))
        XCTAssertNotEqual(DistractionPlan.seed("orbit"), DistractionPlan.seed("stardust"))
    }
}
