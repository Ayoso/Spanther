import Foundation

// The session report for the specialist and the parent: one summary per finished play, kept on the phone and
// shared only through the Share button (CLAUDE.md rule 5). These are game results, not health measurements: no
// face data, no diagnosis, only what happened in the game. Times in seconds, the calibration error in cm.

/// One finished play of one child.
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public enum Game: String, Codable, Sendable { case meteors, rhythm }

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

    /// A rhythm play's results, read from its judge when the track has ended.
    public static func rhythm(id: String, childCode: String, start: Date, durationSec: Double, byEye: Bool,
                              calibrationErrorCm: Double?, track: String, level: RhythmLevel,
                              judge: RhythmJudge) -> SessionSummary {
        var s = SessionSummary(id: id, childCode: childCode, game: .rhythm, start: start, durationSec: durationSec,
                               byEye: byEye, calibrationErrorCm: calibrationErrorCm)
        s.track = track
        s.rhythmLevel = level.rawValue
        s.accuracy = judge.accuracy
        s.notes = judge.notes.count
        s.perfect = judge.count(.perfect)
        s.hits = judge.count(.perfect) + judge.count(.good) + judge.count(.ok)
        s.maxCombo = judge.maxCombo
        s.extraWinks = byEye ? judge.stray + judge.wrongEye : nil
        return s
    }
}

/// Collects the meteors of one play as they burn or reach Earth.
public struct MeteorTally: Sendable {
    public private(set) var records: [AsteroidRecord] = []

    public init() {}

    public mutating func add(_ r: AsteroidRecord) { records.append(r) }

    public var isEmpty: Bool { records.isEmpty }

    public func summary(id: String, childCode: String, start: Date, durationSec: Double, byEye: Bool,
                        calibrationErrorCm: Double?) -> SessionSummary {
        var s = SessionSummary(id: id, childCode: childCode, game: .meteors, start: start, durationSec: durationSec,
                               byEye: byEye, calibrationErrorCm: calibrationErrorCm)
        s.meteors = records.count
        s.burned = records.filter { $0.destroyed }.count
        let looks = records.compactMap { $0.reactionSec }
        s.meanFirstLookSec = looks.isEmpty ? nil : looks.reduce(0, +) / Double(looks.count)
        s.slipsPerMeteor = records.isEmpty ? nil : Double(records.reduce(0) { $0 + $1.slips }) / Double(records.count)
        s.maxLevel = records.map { $0.level }.max()
        return s
    }
}

/// The plays kept on the phone, and the spreadsheet the Share button sends.
public enum SessionHistory {
    /// The stored plays; an unreadable file gives none rather than stopping the app.
    public static func decode(_ data: Data) -> [SessionSummary] {
        (try? JSONDecoder().decode([SessionSummary].self, from: data)) ?? []
    }

    public static func encode(_ sessions: [SessionSummary]) -> Data {
        (try? JSONEncoder().encode(sessions)) ?? Data("[]".utf8)
    }

    /// The plays of one child, oldest first (all plays when the code is empty).
    public static func plays(of childCode: String, in sessions: [SessionSummary]) -> [SessionSummary] {
        let code = childCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { code.isEmpty || $0.childCode == code }.sorted { $0.start < $1.start }
    }

    /// The plays of one game that compare with its newest play: the same control (eye or finger) and, for the
    /// rhythm, the same level. Oldest first, from `plays` sorted oldest first; none when fewer than two compare.
    public static func progress(_ plays: [SessionSummary], game: SessionSummary.Game) -> [SessionSummary] {
        guard let last = plays.last(where: { $0.game == game }) else { return [] }
        let same = plays.filter {
            $0.game == game && $0.byEye == last.byEye && (game == .meteors || $0.rhythmLevel == last.rhythmLevel)
        }
        return same.count >= 2 ? same : []
    }

    static let csvHeader = [
        "Код ребёнка", "Дата", "Время", "Игра", "Управление", "Длительность, мин", "Ошибка калибровки, см",
        "Метеоритов", "Сбито", "Сбито, %", "Первый взгляд, с", "Срывы взгляда на метеорит", "Высший уровень",
        "Трек", "Уровень ритма", "Точность ритма, %", "Нот", "Сыграно нот", "Идеально", "Лучшая серия",
        "Лишние подмигивания",
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
                s.game == .meteors ? "Метеориты" : "Ритм", s.byEye ? "взгляд" : "палец",
                number(s.durationSec / 60, 1), number(s.calibrationErrorCm, 2),
            ]
            row += [
                number(s.meteors), number(s.burned), number(s.burnedShare.map { $0 * 100 }, 0),
                number(s.meanFirstLookSec, 2), number(s.slipsPerMeteor, 2), number(s.maxLevel),
            ]
            row += [
                s.track ?? "", s.rhythmLevel ?? "", number(s.accuracy.map { $0 * 100 }, 0), number(s.notes),
                number(s.hits), number(s.perfect), number(s.maxCombo), number(s.extraWinks),
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

    /// Quotes a cell that holds a separator, a quote or a line break.
    static func cell(_ s: String) -> String {
        guard s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
