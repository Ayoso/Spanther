import XCTest
@testable import GazeCore

final class RhythmTests: XCTestCase {
    private func track(bpm: Double, beats: Int = 64) -> RhythmTrack {
        RhythmTrack(id: "t", title: "T", author: "A", license: "CC0", file: "t.m4a", bpm: bpm, firstBeatSec: 2, beats: beats)
    }

    func testPatternFitsTheLevelAndTempo() {
        // 90 BPM: a beat is 0.67 s.
        XCTAssertEqual(ChartGenerator.mask(level: .easy, beatSec: 60 / 90.0), 1)    // every other beat, 0.75/s
        XCTAssertEqual(ChartGenerator.mask(level: .normal, beatSec: 60 / 90.0), 3)  // 6 of 8 beats, 1.1/s
        XCTAssertEqual(ChartGenerator.mask(level: .hard, beatSec: 60 / 90.0), 5)    // every beat, 1.5/s
        // 120 BPM: a beat is 0.5 s, so each level steps down.
        XCTAssertEqual(ChartGenerator.mask(level: .easy, beatSec: 0.5), 0)
        XCTAssertEqual(ChartGenerator.mask(level: .normal, beatSec: 0.5), 1)
    }

    func testGeneratedNotesStayOnTheGridAndInTheArea() {
        for bpm in [84.0, 100, 126] {
            let t = track(bpm: bpm)
            for level in RhythmLevel.allCases {
                let notes = ChartGenerator.notes(for: t, level: level)
                XCTAssertFalse(notes.isEmpty)
                XCTAssertEqual(notes, ChartGenerator.notes(for: t, level: level), "same notes on every play")
                for (a, b) in zip(notes, notes.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b.time - a.time, level.minGapSec - 1e-9, "\(bpm) \(level)")
                }
                for n in notes {
                    let beat = (n.time - t.firstBeatSec) / t.beatSec
                    XCTAssertEqual(beat, beat.rounded(), accuracy: 1e-9)
                    XCTAssertTrue(ChartGenerator.area.x.contains(n.x) && ChartGenerator.area.y.contains(n.y))
                    XCTAssertEqual(n.side, level == .hard ? (n.x < 0.5 ? .left : .right) : .any)
                }
                let rate = Double(notes.count) / (notes.last!.time - notes.first!.time)
                XCTAssertLessThanOrEqual(rate, level.maxPerSec + 0.05)
                // Each note is clear of the three before it, which may still be on screen.
                for (i, n) in notes.enumerated() {
                    for m in notes[max(0, i - 3)..<i] {
                        XCTAssertGreaterThanOrEqual(hypot(n.x - m.x, (n.y - m.y) * ChartGenerator.aspect),
                                                    ChartGenerator.minSeparation - 1e-9, "\(bpm) \(level) note \(i)")
                    }
                }
            }
        }
    }

    /// Gaps, rate and play area every chart must keep, whatever wrote it.
    private func assertPlayable(_ notes: [RhythmNote], _ level: RhythmLevel, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(notes.isEmpty, label, file: file, line: line)
        for (a, b) in zip(notes, notes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.time - a.time, level.minGapSec - 1e-9, label, file: file, line: line)
        }
        let limit = Int(level.maxPerSec * ChartGenerator.rateWindowSec + 1e-9)
        for (i, n) in notes.enumerated() {
            let inWindow = notes[i...].prefix { $0.time < n.time + ChartGenerator.rateWindowSec }.count
            XCTAssertLessThanOrEqual(inWindow, limit, "\(label) from note \(i)", file: file, line: line)
            XCTAssertTrue(ChartGenerator.area.x.contains(n.x) && ChartGenerator.area.y.contains(n.y), label,
                          file: file, line: line)
            XCTAssertEqual(n.side, level == .hard ? (n.x < 0.5 ? .left : .right) : .any, label, file: file, line: line)
        }
    }

    func testAccentsChooseTheNotes() {
        var t = track(bpm: 104, beats: 64)
        // Each bar: a downbeat (3), a melody note on beat 3 (2), an off-beat after beat 2 (1), plain beats 2 and 4 (1).
        var accents: [[Double]] = []
        for bar in 0..<16 {
            let b = Double(bar * 4)
            accents += [[b, 3], [b + 1, 1], [b + 1.5, 1], [b + 2, 2], [b + 3, 1]]
        }
        t.accents = accents
        for level in RhythmLevel.allCases {
            let notes = t.chart(level)
            assertPlayable(notes, level, "\(level)")
            let beats = notes.map { (($0.time - t.firstBeatSec) / t.beatSec * 2).rounded() / 2 }
            let allowed = Set(accents.filter { Int($0[1]) >= level.minStrength }.map { $0[0] })
            XCTAssertTrue(beats.allSatisfy(allowed.contains), "\(level): only accents strong enough for the level")
            XCTAssertTrue((0..<16).allSatisfy { beats.contains(Double($0 * 4)) }, "\(level): every downbeat is played")
            XCTAssertEqual(notes, t.chart(level), "same notes on every play")
        }
        XCTAssertEqual(t.chart(.easy).count, 16, "easy plays the downbeats only")
        XCTAssertEqual(t.chart(.normal).count, 32, "normal adds the melody note on beat 3")
        // Hard: at 104 BPM the off-beat is 0.29 s from the beats around it, too close; the plain beats fit.
        XCTAssertEqual(t.chart(.hard).count, 64)
        XCTAssertFalse(t.chart(.hard).contains { abs((($0.time - t.firstBeatSec) / t.beatSec).truncatingRemainder(dividingBy: 1) - 0.5) < 1e-6 })
        // At 70 BPM a beat is 0.86 s, so the off-beat fits between the beats around it.
        t.bpm = 70
        let slow = t.chart(.hard)
        assertPlayable(slow, .hard, "70 BPM")
        XCTAssertEqual(slow.count, 80)
    }

    func testAccentsOutsideTheTrackAreIgnored() {
        var t = track(bpm: 100, beats: 16)
        t.accents = [[-1, 3], [0, 3], [4, 3], [16, 3], [40, 3], [8, .nan], [12, 3]]
        XCTAssertEqual(t.chart(.easy).map { (($0.time - t.firstBeatSec) / t.beatSec).rounded() }, [0, 4, 12])
    }

    /// The tracks shipped in the app: they load, their audio is there and every level plays within the rules.
    func testBundledTracks() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("SpantherGaze/Resources")
        let url = resources.appendingPathComponent("tracks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no tracks.json at \(url.path)") }
        let tracks = try RhythmTrack.load(from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(tracks.count, 1)
        XCTAssertEqual(Set(tracks.map(\.id)).count, tracks.count, "ids are unique")
        for t in tracks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(t.file).path), t.file)
            var last = 0
            for level in RhythmLevel.allCases {
                let notes = t.chart(level)
                assertPlayable(notes, level, "\(t.id) \(level)")
                XCTAssertGreaterThanOrEqual(notes.first?.time ?? 0, t.firstBeatSec - 1e-9)
                XCTAssertLessThanOrEqual(notes.last?.time ?? 0, t.endSec)
                XCTAssertGreaterThan(notes.count, last, "\(t.id): each level has more notes than the one before")
                last = notes.count
            }
        }
    }

    func testHandMadeNotesWin() {
        var t = track(bpm: 100)
        t.notes = ["easy": [RhythmNote(time: 5, x: 0.5, y: 0.5), RhythmNote(time: 3, x: 0.2, y: 0.3)]]
        XCTAssertEqual(t.chart(.easy).map(\.time), [3, 5])
        XCTAssertNotEqual(t.chart(.normal).count, 2)
    }

    func testTracksJSON() throws {
        let json = """
        [{"id": "a", "title": "Первый", "author": "SPANTHER", "license": "CC0", "file": "a.m4a",
          "bpm": 96, "firstBeatSec": 1.25, "beats": 96, "phraseBeats": 8}]
        """
        let tracks = try RhythmTrack.load(from: Data(json.utf8))
        XCTAssertEqual(tracks.first?.title, "Первый")
        XCTAssertEqual(tracks.first?.beatSec ?? 0, 0.625, accuracy: 1e-12)
        XCTAssertEqual(tracks.first?.endSec ?? 0, 1.25 + 100 * 0.625, accuracy: 1e-9)
    }

    private func notes(_ times: [Double], side: NoteSide = .any) -> [RhythmNote] {
        times.map { RhythmNote(time: $0, x: 0.5, y: 0.5, side: side) }
    }

    func testWindowsAndTheLearnedDelay() {
        var j = RhythmJudge(notes: notes([1, 2, 3, 4]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0.1)
        let onTarget: (Int) -> Double? = { _ in 10 }
        XCTAssertEqual(j.closure(side: .left, time: 1.12, aimDistance: onTarget)?.judgement, .perfect)
        XCTAssertEqual(j.latencySec, 0.103, accuracy: 1e-9)          // moved 15% toward the 0.12 s it saw
        XCTAssertEqual(j.closure(side: .right, time: 2.25, aimDistance: onTarget)?.judgement, .good)
        XCTAssertEqual(j.closure(side: .left, time: 3.3, aimDistance: onTarget)?.judgement, .ok)
        XCTAssertNil(j.closure(side: .left, time: 4.5, aimDistance: onTarget), "too late for the last note")
        XCTAssertEqual(j.stray, 1)
        XCTAssertEqual(j.advance(to: 10), [3])
        XCTAssertEqual(j.results, [.perfect, .good, .ok, .miss])
        XCTAssertEqual(j.maxCombo, 3)
        XCTAssertEqual(j.combo, 0)
        XCTAssertTrue(j.finished)
        XCTAssertEqual(j.accuracy, (1 + 0.7 + 0.4) / 4, accuracy: 1e-12)
    }

    func testAimMustBeOnTheNote() {
        var j = RhythmJudge(notes: notes([1, 2]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        let hit = j.closure(side: .left, time: 1.0, aimDistance: { _ in 120 })
        XCTAssertEqual(hit?.judgement, .miss)
        XCTAssertEqual(hit?.offTarget, true)
        XCTAssertEqual(j.offTarget, 1)
        XCTAssertEqual(j.closure(side: .left, time: 2.0, aimDistance: { _ in nil })?.judgement, .miss, "no aim, no hit")
        XCTAssertEqual(j.latencySec, 0, "misses do not move the delay")
    }

    func testSideNotesNeedTheirEye() {
        var j = RhythmJudge(notes: [RhythmNote(time: 1, x: 0.2, y: 0.5, side: .left),
                                    RhythmNote(time: 1.4, x: 0.8, y: 0.5, side: .right)],
                            rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        // Right eye at 1.05: the left note is open but wrong, so the right note (window from 1.16) is not reached.
        XCTAssertNil(j.closure(side: .right, time: 1.05, aimDistance: { _ in 0 }))
        XCTAssertEqual(j.wrongEye, 1)
        XCTAssertEqual(j.closure(side: .left, time: 1.1, aimDistance: { _ in 0 })?.index, 0)
        XCTAssertEqual(j.closure(side: .right, time: 1.42, aimDistance: { _ in 0 })?.index, 1)
    }

    func testTheLockedNoteIsPlayedWhenWindowsOverlap() {
        // Notes 0.4 s apart: a closure at 1.2 s is in both windows (±0.24 s).
        var plain = RhythmJudge(notes: notes([1, 1.4]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        XCTAssertEqual(plain.closure(side: .left, time: 1.2, aimDistance: { _ in 0 })?.index, 0, "the earliest by default")
        var locked = RhythmJudge(notes: notes([1, 1.4]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        let hit = locked.closure(side: .left, time: 1.2, aimDistance: { $0 == 1 ? 0 : 200 }, prefer: 1)
        XCTAssertEqual(hit?.index, 1)
        XCTAssertEqual(hit?.judgement, .ok, "0.2 s early")
        XCTAssertEqual(locked.results, [nil, .ok])
        // A preferred note outside its window, or for the other eye, leaves the usual choice.
        var early = RhythmJudge(notes: notes([1, 2]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        XCTAssertEqual(early.closure(side: .left, time: 1.0, aimDistance: { _ in 0 }, prefer: 1)?.index, 0)
        var eye = RhythmJudge(notes: [RhythmNote(time: 1, x: 0.2, y: 0.5), RhythmNote(time: 1.4, x: 0.8, y: 0.5, side: .right)],
                              rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        XCTAssertEqual(eye.closure(side: .left, time: 1.2, aimDistance: { _ in 0 }, prefer: 1)?.index, 0)
    }

    func testBlinksCountOnlyOnTheEasyLevel() {
        var normal = RhythmJudge(notes: notes([1]), rules: .level(.normal, measuredErrorPt: 40), latencySec: 0)
        XCTAssertNil(normal.closure(side: .both, time: 1.0, aimDistance: { _ in 0 }))
        XCTAssertEqual(normal.wrongEye + normal.stray, 0, "an ordinary blink is not held against the player")
        var easy = RhythmJudge(notes: notes([1]), rules: .level(.easy, measuredErrorPt: 40), latencySec: 0)
        XCTAssertEqual(easy.closure(side: .both, time: 1.0, aimDistance: { _ in 0 })?.judgement, .perfect)
    }

    func testLevelRulesGrowWithTheMeasuredError() {
        XCTAssertEqual(RhythmRules.level(.easy, measuredErrorPt: 40).aimRadiusPt, 130)
        XCTAssertEqual(RhythmRules.level(.hard, measuredErrorPt: 500).aimRadiusPt, 145, "capped")
        XCTAssertTrue(RhythmRules.level(.easy, measuredErrorPt: 0).acceptBlink)
        XCTAssertFalse(RhythmRules.level(.normal, measuredErrorPt: 0).acceptBlink)
    }

    func testScoreGrowsWithTheCombo() {
        var j = RhythmJudge(notes: notes([1, 2, 3]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        for t in [1.0, 2.0, 3.0] { _ = j.closure(side: .left, time: t, aimDistance: { _ in 0 }) }
        XCTAssertEqual(j.score, 105 + 110 + 115)
        XCTAssertEqual(j.stars, 3)
    }
}
