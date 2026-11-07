import Foundation
import GazeCore

// Replays a session CSV exported from the app (menu: «Экспорт CSV последней сессии») through the current GazeCore
// code, so tracking changes are compared on the same recordings (CLAUDE.md rule 7):
//
//   cd SpantherGaze/GazeCore && swift run GazeReplay ~/Downloads/spanther-2026-11-05_01-13-16.csv
//
// For each feature set it fits the calibration model the way the app does, replays the check screen and the game
// frames, and prints the check error, how often the aim is off the screen in each level, and how often the player
// counted as looking away. It also replays the blink detector over the game frames and compares it with the blinks
// and reloads the app logged. The app is not in this package, so the replay copies two of its rules:
// a calibration dot with fewer than 20 frames is repeated and its frames are dropped, and frames with the gaze held
// for a blink keep the previous point.
//
// Session CSVs are face data: keep them out of the repository (CLAUDE.md rule 5).

struct Row {
    let kind: String
    let time: Double
    let cells: [String: String]
    func d(_ key: String) -> Double? { cells[key].flatMap { $0.isEmpty ? nil : Double($0) } }
}

func readRows(_ path: String) throws -> [Row] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else { return [] }
    let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    return lines.compactMap { line in
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == header.count, let t = Double(parts[1]) else { return nil }
        return Row(kind: parts[0], time: t, cells: Dictionary(uniqueKeysWithValues: zip(header, parts)))
    }
}

/// Screen pt -> features, the inverse of what SessionLogger.sample writes. Pupils were logged as the two eyes'
/// average, which is all the model uses.
func features(_ r: Row) -> GazeFeatures? {
    guard let lx = r.d("lookat_x_m"), let ly = r.d("lookat_y_m"),
          let ex = r.d("eyeaxis_x_m"), let ey = r.d("eyeaxis_y_m") else { return nil }
    var pupils: PupilOffsets?
    if let u = r.d("pupil_u"), let v = r.d("pupil_v") { pupils = PupilOffsets(leftU: u, leftV: v, rightU: u, rightV: v) }
    return GazeFeatures(lookAtHit: Vec2(lx, ly), eyeAxisHit: Vec2(ex, ey), yaw: r.d("yaw_rad") ?? 0,
                        pitch: r.d("pitch_rad") ?? 0, roll: r.d("roll_rad") ?? 0, distance: r.d("distance_m") ?? 0,
                        pupils: pupils)
}

func target(_ r: Row) -> Vec2? {
    guard let x = r.d("target_x_pt"), let y = r.d("target_y_pt") else { return nil }
    return Vec2(x, y)
}

/// Calibration rows grouped into dot attempts. Each attempt collects for 1 s after a 0.7 s settle
/// (CalibrationView), so a gap over 0.65 s or a run over 1.1 s starts a new attempt.
func calibrationAttempts(_ rows: [Row]) -> [(target: Vec2, rows: [Row])] {
    var out: [(target: Vec2, rows: [Row])] = []
    for r in rows where r.kind == "calibration" {
        guard let t = target(r) else { continue }
        if let last = out.last, last.target == t, let prev = last.rows.last,
           r.time - prev.time <= 0.65, r.time - last.rows[0].time <= 1.1 {
            out[out.count - 1].rows.append(r)
        } else {
            out.append((t, [r]))
        }
    }
    return out
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "  -" : String(format: "%3.0f", Double(a) / Double(b) * 100) }

guard CommandLine.arguments.count >= 2 else {
    print("usage: swift run GazeReplay <session.csv>")
    exit(2)
}
let rows = try readRows(CommandLine.arguments[1])

// Wink test runs (menu: «Тест подмигиваний»): the wink detector replayed over the raw eyelid values at three close
// thresholds, plus each eye's peak around every cue, which does not depend on any threshold.
let winkFrames = rows.filter { $0.kind == "wink_frame" }
if !winkFrames.isEmpty {
    let cueRows = rows.filter { $0.kind == "cue" }
    let cues = cueRows.compactMap { r -> (cue: WinkTestPlan.Cue, time: Double)? in
        guard let side = WinkSide(rawValue: r.cells["side"] ?? "") else { return nil }
        return (WinkTestPlan.Cue(side: side, offset: 0, block: 0), r.time)
    }
    let latency = rows.first { $0.kind == "wink_test" }?.d("audio_latency_s") ?? 0
    print("Wink test: \(rows.filter { $0.kind == "wink_test" }.count) run(s), \(cues.count) cues, "
          + "\(rows.filter { $0.kind == "wink" }.count) closures logged by the app, \(winkFrames.count) frames, "
          + String(format: "audio latency %.0f ms", latency * 1000))
    func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    func p90(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.9))] }
    for side in [WinkSide.left, .right] {
        var asked: [Double] = [], other: [Double] = []
        for c in cues where c.cue.side == side {
            let near = winkFrames.filter { abs($0.time - c.time) <= 0.45 }
            let l = near.compactMap { $0.d("blink_l") }.max() ?? .nan, r = near.compactMap { $0.d("blink_r") }.max() ?? .nan
            asked.append(side == .left ? l : r)
            other.append(side == .left ? r : l)
        }
        print("  \(side.rawValue) cues: " + String(format: "asked eye peak median %.2f (lowest %.2f), other eye peak median %.2f (p90 %.2f)",
                                                    median(asked), asked.min() ?? .nan, median(other), p90(other)))
    }
    print("  close  | left: hits wrong both  mean   sd  ±100/180/250 other | right: hits wrong both  mean   sd  ±100/180/250 other | stray wink blink")
    for threshold in [0.5, 0.6, 0.7] {
        var config = WinkConfig()
        config.closeThreshold = threshold
        var detector = WinkDetector(config)
        var events: [WinkEvent] = []
        var last: Double?
        for r in winkFrames {
            guard let l = r.d("blink_l"), let rr = r.d("blink_r") else { continue }
            if let t = last, r.time - t > 0.2 { detector.faceLost() }
            last = r.time
            if let e = detector.update(time: r.time, left: l, right: rr) { events.append(e) }
        }
        let s = WinkStats.compute(cues: cues.map(\.cue), beats: cues.map(\.time), events: events)
        func eye(_ e: WinkStats.Eye) -> String {
            String(format: "%2d/%-2d %4d %4d %+5.0f %4.0f  %2d/%2d/%2d    %.2f",
                   e.hits, e.cues, e.wrongEye, e.bothEyes, e.meanOffsetMs, e.sdOffsetMs,
                   e.within100, e.within180, e.within250, e.medianOtherPeak)
        }
        print(String(format: "  %.1f    | ", threshold) + eye(s.left) + " | " + eye(s.right)
              + String(format: " | %4d %5d", s.strayOneEye, s.strayBoth))
    }
    print("")
}
let attempts = calibrationAttempts(rows)
let used = attempts.filter { $0.rows.count >= 20 }
let checkRows = rows.filter { $0.kind == "check" }
let frameRows = rows.filter { $0.kind == "frame" }
let targets = used.map(\.target)
guard let minX = targets.map(\.x).min(), let maxX = targets.map(\.x).max(),
      let minY = targets.map(\.y).min(), let maxY = targets.map(\.y).max(), maxX > minX, maxY > minY else {
    print("no usable calibration in this file")
    exit(winkFrames.isEmpty ? 1 : 0)
}
// Calibration dots sit at 10% and 90% of the screen.
let screen = Vec2((maxX - minX) / 0.8, (maxY - minY) / 0.8)
let levelStarts = rows.filter { $0.kind == "level" }.compactMap { r in r.d("level").map { (r.time, Int($0)) } }
func level(at t: Double) -> Int { levelStarts.last(where: { $0.0 <= t })?.1 ?? 1 }
let levels = Array(Set(frameRows.map { level(at: $0.time) })).sorted()
let distances = checkRows.compactMap { $0.d("distance_m") }
let distanceCm = distances.isEmpty ? 30 : distances.reduce(0, +) / Double(distances.count) * 100
let tracked = rows.filter { ["calibration", "check", "frame"].contains($0.kind) }.map(\.time)
let gaps = zip(tracked, tracked.dropFirst()).map { $1 - $0 }.filter { $0 > 0 && $0 < 0.2 }.sorted()

print("\(rows.count) rows: \(used.count) calibration dots (\(attempts.count - used.count) repeated), "
      + "\(checkRows.count) check frames, \(frameRows.count) game frames in levels \(levels.map(String.init).joined(separator: ", ")).")
print(String(format: "Screen %.0f x %.0f pt, tracking at %.0f fps, check distance %.1f cm.",
             screen.x, screen.y, gaps.isEmpty ? 0 : 1 / gaps[gaps.count / 2], distanceCm))
// Camera format and device state (`tracking` rows) and frame processing time; files from before they were
// logged have neither.
for r in rows where r.kind == "tracking" {
    let lowPower = r.cells["low_power"] == "1" ? ", Low Power Mode on" : ""
    // Screen and Vision orientation: files from before landscape (2026-11-05) are portrait and leftMirrored.
    let screen = r.cells["screen_orientation"].map { $0.isEmpty ? "" : ", screen " + $0 } ?? ""
    let vision = r.cells["vision_orientation"].map { $0.isEmpty ? "" : ", Vision " + $0 } ?? ""
    print(String(format: "At %.1f s: camera ", r.time) + (r.cells["video_format"] ?? "?")
          + ", offered " + (r.cells["formats_offered"] ?? "?") + ", thermal " + (r.cells["thermal"] ?? "?") + lowPower
          + screen + vision + ".")
}
let processing = rows.compactMap { $0.d("proc_ms") }.sorted()
if !processing.isEmpty {
    print(String(format: "Frame processing: median %.2f ms, 95th percentile %.2f ms.",
                 processing[processing.count / 2], processing[(processing.count - 1) * 95 / 100]))
}
print("")
print("Off screen = aim more than 1 cm (60 pt) outside the screen while the player was not blinking.")
print("feature set     check cm  jitter cm | off screen % by level: " + levels.map { String(format: "%3d", $0) }.joined(separator: " ")
      + "  all | looking away %")
for set in GazeFeatures.FeatureSet.allCases {
    var X: [[Double]] = [], Y: [Vec2] = []
    for a in used { for r in a.rows { if let f = features(r) { X.append(f.vector(set)); Y.append(a.target) } } }
    guard let model = RidgeModel.fit(features: X, targets: Y, lambda: 0.01, featureSet: set.rawValue) else {
        print("\(set.rawValue): fit failed"); continue
    }
    func step(_ f: GazeFeatures, _ t: Double, _ filter: inout OneEuroFilter2D) -> Vec2? {
        let v = f.vector(set)
        if model.outOfRange(v, features: 0..<2, margin: RidgeModel.lookingAwayMargin) { filter.reset(); return nil }
        return filter.filter(model.predict(v), t: t)
    }

    var filter = OneEuroFilter2D()
    var byTarget: [(target: Vec2, predictions: [Vec2])] = []
    for r in checkRows {
        guard let f = features(r), let t = target(r) else { continue }
        if byTarget.last?.target != t { byTarget.append((t, [])) }
        if let p = step(f, r.time, &filter) { byTarget[byTarget.count - 1].predictions.append(p) }
    }
    let report = Metrics.report(samples: byTarget, ptPerCm: 60, viewingDistanceCm: distanceCm)

    filter = OneEuroFilter2D()
    var total: [Int: Int] = [:], off: [Int: Int] = [:], away: [Int: Int] = [:]
    for r in frameRows where r.cells["hold"] != "1" {
        guard let f = features(r) else { continue }
        let l = level(at: r.time)
        total[l, default: 0] += 1
        guard let p = step(f, r.time, &filter) else { away[l, default: 0] += 1; continue }
        if p.x < -60 || p.x > screen.x + 60 || p.y < -60 || p.y > screen.y + 60 { off[l, default: 0] += 1 }
    }
    let all = total.values.reduce(0, +)
    print(set.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
          + String(format: " %8.2f %10.2f", report.meanErrorCm, report.jitterCm) + " |                        "
          + levels.map { pct(off[$0] ?? 0, total[$0] ?? 0) }.joined(separator: " ")
          + "  " + pct(off.values.reduce(0, +), all) + " | " + pct(away.values.reduce(0, +), all))
}

// Blink detector over the game frames, with the energy settings from balance.json next to this package.
let balanceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SpantherGaze/Resources/balance.json")
let energy = (try? BalanceConfig.load(from: Data(contentsOf: balanceURL)))?.energy ?? EnergyConfig()
var detector = BlinkDetector(energy)
var blinks = 0, reloads = 0, held = 0
var lastTime: Double?
for r in frameRows {
    guard let l = r.d("blink_l"), let rr = r.d("blink_r") else { continue }
    // A gap in the frames is a lost face for the app as well.
    if let last = lastTime, r.time - last > 0.2 { detector.faceLost() }
    lastTime = r.time
    let u = detector.update(time: r.time, left: l, right: rr)
    if u.blinkEnded != nil { blinks += 1 }
    if u.reload { reloads += 1 }
    if u.freezeGaze { held += 1 }
}
let loggedBlinks = rows.filter { $0.kind == "blink" }.count
let loggedReloads = rows.filter { $0.kind == "reload" }.count
print("")
print("Blinks: replay \(blinks), app logged \(loggedBlinks). Reloads: replay \(reloads), app logged \(loggedReloads) "
      + "(the app also counts taps in touch mode). Gaze held on \(pct(held, frameRows.count))% of game frames.")

// Aim adapter (GazeAdapter), replayed online over the moments the game knew where the player looked: `label` rows
// (check dots, start stars and rhythm notes; their gaze is the model's raw prediction) and eye-game `frame` rows with
// a target (the meteor being burned; the raw prediction is refitted here, at the app's weight of 1/20 a frame).
// Each label is scored with what was learned before it, so the columns compare the aim without and with the
// correction on the same moments, split by how far the head's pitch was from the calibration's.
let poseRows = used.flatMap(\.rows).compactMap(features)
if let reference = HeadPose.mean(poseRows) {
    let set: GazeFeatures.FeatureSet = poseRows.contains { $0.pupils != nil } ? .eyesAndPupils : .eyes
    var X: [[Double]] = [], Y: [Vec2] = []
    for a in used { for r in a.rows { if let f = features(r) { X.append(f.vector(set)); Y.append(a.target) } } }
    let model = RidgeModel.fit(features: X, targets: Y, lambda: 0.01, featureSet: set.rawValue)
    struct Label { let time: Double; let source: String; let raw: Vec2; let target: Vec2; let pose: HeadPose; let weight: Double }
    var labels: [Label] = []
    for r in rows {
        guard let t = target(r) else { continue }
        if r.kind == "label", let x = r.d("gaze_x_pt"), let y = r.d("gaze_y_pt") {
            labels.append(Label(time: r.time, source: r.cells["label_src"] ?? "?", raw: Vec2(x, y), target: t,
                                pose: HeadPose(pitch: r.d("pitch_rad") ?? 0, yaw: r.d("yaw_rad") ?? 0), weight: 1))
        } else if r.kind == "frame", r.cells["hold"] != "1", let m = model, let f = features(r) {
            let v = f.vector(set)
            guard !m.outOfRange(v, features: 0..<2, margin: RidgeModel.lookingAwayMargin) else { continue }
            labels.append(Label(time: r.time, source: "meteor", raw: m.predict(v), target: t, pose: HeadPose(f), weight: 1.0 / 20))
        }
    }
    if !labels.isEmpty {
        var adapter = GazeAdapter(reference: reference)
        // [source or pitch bin: (weight, error without, error with)]
        var bySource: [String: (Double, Double, Double)] = [:], byPitch: [String: (Double, Double, Double)] = [:]
        for l in labels.sorted(by: { $0.time < $1.time }) {
            let without = l.raw.distance(to: l.target), with = adapter.correct(l.raw, pose: l.pose).distance(to: l.target)
            let deg = abs(l.pose.pitch - reference.pitch) * 180 / Double.pi
            let bin = deg < 3 ? "pitch within 3°" : deg < 6 ? "pitch 3-6° off" : "pitch over 6° off"
            for key in [l.source] {
                let s = bySource[key] ?? (0, 0, 0)
                bySource[key] = (s.0 + l.weight, s.1 + l.weight * without, s.2 + l.weight * with)
            }
            let p = byPitch[bin] ?? (0, 0, 0)
            byPitch[bin] = (p.0 + l.weight, p.1 + l.weight * without, p.2 + l.weight * with)
            adapter.learn(raw: l.raw, target: l.target, pose: l.pose, time: l.time, weight: l.weight)
        }
        print("")
        print("Aim adapter, each label scored before it is learned: mean distance to the target (cm), without -> with.")
        for (name, s) in bySource.sorted(by: { $0.key < $1.key }) + byPitch.sorted(by: { $0.key < $1.key }) {
            print(name.padding(toLength: 18, withPad: " ", startingAt: 0)
                  + String(format: " %6.1f labels  %5.2f -> %5.2f cm", s.0, s.1 / s.0 / 60, s.2 / s.0 / 60))
        }
        print("Learned \(adapter.learned), left out \(adapter.rejected) as too far from the aim.")
    }
}
