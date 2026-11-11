import Foundation

/// The plays kept on the phone, in Application Support/sessions.json. They are game results with the child's code,
/// no face data. They leave the phone only as the table the Share button sends (CLAUDE.md rule 5).
enum SessionStore {
    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sessions.json")
    }

    static func load() -> [SessionSummary] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return SessionHistory.decode(data)
    }

    /// A few hundred plays are tens of kilobytes, written when a play ends, never during one.
    static func save(_ sessions: [SessionSummary]) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SessionHistory.encode(sessions).write(to: url, options: .atomic)
    }

    /// The table of all plays for the Share button: a temporary file named by today's date, with a byte order mark
    /// so that Excel reads the Cyrillic. In its own folder, apart from the session CSVs the CI test looks for.
    static func exportCSV(_ sessions: [SessionSummary]) -> URL? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return write(sessions, name: "spanther-sessions-\(day.string(from: Date())).csv")
    }

    /// The table of one play, for the Share button on its summary: the same columns as the table of all plays (the
    /// date and time, the game, how it was played, the four numbers of the report and the game's own results) and
    /// one row. Named by the game and the time the play started.
    static func exportCSV(play s: SessionSummary) -> URL? {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        return write([s], name: "spanther-\(s.game.rawValue)-\(stamp.string(from: s.start)).csv")
    }

    private static func write(_ sessions: [SessionSummary], name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("report", isDirectory: true)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (Data("\u{FEFF}".utf8) + Data(SessionHistory.csv(sessions).utf8)).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
