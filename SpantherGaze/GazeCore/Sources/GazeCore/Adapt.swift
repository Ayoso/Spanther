import Foundation

/// Head pose as seen from the camera (radians), the part of `GazeFeatures` that changes when the phone is tilted
/// or turned in the hands. Pitch turns about the screen's horizontal axis, yaw about its vertical one.
public struct HeadPose: Equatable, Sendable {
    public var pitch: Double
    public var yaw: Double
    public init(pitch: Double, yaw: Double) { self.pitch = pitch; self.yaw = yaw }
    public init(_ f: GazeFeatures) { self.init(pitch: f.pitch, yaw: f.yaw) }

    /// Mean pose of a set of frames, for example the calibration's.
    public static func mean(_ fs: [GazeFeatures]) -> HeadPose? {
        guard !fs.isEmpty else { return nil }
        let n = Double(fs.count)
        return HeadPose(pitch: fs.map(\.pitch).reduce(0, +) / n, yaw: fs.map(\.yaw).reduce(0, +) / n)
    }
}

public struct GazeAdapterConfig: Equatable, Sendable {
    /// Old evidence loses half its weight every `halfLifeSec` seconds, so the correction follows a grip that
    /// changes during a game.
    public var halfLifeSec = 15.0
    /// Scatter of one label around the real gaze point (pt): how far one label is trusted against the prior.
    /// About the check error of a good calibration (0.7 cm at 60 pt/cm).
    public var labelNoisePt = 45.0
    /// How far the model's aim follows a turn of the head against the phone, as a share of the head's own turn
    /// projected onto the screen (distance × angle). The tilt terms start from this, so a new tilt is corrected
    /// before any label at that tilt arrives. In Aziz's rhythm session on 2026-11-07 (iPhone 13, landscape, 27 cm)
    /// the raw aim moved 36-47 pt per degree of head pitch, a share of 1.25-1.6, and about 0.7 per degree of yaw
    /// (little yaw, so a rough figure): the eyes stay on the note, but the lookAt and eye-axis hits move with the
    /// head, and the calibration's gain scales that up. The defaults stay below those numbers; labels refine them.
    public var followPitch = 1.0
    public var followYaw = 0.5
    /// Screen points per metre (60 pt per cm), to turn the projected head turn into points.
    public var ptPerMetre = 6000.0
    /// Prior spread of the bias (pt) and of the tilt terms around their starting values (pt per radian of head
    /// pitch or yaw).
    public var priorBiasPt = 60.0
    public var priorSlopePtPerRad = 1000.0
    /// A label further than this from both the corrected and the raw aim was not where the player looked, so it is
    /// not learned.
    public var gatePt = 180.0
    /// The correction never moves the aim further than this.
    public var maxCorrectionPt = 300.0
    public init() {}
}

/// Keeps the calibrated aim on target after the phone is held differently, without refitting the ridge model.
///
/// In the first iPhone sessions the aim slid away when the phone was tilted after calibration: the ridge model is
/// fitted at one grip, and the lookAt hits and pupil offsets it reads shift a little with the head's angle to the
/// camera. This adds a small correction on top of the model's prediction (screen pt), learned from moments when the
/// game knows where the player is looking: a rhythm note winked on the beat, a meteor being burned, the check dots.
///
/// correction = b + B · (pose - calibration pose), for each screen axis. `b` absorbs a slow drift, `B` how the aim
/// moves with tilt, so a new tilt is corrected before the next label arrives. It is a ridge regression on the
/// residuals with exponential forgetting: each fit uses all labels so far, weighted by age, plus a prior that keeps
/// `b` at zero and `B` at the measured follow (see `followPitch`) until there is evidence. Labels seldom arrive at
/// different tilts (players hold still while they aim), so `B` mostly comes from that prior.
public struct GazeAdapter: Sendable {
    public let config: GazeAdapterConfig
    /// The calibration's mean head pose.
    public let reference: HeadPose
    /// Weighted sums: S = Σ w·φφᵀ (3x3, row-major), sx = Σ w·φ·rx, sy = Σ w·φ·ry, with φ = (1, Δpitch, Δyaw).
    private var S = [Double](repeating: 0, count: 9)
    private var sx = [0.0, 0.0, 0.0], sy = [0.0, 0.0, 0.0]
    /// Fitted terms (b, B_pitch, B_yaw) for screen x and y.
    public private(set) var wx: [Double], wy: [Double]
    /// The prior's values of those terms: no bias, and the aim's measured follow of the head turned against it.
    public let priorX: [Double], priorY: [Double]
    private var lastLabelTime: Double?
    /// Labels learned and labels rejected by the gate.
    public private(set) var learned = 0
    public private(set) var rejected = 0

    /// `distanceM`: the calibration's mean distance from the camera to the face (metres), which sets how far a
    /// head turn moves the aim.
    public init(reference: HeadPose, distanceM: Double = 0.28, config: GazeAdapterConfig = GazeAdapterConfig()) {
        self.reference = reference
        self.config = config
        // The aim follows the head: pitch turns it along screen y, yaw along screen x, so the correction pushes back.
        let k = max(0.1, min(distanceM, 0.6)) * config.ptPerMetre
        priorX = [0, 0, -config.followYaw * k]
        priorY = [0, -config.followPitch * k, 0]
        wx = priorX
        wy = priorY
    }

    private func phi(_ pose: HeadPose) -> [Double] { [1, pose.pitch - reference.pitch, pose.yaw - reference.yaw] }

    /// The correction for a frame with this head pose (screen pt), capped at `maxCorrectionPt`.
    public func correction(pose: HeadPose) -> Vec2 {
        let f = phi(pose)
        var c = Vec2(zip(wx, f).map(*).reduce(0, +), zip(wy, f).map(*).reduce(0, +))
        let len = c.length
        if len > config.maxCorrectionPt { c = c * (config.maxCorrectionPt / len) }
        return c
    }

    /// The model's prediction with the correction added (screen pt in, screen pt out).
    public func correct(_ raw: Vec2, pose: HeadPose) -> Vec2 { raw + correction(pose: pose) }

    /// Learns from one moment when the player was looking at `target` (screen pt) while the model predicted `raw`
    /// (screen pt, uncorrected). `weight` < 1 for many small labels, such as every frame of a meteor being burned.
    /// Returns false when the label is further than `gatePt` from the corrected aim and is left out.
    @discardableResult
    public mutating func learn(raw: Vec2, target: Vec2, pose: HeadPose, time: Double, weight: Double = 1) -> Bool {
        guard weight > 0, raw.x.isFinite, raw.y.isFinite else { return false }
        if min(correct(raw, pose: pose).distance(to: target), raw.distance(to: target)) > config.gatePt {
            rejected += 1
            return false
        }
        if let last = lastLabelTime, time > last {
            let decay = pow(0.5, (time - last) / config.halfLifeSec)
            for i in 0..<9 { S[i] *= decay }
            for i in 0..<3 { sx[i] *= decay; sy[i] *= decay }
        }
        lastLabelTime = max(lastLabelTime ?? time, time)
        let f = phi(pose)
        let r = target - raw
        for i in 0..<3 {
            for j in 0..<3 { S[i * 3 + j] += weight * f[i] * f[j] }
            sx[i] += weight * f[i] * r.x
            sy[i] += weight * f[i] * r.y
        }
        // Ridge prior around (priorX, priorY): label noise over prior spread, squared, on each term.
        let n2 = config.labelNoisePt * config.labelNoisePt
        let lambda = [n2 / (config.priorBiasPt * config.priorBiasPt),
                      n2 / (config.priorSlopePtPerRad * config.priorSlopePtPerRad),
                      n2 / (config.priorSlopePtPerRad * config.priorSlopePtPerRad)]
        var A = S
        for i in 0..<3 { A[i * 4] += lambda[i] }
        let bx = (0..<3).map { sx[$0] + lambda[$0] * priorX[$0] }, by = (0..<3).map { sy[$0] + lambda[$0] * priorY[$0] }
        if let x = Self.solve3(A, bx), let y = Self.solve3(A, by) { wx = x; wy = y }
        learned += 1
        return true
    }

    /// Solves the 3x3 system A·x = b (A row-major) by Gaussian elimination with partial pivoting.
    static func solve3(_ a: [Double], _ b: [Double]) -> [Double]? {
        var m = [[a[0], a[1], a[2], b[0]], [a[3], a[4], a[5], b[1]], [a[6], a[7], a[8], b[2]]]
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p)
            for r in 0..<3 where r != c {
                let k = m[r][c] / m[c][c]
                for j in c..<4 { m[r][j] -= k * m[c][j] }
            }
        }
        return (0..<3).map { m[$0][3] / m[$0][$0] }
    }
}
