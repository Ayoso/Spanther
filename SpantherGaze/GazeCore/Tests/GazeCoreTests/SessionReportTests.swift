@testable import GazeCore
import XCTest

final class SessionReportTests: XCTestCase {
    /// 2026-11-12 05:30 UTC (10:30 in Almaty), 2026-11-12 06:05 UTC, 2026-11-11 09:00 UTC.
    private let thursday = Date(timeIntervalSince1970: 1_794_461_400)
    private let thursdayLater = Date(timeIntervalSince1970: 1_794_463_500)
    private let wednesday = Date(timeIntervalSince1970: 1_794_387_600)

    private func rock(level: Int, reaction: Double?, slips: Int, burned: Bool) -> AsteroidRecord {
        AsteroidRecord(className: "M", level: level, reactionSec: reaction, lifetimeSec: 3, slips: slips, destroyed: burned)
    }

    private func meteors(_ code: String, _ start: Date, byEye: Bool = true, burned: Int = 1, of total: Int = 2) -> SessionSummary {
        var t = MeteorTally()
        for i in 0..<total { t.add(rock(level: 1, reaction: 1, slips: 0, burned: i < burned)) }
        return t.summary(id: UUID().uuidString, childCode: code, start: start, durationSec: 60, byEye: byEye,
                         calibrationErrorCm: byEye ? 1.2 : nil)
    }

    private func notes(_ times: [Double]) -> [RhythmNote] { times.map { RhythmNote(time: $0, x: 0.5, y: 0.5) } }

    /// A rhythm play of four notes: perfect, good, ok, then a wink far from any note and a missed last note.
    private func playedJudge() -> RhythmJudge {
        var j = RhythmJudge(notes: notes([1, 2, 3, 4]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        let onTarget: (Int) -> Double? = { _ in 10 }
        _ = j.closure(side: .left, time: 1.02, aimDistance: onTarget)
        _ = j.closure(side: .right, time: 2.15, aimDistance: onTarget)
        _ = j.closure(side: .left, time: 3.2, aimDistance: onTarget)
        _ = j.closure(side: .left, time: 4.6, aimDistance: onTarget)
        _ = j.advance(to: 10)
        return j
    }

    private func rhythm(_ code: String, _ start: Date, level: RhythmLevel, byEye: Bool = true) -> SessionSummary {
        .rhythm(id: UUID().uuidString, childCode: code, start: start, durationSec: 61, byEye: byEye, calibrationErrorCm: nil,
                track: "Track", level: level, judge: playedJudge())
    }

    func testMeteorTallySummary() {
        var t = MeteorTally()
        XCTAssertTrue(t.isEmpty)
        t.add(rock(level: 1, reaction: 0.5, slips: 0, burned: true))
        t.add(rock(level: 2, reaction: 1.0, slips: 2, burned: true))
        t.add(rock(level: 2, reaction: nil, slips: 1, burned: false))   // never looked at, reached Earth
        XCTAssertFalse(t.isEmpty)
        let s = t.summary(id: "a", childCode: "К-07", start: thursday, durationSec: 252, byEye: true, calibrationErrorCm: 1.23)
        XCTAssertEqual(s.game, .meteors)
        XCTAssertEqual(s.meteors, 3)
        XCTAssertEqual(s.burned, 2)
        XCTAssertEqual(s.burnedShare ?? 0, 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(s.meanFirstLookSec ?? 0, 0.75, accuracy: 1e-12, "only the meteors that were looked at")
        XCTAssertEqual(s.slipsPerMeteor ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertEqual(s.maxLevel, 2)
        XCTAssertEqual(s.calibrationErrorCm, 1.23)
        XCTAssertNil(s.accuracy)
        XCTAssertNil(s.track)
    }

    func testEmptyTallyHasNoRates() {
        let s = MeteorTally().summary(id: "e", childCode: "", start: thursday, durationSec: 5, byEye: false, calibrationErrorCm: nil)
        XCTAssertEqual(s.meteors, 0)
        XCTAssertEqual(s.burned, 0)
        XCTAssertNil(s.burnedShare)
        XCTAssertNil(s.meanFirstLookSec)
        XCTAssertNil(s.slipsPerMeteor)
        XCTAssertNil(s.maxLevel)
    }

    func testCalibrationErrorMustBeFinite() {
        XCTAssertNil(SessionSummary(id: "n", childCode: "", game: .meteors, start: thursday, durationSec: 1, byEye: true,
                                    calibrationErrorCm: .nan).calibrationErrorCm)
        XCTAssertNil(SessionSummary(id: "i", childCode: "", game: .meteors, start: thursday, durationSec: 1, byEye: true,
                                    calibrationErrorCm: .infinity).calibrationErrorCm)
    }

    func testRhythmSummaryReadsTheJudge() {
        let s = rhythm("К-07", thursday, level: .normal)
        XCTAssertEqual(s.game, .rhythm)
        XCTAssertEqual(s.track, "Track")
        XCTAssertEqual(s.rhythmLevel, "normal")
        XCTAssertEqual(s.notes, 4)
        XCTAssertEqual(s.hits, 3)
        XCTAssertEqual(s.perfect, 1)
        XCTAssertEqual(s.maxCombo, 3)
        XCTAssertEqual(s.accuracy ?? 0, (1 + 0.7 + 0.4) / 4, accuracy: 1e-12)
        XCTAssertEqual(s.extraWinks, 1, "the wink after the last note's window")
        XCTAssertNil(s.meteors)
        XCTAssertNil(rhythm("К-07", thursday, level: .normal, byEye: false).extraWinks, "no winks by finger")
    }

    func testHistoryRoundTripAndBadFile() {
        let all = [meteors("К-07", thursday), rhythm("К-07", wednesday, level: .easy)]
        XCTAssertEqual(SessionHistory.decode(SessionHistory.encode(all)), all)
        XCTAssertEqual(SessionHistory.decode(Data("not json".utf8)), [])
        XCTAssertEqual(SessionHistory.decode(Data()), [])
    }

    func testPlaysOfOneChildOldestFirst() {
        let a = meteors("К-07", thursday), b = meteors("К-08", wednesday), c = rhythm("К-07", wednesday, level: .easy)
        XCTAssertEqual(SessionHistory.plays(of: " К-07 ", in: [a, b, c]).map(\.id), [c.id, a.id])
        XCTAssertEqual(SessionHistory.plays(of: "", in: [a, b, c]).map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(SessionHistory.plays(of: "К-09", in: [a, b, c]), [])
    }

    func testProgressComparesLikeWithLike() {
        let eye1 = meteors("К-07", wednesday, burned: 1), eye2 = meteors("К-07", thursday, burned: 2)
        XCTAssertEqual(SessionHistory.progress([eye1, eye2], game: .meteors).map(\.id), [eye1.id, eye2.id])
        // The newest play was by finger: the eye plays do not compare with it, and one play is not a trend.
        let finger = meteors("К-07", thursdayLater, byEye: false)
        XCTAssertEqual(SessionHistory.progress([eye1, eye2, finger], game: .meteors), [])
        XCTAssertEqual(SessionHistory.progress([eye1, eye2, finger], game: .rhythm), [])
        // The rhythm compares within the newest play's level.
        let easy = rhythm("К-07", wednesday, level: .easy), normal1 = rhythm("К-07", thursday, level: .normal)
        let normal2 = rhythm("К-07", thursdayLater, level: .normal)
        XCTAssertEqual(SessionHistory.progress([easy, normal1, eye1, normal2], game: .rhythm).map(\.id), [normal1.id, normal2.id])
        XCTAssertEqual(SessionHistory.progress([normal1, easy], game: .rhythm), [])
    }

    func testMeteorHoldShareCountsOnlyTheMeteorsLookedAt() {
        var t = MeteorTally()
        t.add(rock(level: 1, reaction: 0.5, slips: 0, burned: true))    // held
        t.add(rock(level: 1, reaction: 0.7, slips: 0, burned: true))    // held
        t.add(rock(level: 1, reaction: 0.9, slips: 2, burned: true))    // burned, but the gaze left it twice
        t.add(rock(level: 1, reaction: 1.5, slips: 0, burned: false))   // looked at, not burned
        t.add(rock(level: 1, reaction: nil, slips: 0, burned: false))   // never looked at: not a question of holding
        let s = t.summary(id: "h", childCode: "", start: thursday, durationSec: 60, byEye: true, calibrationErrorCm: 1)
        XCTAssertEqual(s.holdShare ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertNil(s.decoys, "a play without red signs has no count of them")
        XCTAssertNil(s.decoyErrors)
        XCTAssertNil(s.decoyErrorShare)
        XCTAssertNil(s.timingDeviationMs)
        XCTAssertNil(s.winkLeft)
        var none = MeteorTally()
        none.add(rock(level: 1, reaction: nil, slips: 0, burned: false))
        XCTAssertNil(none.summary(id: "n", childCode: "", start: thursday, durationSec: 9, byEye: true,
                                  calibrationErrorCm: 1).holdShare)
    }

    func testDecoyErrorsAreCounted() {
        var t = MeteorTally()
        t.add(rock(level: 1, reaction: 0.5, slips: 0, burned: true))
        t.add(DecoyRecord(level: 1, lifetimeSec: 7, looked: false, lookSec: nil))
        t.add(DecoyRecord(level: 1, lifetimeSec: 2.1, looked: true, lookSec: 1.8))
        t.add(DecoyRecord(level: 2, lifetimeSec: 7, looked: false, lookSec: nil))
        t.add(DecoyRecord(level: 2, lifetimeSec: 7, looked: false, lookSec: nil))
        let s = t.summary(id: "d", childCode: "", start: thursday, durationSec: 60, byEye: true, calibrationErrorCm: 1,
                          targetScale: 0.7)
        XCTAssertEqual(s.decoys, 4)
        XCTAssertEqual(s.decoyErrors, 1)
        XCTAssertEqual(s.decoyErrorShare ?? 0, 0.25, accuracy: 1e-12)
        XCTAssertEqual(s.targetScale, 0.7)
        XCTAssertEqual(t.decoyRecords.count, 4)
        // Signs that all passed: zero errors is a result, not a missing number.
        var clean = MeteorTally()
        clean.add(DecoyRecord(level: 1, lifetimeSec: 7, looked: false, lookSec: nil))
        let c = clean.summary(id: "c", childCode: "", start: thursday, durationSec: 60, byEye: true, calibrationErrorCm: 1)
        XCTAssertEqual(c.decoyErrors, 0)
        XCTAssertEqual(c.decoyErrorShare, 0)
        XCTAssertNil(c.targetScale, "the regular size is not written down")
    }

    func testRhythmSummaryHasTimingAndBothEyes() {
        // Left winks: 1.02 (perfect), 3.2 (ok), 4.6 (far from any note). Right wink: 2.15 (good).
        let s = rhythm("К-07", thursday, level: .normal)
        let offsets = [0.02, 0.15, 0.2]
        let mean = offsets.reduce(0, +) / 3
        XCTAssertEqual(s.timingOffsetMs ?? 0, mean * 1000, accuracy: 1e-6)
        XCTAssertEqual(s.timingDeviationMs ?? 0, offsets.reduce(0) { $0 + abs($1 - mean) } / 3 * 1000, accuracy: 1e-6)
        XCTAssertEqual(s.winkLeft ?? 0, 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(s.winkRight ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(s.holdShare ?? 0, 1, accuracy: 1e-12, "every wink in a note's window had the gaze on the note")
        // By finger there are no eyes to compare and no gaze to hold; the timing is still there.
        let finger = rhythm("К-07", thursday, level: .normal, byEye: false)
        XCTAssertNil(finger.winkLeft)
        XCTAssertNil(finger.winkRight)
        XCTAssertNil(finger.holdShare)
        XCTAssertNotNil(finger.timingDeviationMs)
    }

    func testRhythmHoldShareDropsWhenTheGazeIsOffTheNote() {
        var j = RhythmJudge(notes: notes([1, 2, 3, 4]), rules: RhythmRules(aimRadiusPt: 80, acceptBlink: false), latencySec: 0)
        _ = j.closure(side: .left, time: 1, aimDistance: { _ in 10 })
        _ = j.closure(side: .left, time: 2, aimDistance: { _ in 300 })   // on the beat, the gaze elsewhere
        _ = j.closure(side: .right, time: 3, aimDistance: { _ in 10 })
        _ = j.advance(to: 10)                                              // the last note: no wink at all
        let s = SessionSummary.rhythm(id: "r", childCode: "", start: thursday, durationSec: 30, byEye: true,
                                      calibrationErrorCm: 1, track: "T", level: .hard, judge: j, targetScale: 0.7)
        XCTAssertEqual(s.holdShare ?? 0, 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(s.winkLeft ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(s.winkRight ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(s.targetScale, 0.7)
    }

    func testOldStoredPlaysStillOpen() throws {
        // A play as the previous build stored it: none of the new numbers.
        let old = #"[{"id":"a","childCode":"К-07","game":"meteors","start":784000000,"durationSec":120,"byEye":true,"#
            + #""calibrationErrorCm":1.1,"meteors":10,"burned":8,"meanFirstLookSec":0.9,"slipsPerMeteor":0.2,"maxLevel":2}]"#
        let plays = SessionHistory.decode(Data(old.utf8))
        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays.first?.burned, 8)
        XCTAssertNil(plays.first?.holdShare)
        XCTAssertNil(plays.first?.targetScale)
        XCTAssertNil(plays.first?.decoyErrors)
    }

    func testAPlayThisBuildCannotReadIsLeftOutAlone() {
        let good = meteors("К-07", thursday)
        var text = String(decoding: SessionHistory.encode([good, good]), as: UTF8.self)
        // Between the two, a play of a game a later build might add.
        let future = #"{"id":"z","childCode":"К-07","game":"memory","start":784000000,"durationSec":5,"byEye":true}"#
        text = text.replacingOccurrences(of: "},{", with: "},\(future),{")
        XCTAssertTrue(text.contains("memory"))
        XCTAssertEqual(SessionHistory.decode(Data(text.utf8)).map(\.id), [good.id, good.id])
    }

    func testProgressNeedsTheSameTargetSize() {
        func small(_ start: Date) -> SessionSummary {
            var s = meteors("К-07", start)
            s.targetScale = 0.7
            return s
        }
        let big1 = meteors("К-07", wednesday), small1 = small(thursday), small2 = small(thursdayLater)
        XCTAssertEqual(SessionHistory.progress([big1, small1, small2], game: .meteors).map(\.id), [small1.id, small2.id])
        XCTAssertEqual(SessionHistory.progress([big1, small1], game: .meteors), [], "a size change is not a trend")
        // The warm-up has no target size to keep apart.
        func warmUp(_ start: Date) -> SessionSummary {
            var t = PursuitTally(radiusPt: 90)
            t.add(part: .horizontal, distance: 10)
            return .pursuit(id: UUID().uuidString, childCode: "К-07", start: start, durationSec: 60, byEye: true,
                            calibrationErrorCm: 1, tally: t, ptPerCm: 60)
        }
        let w1 = warmUp(wednesday), w2 = warmUp(thursday)
        XCTAssertEqual(SessionHistory.progress([w1, small1, w2], game: .pursuit).map(\.id), [w1.id, w2.id])
        XCTAssertEqual(SessionHistory.gameName(.pursuit), "Разминка")
    }

    func testCSVForARussianSpreadsheet() {
        var m = MeteorTally()
        m.add(rock(level: 1, reaction: 0.5, slips: 0, burned: true))
        m.add(rock(level: 3, reaction: 1.25, slips: 1, burned: true))
        m.add(rock(level: 3, reaction: nil, slips: 0, burned: false))
        m.add(DecoyRecord(level: 1, lifetimeSec: 7, looked: false, lookSec: nil))
        m.add(DecoyRecord(level: 3, lifetimeSec: 2, looked: true, lookSec: 1.7))
        m.add(DecoyRecord(level: 3, lifetimeSec: 7, looked: false, lookSec: nil))
        let play = m.summary(id: "m", childCode: "К-07", start: thursday, durationSec: 252, byEye: true,
                             calibrationErrorCm: 1.234, targetScale: 0.7)
        var tune = SessionSummary(id: "r", childCode: "К;\"07\"", game: .rhythm, start: wednesday, durationSec: 61,
                                  byEye: false, calibrationErrorCm: nil)
        tune.track = "Track"
        tune.rhythmLevel = "hard"
        tune.accuracy = 0.8125
        tune.notes = 4
        tune.hits = 3
        tune.perfect = 1
        tune.maxCombo = 3
        tune.timingDeviationMs = 41.6
        tune.timingOffsetMs = 123.4
        var tally = PursuitTally(radiusPt: 100)
        for _ in 0..<3 { tally.add(part: .horizontal, distance: 60) }
        tally.add(part: .vertical, distance: 150)
        tally.add(part: .eight, distance: nil)
        let warmUp = SessionSummary.pursuit(id: "p", childCode: "К-07", start: thursdayLater, durationSec: 60, byEye: true,
                                            calibrationErrorCm: 0.95, tally: tally, ptPerCm: 60)
        // Almaty is UTC+5.
        let csv = SessionHistory.csv([play, warmUp, tune], timeZone: TimeZone(secondsFromGMT: 5 * 3600)!)
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        let lines = csv.components(separatedBy: "\r\n").dropLast()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], SessionHistory.csvHeader.joined(separator: ";"))
        XCTAssertEqual(SessionHistory.csvHeader.count, 34)
        XCTAssertEqual(Array(SessionHistory.csvHeader[0..<5]), ["Код ребёнка", "Дата", "Время", "Игра", "Управление"])
        // The four numbers of the report sit together, right after the play's own columns.
        XCTAssertEqual(Array(SessionHistory.csvHeader[8..<14]), [
            "Удержание взгляда, %", "Отклонение от ритма, мс", "Красных знаков", "Ошибок на красных",
            "Подмигивания левым, %", "Подмигивания правым, %",
        ])
        // Oldest first: the rhythm play of Wednesday, its code quoted because it holds a separator and quotes.
        XCTAssertEqual(lines[1], [
            "\"К;\"\"07\"\"\"", "2026-11-11", "14:00", "Ритм", "палец", "1,0", "", "100",
            "", "42", "", "", "", "",
            "", "", "", "", "", "",
            "Track", "hard", "81", "4", "3", "1", "3", "", "123",
            "", "", "", "", "",
        ].joined(separator: ";"))
        XCTAssertEqual(lines[2], [
            "К-07", "2026-11-12", "10:30", "Метеориты", "взгляд", "4,2", "1,23", "70",
            "50", "", "3", "1", "", "",
            "3", "2", "67", "0,88", "0,33", "3",
            "", "", "", "", "", "", "", "", "",
            "", "", "", "", "",
        ].joined(separator: ";"))
        XCTAssertEqual(lines[3], [
            "К-07", "2026-11-12", "11:05", "Разминка", "взгляд", "1,0", "0,95", "100",
            "60", "", "", "", "", "",
            "", "", "", "", "", "",
            "", "", "", "", "", "", "", "", "",
            "1,38", "100", "0", "0", "20",
        ].joined(separator: ";"))
        for line in lines.dropFirst() where !line.hasPrefix("\"") {
            XCTAssertEqual(line.split(separator: ";", omittingEmptySubsequences: false).count, 34)
        }
    }

    func testNumbersUseADecimalComma() {
        XCTAssertEqual(SessionHistory.number(0.875, 2), "0,88")
        XCTAssertEqual(SessionHistory.number(12, 0), "12")
        XCTAssertEqual(SessionHistory.number(nil, 1), "")
        XCTAssertEqual(SessionHistory.number(.nan, 1), "")
        XCTAssertEqual(SessionHistory.number(7), "7")
        XCTAssertEqual(SessionHistory.number(nil as Int?), "")
        XCTAssertEqual(SessionHistory.cell("a\nb"), "\"a\nb\"")
        XCTAssertEqual(SessionHistory.cell("plain"), "plain")
    }
}
