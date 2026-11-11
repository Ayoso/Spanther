import Foundation

// The session report for the specialist and the parent: one summary per finished play, kept on the phone and
// shared only through the Share button (CLAUDE.md rule 5). These are game results, not health measurements: no
// face data, no diagnosis, only what happened in the game. Times in seconds, the calibration error in cm.

/// One finished play of one child.
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public enum Game: String, Codable, Sendable { case meteors, rhythm, pursuit }

    public var id: String
    /// The code the specialist gave the child instead of a name; empty when none was set.
    public var childCode: String
    public var game: Game
    public var start: Date
    public var durationSec: Double
    /// Played by eye (false: by finger).
    public var byEye: Bool
    /// Mean error on the check screen of the calibration before this play (cm); nil when played by finger.
    public var calibrationErrorCm: Double?
    /// «Мелкие цели»: the scale the targets and their hit zones had (0.7 is 30% smaller). Nil: the regular size.
    public var targetScale: Double?

    // The four numbers of the report. Each is nil where the game does not measure it.
    /// Holding the gaze, 0...1. Meteors: the ones burned in one go, without a slip, out of those the player looked
    /// at. Warm-up: the share of the minute the gaze stayed near the target. Rhythm by eye: the winks made with the
    /// gaze on the note, out of the winks that fell in a note's window.
    public var holdShare: Double?
    /// Rhythm: how far the played notes were from the player's own mean lateness, on average (ms), and that
    /// lateness (ms; it holds the wink detector's delay, so it is context, not a result).
    public var timingDeviationMs: Double?
    public var timingOffsetMs: Double?
    /// Meteors: red signs that left the play, and how many of them the player looked at (errors).
    public var decoys: Int?
    public var decoyErrors: Int?
    /// Rhythm by eye: share of each eye's winks that played a note, 0...1; nil when that eye never winked.
    public var winkLeft: Double?
    public var winkRight: Double?

    // Warm-up.
    /// Mean distance from the gaze to the target (cm), the shares of each part with the gaze near the target
    /// (0...1), and the share of frames with no gaze point at all.
    public var pursuitMeanCm: Double?
    public var pursuitHorizontal: Double?
    public var pursuitVertical: Double?
    public var pursuitEight: Double?
    public var pursuitLostShare: Double?

    // Meteors.
    /// Meteors that left the play (burned or reached Earth), and how many of them were burned.
    public var meteors: Int?
    public var burned: Int?
    /// Mean time from a meteor's appearance to the first look at it (s), over the meteors that were looked at.
    public var meanFirstLookSec: Double?
    /// How often the gaze left a meteor long enough for its burn to run back to zero, per meteor.
    public var slipsPerMeteor: Double?
    public var maxLevel: Int?

    // Rhythm.
    public var track: String?
    public var rhythmLevel: String?
    /// Share of the best possible play, 0...1 (perfect 1, good 0.7, ok 0.4).
    public var accuracy: Double?
    public var notes: Int?
    /// Notes played (perfect, good or ok) and how many of them were perfect.
    public var hits: Int?
    public var perfect: Int?
    public var maxCombo: Int?
    /// One-eye winks that played no note: far from every note, or the wrong eye on a side note. Nil by finger.
    public var extraWinks: Int?

    public init(id: String, childCode: String, game: Game, start: Date, durationSec: Double, byEye: Bool,
                calibrationErrorCm: Double?) {
        self.id = id
        self.childCode = childCode
        self.game = game
        self.start = start
        self.durationSec = durationSec
        self.byEye = byEye
        self.calibrationErrorCm = calibrationErrorCm.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Burned meteors as a share of the meteors that left the play, 0...1.
    public var burnedShare: Double? {
        guard let m = meteors, let b = burned, m > 0 else { return nil }
        return Double(b) / Double(m)
    }

    /// The target scale as the report keeps it: nil for the regular size.
    static func kept(scale: Double?) -> Double? {
        guard let k = scale, k.isFinite, k < 0.999 else { return nil }
        return k
    }

    /// The decoy errors as a share of the red signs, 0...1.
    public var decoyErrorShare: Double? {
        guard let n = decoys, let e = decoyErrors, n > 0 else { return nil }
        return Double(e) / Double(n)
    }

    /// A rhythm play's results, read from its judge when the track has ended.
    public static func rhythm(id: String, childCode: String, start: Date, durationSec: Double, byEye: Bool,
                              calibrationErrorCm: Double?, track: String, level: RhythmLevel,
                              judge: RhythmJudge, targetScale: Double? = nil) -> SessionSummary {
        var s = SessionSummary(id: id, childCode: childCode, game: .rhythm, start: start, durationSec: durationSec,
                               byEye: byEye, calibrationErrorCm: calibrationErrorCm)
        s.targetScale = kept(scale: targetScale)
        s.track = track
        s.rhythmLevel = level.rawValue
        s.accuracy = judge.accuracy
        s.notes = judge.notes.count
        s.perfect = judge.count(.perfect)
        let hits = judge.count(.perfect) + judge.count(.good) + judge.count(.ok)
        s.hits = hits
        s.maxCombo = judge.maxCombo
        s.extraWinks = byEye ? judge.stray + judge.wrongEye : nil
        s.timingDeviationMs = judge.timingDeviationSec.map { $0 * 1000 }
        s.timingOffsetMs = judge.meanOffsetSec.map { $0 * 1000 }
        if byEye {
            // A tap is on the note or not; only a look can be held on it while the eye closes.
            let inWindow = hits + judge.offTarget
            s.holdShare = inWindow > 0 ? Double(hits) / Double(inWindow) : nil
            s.winkLeft = judge.winkAccuracy(.left)
            s.winkRight = judge.winkAccuracy(.right)
        }
        return s
    }

    /// A warm-up's results. `ptPerCm`: screen points per centimetre on this phone.
    public static func pursuit(id: String, childCode: String, start: Date, durationSec: Double, byEye: Bool,
                               calibrationErrorCm: Double?, tally: PursuitTally, ptPerCm: Double) -> SessionSummary {
        var s = SessionSummary(id: id, childCode: childCode, game: .pursuit, start: start, durationSec: durationSec,
                               byEye: byEye, calibrationErrorCm: calibrationErrorCm)
        s.holdShare = tally.all.share
        s.pursuitMeanCm = tally.meanDistancePt.map { $0 / max(1, ptPerCm) }
        s.pursuitHorizontal = tally.horizontal.share
        s.pursuitVertical = tally.vertical.share
        s.pursuitEight = tally.eight.share
        s.pursuitLostShare = tally.lostShare
        return s
    }
}

/// Collects the meteors of one play as they burn or reach Earth.
public struct MeteorTally: Sendable {
    public private(set) var records: [AsteroidRecord] = []
    /// The red signs that left the play: passed by, or looked at (an error).
    public private(set) var decoyRecords: [DecoyRecord] = []

    public init() {}

    public mutating func add(_ r: AsteroidRecord) { records.append(r) }
    public mutating func add(_ d: DecoyRecord) { decoyRecords.append(d) }

    public var isEmpty: Bool { records.isEmpty }

    public func summary(id: String, childCode: String, start: Date, durationSec: Double, byEye: Bool,
                        calibrationErrorCm: Double?, targetScale: Double? = nil) -> SessionSummary {
        var s = SessionSummary(id: id, childCode: childCode, game: .meteors, start: start, durationSec: durationSec,
                               byEye: byEye, calibrationErrorCm: calibrationErrorCm)
        s.targetScale = SessionSummary.kept(scale: targetScale)
        s.meteors = records.count
        s.burned = records.filter { $0.destroyed }.count
        let looks = records.compactMap { $0.reactionSec }
        s.meanFirstLookSec = looks.isEmpty ? nil : looks.reduce(0, +) / Double(looks.count)
        s.slipsPerMeteor = records.isEmpty ? nil : Double(records.reduce(0) { $0 + $1.slips }) / Double(records.count)
        s.maxLevel = records.map { $0.level }.max()
        // Held: looked at and burned without the burn ever running back to zero.
        let looked = records.filter { $0.reactionSec != nil }
        s.holdShare = looked.isEmpty ? nil
            : Double(looked.filter { $0.destroyed && $0.slips == 0 }.count) / Double(looked.count)
        if !decoyRecords.isEmpty {
            s.decoys = decoyRecords.count
            s.decoyErrors = decoyRecords.filter { $0.looked }.count
        }
        return s
    }
}

/// The plays kept on the phone, and the spreadsheet the Share button sends.
public enum SessionHistory {
    /// One stored play, or nothing when this build cannot read it (a game a newer build added, say).
    private struct Entry: Decodable {
        let play: SessionSummary?
        init(from decoder: Decoder) throws { play = try? SessionSummary(from: decoder) }
    }

    /// The stored plays; an unreadable file gives none rather than stopping the app, and a play this build cannot
    /// read is left out without losing the others.
    public static func decode(_ data: Data) -> [SessionSummary] {
        ((try? JSONDecoder().decode([Entry].self, from: data)) ?? []).compactMap { $0.play }
    }

    public static func encode(_ sessions: [SessionSummary]) -> Data {
        (try? JSONEncoder().encode(sessions)) ?? Data("[]".utf8)
    }

    /// The plays of one child, oldest first (all plays when the code is empty).
    public static func plays(of childCode: String, in sessions: [SessionSummary]) -> [SessionSummary] {
        let code = childCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { code.isEmpty || $0.childCode == code }.sorted { $0.start < $1.start }
    }

    /// The plays of one game that compare with its newest play: the same control (eye or finger), the same target
    /// size and, for the rhythm, the same level. Oldest first, from `plays` sorted oldest first; none when fewer
    /// than two compare.
    public static func progress(_ plays: [SessionSummary], game: SessionSummary.Game) -> [SessionSummary] {
        guard let last = plays.last(where: { $0.game == game }) else { return [] }
        let same = plays.filter {
            $0.game == game && $0.byEye == last.byEye && (game != .rhythm || $0.rhythmLevel == last.rhythmLevel)
                && (game == .pursuit || abs(($0.targetScale ?? 1) - (last.targetScale ?? 1)) < 0.005)
        }
        return same.count >= 2 ? same : []
    }

    public static func gameName(_ g: SessionSummary.Game) -> String {
        switch g {
        case .meteors: return "Метеориты"
        case .rhythm: return "Ритм"
        case .pursuit: return "Разминка"
        }
    }

    /// The play's own columns first, then the four numbers of the report, then each game's details.
    static let csvHeader = [
        "Код ребёнка", "Дата", "Время", "Игра", "Управление", "Длительность, мин", "Ошибка калибровки, см",
        "Размер целей, %",
        "Удержание взгляда, %", "Отклонение от ритма, мс", "Красных знаков", "Ошибок на красных",
        "Подмигивания левым, %", "Подмигивания правым, %",
        "Метеоритов", "Сбито", "Сбито, %", "Первый взгляд, с", "Срывы взгляда на метеорит", "Высший уровень",
        "Трек", "Уровень ритма", "Точность ритма, %", "Нот", "Сыграно нот", "Идеально", "Лучшая серия",
        "Лишние подмигивания", "Среднее опоздание, мс",
        "Разминка: до цели, см", "Разминка: горизонталь, %", "Разминка: вертикаль, %", "Разминка: восьмёрка, %",
        "Разминка: без взгляда, %",
    ]

    /// A table for a spreadsheet in a Russian locale: semicolons between cells, decimal commas, one play per row,
    /// oldest first. The caller adds a UTF-8 byte order mark so Excel reads the Cyrillic.
    public static func csv(_ sessions: [SessionSummary], timeZone: TimeZone = .current) -> String {
        let day = DateFormatter(), time = DateFormatter()
        for f in [day, time] {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
        }
        day.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HH:mm"
        var lines = [csvHeader.joined(separator: ";")]
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            var row: [String] = [
                s.childCode, day.string(from: s.start), time.string(from: s.start),
                gameName(s.game), s.byEye ? "взгляд" : "палец",
                number(s.durationSec / 60, 1), number(s.calibrationErrorCm, 2),
                number((s.targetScale ?? 1) * 100, 0),
            ]
            row += [
                percent(s.holdShare), number(s.timingDeviationMs, 0), number(s.decoys), number(s.decoyErrors),
                percent(s.winkLeft), percent(s.winkRight),
            ]
            row += [
                number(s.meteors), number(s.burned), percent(s.burnedShare),
                number(s.meanFirstLookSec, 2), number(s.slipsPerMeteor, 2), number(s.maxLevel),
            ]
            row += [
                s.track ?? "", s.rhythmLevel ?? "", percent(s.accuracy), number(s.notes),
                number(s.hits), number(s.perfect), number(s.maxCombo), number(s.extraWinks),
                number(s.timingOffsetMs, 0),
            ]
            row += [
                number(s.pursuitMeanCm, 2), percent(s.pursuitHorizontal), percent(s.pursuitVertical),
                percent(s.pursuitEight), percent(s.pursuitLostShare),
            ]
            lines.append(row.map(cell).joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A decimal number with a comma, as Russian writes it; empty when missing.
    public static func number(_ v: Double?, _ digits: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    static func number(_ v: Int?) -> String { v.map(String.init) ?? "" }

    /// A share 0...1 as whole percent, without the sign (the column's name has it); empty when missing.
    static func percent(_ v: Double?) -> String { number(v.map { $0 * 100 }, 0) }

    /// Quotes a cell that holds a separator, a quote or a line break.
    static func cell(_ s: String) -> String {
        guard s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
