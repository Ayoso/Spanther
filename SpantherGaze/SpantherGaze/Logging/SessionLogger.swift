import Foundation

/// Raw session data as CSV. Stays on the device; leaves only through the Share button (CLAUDE.md rule 5).
final class SessionLogger {
    private(set) var url: URL
    private var handle: FileHandle?

    init() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        url = FileManager.default.temporaryDirectory.appendingPathComponent("spanther-\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write("kind,time,target_x_pt,target_y_pt,gaze_x_pt,gaze_y_pt,lookat_x_m,lookat_y_m,eyeaxis_x_m,eyeaxis_y_m,yaw_rad,pitch_rad,roll_rad,distance_m,pupil_u,pupil_v,class,level,reaction_s,lifetime_s,slips,destroyed")
    }

    /// One tracked sample during calibration or the check.
    func sample(kind: String, time: Double, target: Vec2, gaze: Vec2?, f: GazeFeatures) {
        let pu = f.pupils.map { String(format: "%.5f", ($0.leftU + $0.rightU) / 2) } ?? ""
        let pv = f.pupils.map { String(format: "%.5f", ($0.leftV + $0.rightV) / 2) } ?? ""
        write([kind, fmt(time), fmt(target.x), fmt(target.y), gaze.map { fmt($0.x) } ?? "", gaze.map { fmt($0.y) } ?? "",
               fmt(f.lookAtHit.x), fmt(f.lookAtHit.y), fmt(f.eyeAxisHit.x), fmt(f.eyeAxisHit.y),
               fmt(f.yaw), fmt(f.pitch), fmt(f.roll), fmt(f.distance), pu, pv, "", "", "", "", "", ""].joined(separator: ","))
    }

    /// One asteroid outcome for the parent report.
    func asteroid(_ r: AsteroidRecord, time: Double) {
        let cells: [String] = ["asteroid", fmt(time)] + Array(repeating: "", count: 14)
            + [r.className, "\(r.level)", r.reactionSec.map(fmt) ?? "", fmt(r.lifetimeSec), "\(r.slips)", r.destroyed ? "1" : "0"]
        write(cells.joined(separator: ","))
    }

    private func fmt(_ v: Double) -> String { String(format: "%.5f", v) }
    private func write(_ line: String) { handle?.write((line + "\n").data(using: .utf8)!) }
}
