import Foundation

/// Raw session data as CSV. Stays on the device; leaves only through the Share button (CLAUDE.md rule 5).
final class SessionLogger {
    /// CSV columns in file order. The header is built from these names, so a row cannot shift its cells.
    enum Column: String, CaseIterable {
        case kind, time
        case targetX = "target_x_pt", targetY = "target_y_pt", gazeX = "gaze_x_pt", gazeY = "gaze_y_pt"
        case lookAtX = "lookat_x_m", lookAtY = "lookat_y_m", eyeAxisX = "eyeaxis_x_m", eyeAxisY = "eyeaxis_y_m"
        case yaw = "yaw_rad", pitch = "pitch_rad", roll = "roll_rad", distance = "distance_m"
        case pupilU = "pupil_u", pupilV = "pupil_v"
        case className = "class", level, reaction = "reaction_s", lifetime = "lifetime_s", slips, destroyed
        case blinkSec = "blink_s", energy, blinkLeft = "blink_l", blinkRight = "blink_r", hold
        // Added after the first iPhone session; readers find columns by name, so older files still read.
        case processingMs = "proc_ms"
        case videoFormat = "video_format", formatsOffered = "formats_offered", thermal, lowPower = "low_power"
    }

    /// One CSV line. Cells that are not set stay empty. Built one cell at a time: long array literals of
    /// optionals are too slow for the Swift type checker and broke the build once.
    struct Row {
        private static let position: [Column: Int] = {
            var p: [Column: Int] = [:]
            for (i, c) in Column.allCases.enumerated() { p[c] = i }
            return p
        }()
        private var cells = [String](repeating: "", count: Column.allCases.count)

        init(kind: String, time: Double) {
            self[.kind] = kind
            set(.time, time)
        }

        subscript(_ c: Column) -> String {
            get { cells[Row.position[c]!] }
            set { cells[Row.position[c]!] = newValue }
        }

        mutating func set(_ c: Column, _ v: Double?) {
            if let v { self[c] = String(format: "%.5f", v) } else { self[c] = "" }
        }

        mutating func set(_ c: Column, _ v: Int?) {
            if let v { self[c] = String(v) } else { self[c] = "" }
        }

        var line: String { cells.joined(separator: ",") }
    }

    private(set) var url: URL
    private var handle: FileHandle?

    init() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        url = FileManager.default.temporaryDirectory.appendingPathComponent("spanther-\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write(Column.allCases.map { $0.rawValue }.joined(separator: ","))
    }

    /// One tracked sample: `calibration` / `check` rows have a target, `frame` rows (every tracked frame of an
    /// eye-controlled game) do not. Raw eyeBlink values and the gaze-hold flag let blink thresholds be replayed
    /// offline on the same session (CLAUDE.md rule 7). Target and gaze in screen pt, hits in metres.
    /// `processingMs` is the tracking queue's time for the frame (CLAUDE.md rule 4).
    func sample(kind: String, time: Double, target: Vec2?, gaze: Vec2?, f: GazeFeatures,
                blink: (left: Double, right: Double)?, hold: Bool, processingMs: Double? = nil) {
        var r = Row(kind: kind, time: time)
        r.set(.targetX, target?.x)
        r.set(.targetY, target?.y)
        r.set(.gazeX, gaze?.x)
        r.set(.gazeY, gaze?.y)
        r.set(.lookAtX, f.lookAtHit.x)
        r.set(.lookAtY, f.lookAtHit.y)
        r.set(.eyeAxisX, f.eyeAxisHit.x)
        r.set(.eyeAxisY, f.eyeAxisHit.y)
        r.set(.yaw, f.yaw)
        r.set(.pitch, f.pitch)
        r.set(.roll, f.roll)
        r.set(.distance, f.distance)
        if let p = f.pupils {
            r.set(.pupilU, (p.leftU + p.rightU) / 2)
            r.set(.pupilV, (p.leftV + p.rightV) / 2)
        }
        r.set(.blinkLeft, blink?.left)
        r.set(.blinkRight, blink?.right)
        r[.hold] = hold ? "1" : "0"
        r.set(.processingMs, processingMs)
        write(r.line)
    }

    /// A `tracking` row: the camera format the session runs, the formats the device offers, the thermal state
    /// and Low Power Mode. Written when a session starts and whenever the thermal state or Low Power Mode
    /// changes, so a session's frame rate can be explained from its CSV. The format strings hold no commas.
    func tracking(format: String, offered: String, thermal: String, lowPower: Bool, time: Double) {
        var r = Row(kind: "tracking", time: time)
        r[.videoFormat] = format
        r[.formatsOffered] = offered
        r[.thermal] = thermal
        r[.lowPower] = lowPower ? "1" : "0"
        write(r.line)
    }

    /// One asteroid outcome for the parent report.
    func asteroid(_ a: AsteroidRecord, time: Double) {
        var r = Row(kind: "asteroid", time: time)
        r[.className] = a.className
        r.set(.level, a.level)
        r.set(.reaction, a.reactionSec)
        r.set(.lifetime, a.lifetimeSec)
        r.set(.slips, a.slips)
        r[.destroyed] = a.destroyed ? "1" : "0"
        write(r.line)
    }

    /// A blink (`blink`, with its closed time) or a game event (`energy` per kill, `reload`, `level`, `restart`,
    /// with the energy after it and the level). Blink rows let the thresholds be tuned on recorded sessions
    /// (CLAUDE.md rule 7); level rows explain the pool refills at each new level.
    func event(kind: String, time: Double, blinkSec: Double? = nil, energy: Int? = nil, level: Int? = nil) {
        var r = Row(kind: kind, time: time)
        r.set(.level, level)
        r.set(.blinkSec, blinkSec)
        r.set(.energy, energy)
        write(r.line)
    }

    private func write(_ line: String) { handle?.write((line + "\n").data(using: .utf8)!) }
}
