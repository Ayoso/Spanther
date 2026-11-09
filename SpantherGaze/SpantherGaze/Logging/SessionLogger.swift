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
        case screenOrientation = "screen_orientation", visionOrientation = "vision_orientation"
        // Wink test, the groundwork for the rhythm mode.
        case side, otherPeak = "other_peak", decisionMs = "decision_ms", period = "period_s", audioLatency = "audio_latency_s"
        // Rhythm mode and the aim adapter.
        case track, rhythmLevel = "rhythm_level", note, judgement, offset = "offset_s", aim = "aim_pt"
        case labelSource = "label_src", accepted, corrX = "corr_x_pt", corrY = "corr_y_pt"
        case score, accuracy, latency = "latency_s"
        // The rhythm mode's target lock: the note index the hidden aim is locked on, -1 for the start star.
        case locked
        // Night vision (tracking rows: 1 on), the light ARKit estimates on each frame (lumens, about 1000 in a lit
        // room), and the rhythm play's distractions (their kind).
        case night, light = "light_lm", distraction
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
    /// `correction`: what the aim adapter added to the model's prediction on this frame (screen pt); the gaze
    /// column has it in. In `frame` rows the target is the meteor the game took as looked at, if any.
    /// `locked`: in `rhythm_frame` rows, the note the aim is locked on (-1 the start star, empty none).
    func sample(kind: String, time: Double, target: Vec2?, gaze: Vec2?, f: GazeFeatures,
                blink: (left: Double, right: Double)?, hold: Bool, processingMs: Double? = nil, correction: Vec2? = nil,
                locked: Int? = nil, light: Double? = nil) {
        var r = Row(kind: kind, time: time)
        r.set(.locked, locked)
        r.set(.light, light)
        r.set(.corrX, correction?.x)
        r.set(.corrY, correction?.y)
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
    func tracking(format: String, offered: String, thermal: String, lowPower: Bool, screen: String, vision: String,
                  night: Bool, time: Double) {
        var r = Row(kind: "tracking", time: time)
        r[.night] = night ? "1" : "0"
        r[.videoFormat] = format
        r[.formatsOffered] = offered
        r[.thermal] = thermal
        r[.lowPower] = lowPower ? "1" : "0"
        r[.screenOrientation] = screen
        r[.visionOrientation] = vision
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

    /// Wink test rows. `wink_test`: a run starts at `time` (its first click), with the click period and the audio
    /// output latency the clicks were moved earlier by. `cue`: a beat that asks for a wink (time = the beat, side =
    /// the eye asked). `wink`: a closure the detector reported (time = its onset, side, the other eye's peak and the
    /// time until the side was known). The test's frames are `wink_frame` sample rows with the raw eyeBlink values,
    /// so other thresholds can be replayed on the same run (CLAUDE.md rule 7).
    func winkTest(time: Double, periodSec: Double, audioLatency: Double) {
        var r = Row(kind: "wink_test", time: time)
        r.set(.period, periodSec)
        r.set(.audioLatency, audioLatency)
        write(r.line)
    }

    func cue(side: WinkSide, time: Double) {
        var r = Row(kind: "cue", time: time)
        r[.side] = side.rawValue
        write(r.line)
    }

    func wink(_ e: WinkEvent) {
        var r = Row(kind: "wink", time: e.onset)
        r[.side] = e.side.rawValue
        r.set(.otherPeak, e.otherPeak)
        r.set(.decisionMs, (e.decided - e.onset) * 1000)
        write(r.line)
    }

    /// Rhythm mode. `rhythm_start`: the music's first sample is heard at `time`; the row has the track, the level,
    /// the beat length, the audio route latency, the wink delay the judge starts from and the number of notes.
    func rhythmStart(time: Double, track: String, level: String, beatSec: Double, audioLatency: Double,
                     latency: Double, notes: Int) {
        var r = Row(kind: "rhythm_start", time: time)
        r[.track] = track
        r[.rhythmLevel] = level
        r.set(.period, beatSec)
        r.set(.audioLatency, audioLatency)
        r.set(.latency, latency)
        r.set(.note, notes)
        write(r.line)
    }

    /// `note_hit` (time = the closure's onset) or `note_miss` (time = when its window closed): the note's index, its
    /// spot (screen pt), the judgement, closure minus note time (s, track clock), how far the aim was from the note
    /// (pt), the eye and the note the aim was locked on then (a locked note counts as aimed at).
    func rhythmNote(hit: Bool, time: Double, index: Int, target: Vec2, judgement: String, offset: Double?,
                    aimDistance: Double?, side: String?, locked: Int? = nil) {
        var r = Row(kind: hit ? "note_hit" : "note_miss", time: time)
        r.set(.locked, locked)
        r.set(.note, index)
        r.set(.targetX, target.x)
        r.set(.targetY, target.y)
        r[.judgement] = judgement
        r.set(.offset, offset)
        r.set(.aim, aimDistance)
        r[.side] = side ?? ""
        write(r.line)
    }

    /// `note_reject`: an eye closure that landed in a note's window but could not play it (time = its onset):
    /// the note, the reason (judgement column: `blink` both eyes where one is needed, `wrongEye`), the eye, and
    /// how far it was from the note's expected time (offset column, s).
    func rhythmReject(time: Double, index: Int, reason: String, side: String, distance: Double) {
        var r = Row(kind: "note_reject", time: time)
        r.set(.note, index)
        r[.judgement] = reason
        r[.side] = side
        r.set(.offset, distance)
        write(r.line)
    }

    /// `distraction`: a distraction of the rhythm play began (time = host time), its kind and where it started
    /// (screen pt), so a replay can see whether the gaze went to it.
    func distraction(time: Double, kind: String, at p: Vec2?) {
        var r = Row(kind: "distraction", time: time)
        r[.distraction] = kind
        r.set(.targetX, p?.x)
        r.set(.targetY, p?.y)
        write(r.line)
    }

    /// `rhythm_end`: score, accuracy (0...1) and the wink delay the judge learned.
    func rhythmEnd(time: Double, score: Int, accuracy: Double, latency: Double) {
        var r = Row(kind: "rhythm_end", time: time)
        r.set(.score, score)
        r.set(.accuracy, accuracy)
        r.set(.latency, latency)
        write(r.line)
    }

    /// `label`: a moment the game knows where the player looked (`target`, screen pt), taught to the aim adapter.
    /// gaze = the model's raw prediction then (screen pt, before the correction), with the head pose; accepted = 0
    /// when the adapter left it out as too far from the aim; corr = the correction for that pose after it.
    func label(time: Double, source: String, target: Vec2, raw: Vec2, pitch: Double, yaw: Double, accepted: Bool,
               correction: Vec2) {
        var r = Row(kind: "label", time: time)
        r[.labelSource] = source
        r.set(.targetX, target.x)
        r.set(.targetY, target.y)
        r.set(.gazeX, raw.x)
        r.set(.gazeY, raw.y)
        r.set(.pitch, pitch)
        r.set(.yaw, yaw)
        r[.accepted] = accepted ? "1" : "0"
        r.set(.corrX, correction.x)
        r.set(.corrY, correction.y)
        write(r.line)
    }

    private func write(_ line: String) { handle?.write((line + "\n").data(using: .utf8)!) }
}
