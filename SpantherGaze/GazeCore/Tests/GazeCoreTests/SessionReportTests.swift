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

    func testCSVForARussianSpreadsheet() {
        var m = MeteorTally()
        m.add(rock(level: 1, reaction: 0.5, slips: 0, burned: true))
        m.add(rock(level: 3, reaction: 1.25, slips: 1, burned: true))
        m.add(rock(level: 3, reaction: nil, slips: 0, burned: false))
        let play = m.summary(id: "m", childCode: "К-07", start: thursday, durationSec: 252, byEye: true, calibrationErrorCm: 1.234)
        var tune = SessionSummary(id: "r", childCode: "К;\"07\"", game: .rhythm, start: wednesday, durationSec: 61,
                                  byEye: false, calibrationErrorCm: nil)
        tune.track = "Track"
        tune.rhythmLevel = "hard"
        tune.accuracy = 0.8125
        tune.notes = 4
        tune.hits = 3
        tune.perfect = 1
        tune.maxCombo = 3
        // Almaty is UTC+5.
        let csv = SessionHistory.csv([play, tune], timeZone: TimeZone(secondsFromGMT: 5 * 3600)!)
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        let lines = csv.components(separatedBy: "\r\n").dropLast()
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], SessionHistory.csvHeader.joined(separator: ";"))
        XCTAssertEqual(lines[0].split(separator: ";", omittingEmptySubsequences: false).count, 21)
        // Oldest first: the rhythm play of Wednesday, its code quoted because it holds a separator and quotes.
        XCTAssertEqual(lines[1], "\"К;\"\"07\"\"\";2026-11-11;14:00;Ритм;палец;1,0;;;;;;;;Track;hard;81;4;3;1;3;")
        XCTAssertEqual(lines[2], "К-07;2026-11-12;10:30;Метеориты;взгляд;4,2;1,23;3;2;67;0,88;0,33;3;;;;;;;;")
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
