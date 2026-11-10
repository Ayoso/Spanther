import Foundation

// The 60-second warm-up: one target glides across the screen and the player follows it with the eyes. It moves
// along a horizontal line, then a vertical one, then a figure of eight, and never jumps: each part fades into the
// next. The score is the share of the minute the gaze stayed near the target. A game result, like the others: it
// tells how the play went with this calibration, not how anyone's eyes work.

/// Where the warm-up's target is at each moment. Positions are fractions of the screen (0...1 across and down, as
/// the player sees it), turned into screen pt by `position(at:in:)`.
public struct PursuitPlan: Equatable, Sendable {
    public enum Part: String, Sendable, CaseIterable {
        case horizontal, vertical, eight
    }

    /// The whole warm-up (s); each part takes a third of it.
    public var durationSec = 60.0
    /// How far the target goes from the centre, as a share of the screen's width and height.
    public var reachX = 0.38
    public var reachY = 0.30
    /// Seconds for one sweep there and back, per part (for the eight: one whole figure).
    public var horizontalPeriodSec = 10.0
    public var verticalPeriodSec = 5.0
    public var eightPeriodSec = 10.0
    /// One part fades into the next over this long (s), and the first one starts from rest over it.
    public var blendSec = 2.0
    /// The frames around a change of part are not scored: the path there is a mix of both.
    public var settleSec = 1.0

    public init() {}

    public var partSec: Double { durationSec / 3 }

    /// The part the moment belongs to.
    public func part(at t: Double) -> Part {
        t < partSec ? .horizontal : t < 2 * partSec ? .vertical : .eight
    }

    /// True where a frame counts toward the score: inside the minute, and clear of the starts of the three parts.
    public func scored(at t: Double) -> Bool {
        guard t >= settleSec, t <= durationSec else { return false }
        for edge in [partSec, 2 * partSec] where abs(t - edge) < settleSec { return false }
        return true
    }

    /// 0 before `a`, 1 after `b`, a smooth step between.
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        guard b > a else { return t >= b ? 1 : 0 }
        let k = min(1, max(0, (t - a) / (b - a)))
        return k * k * (3 - 2 * k)
    }

    /// The target's place at `t` seconds, as fractions of the screen from its centre: x in -reachX...reachX and
    /// y in -reachY...reachY. Continuous in place and in speed over the whole minute.
    public func offset(at t: Double) -> (x: Double, y: Double) {
        let t = min(max(0, t), durationSec)
        let p = partSec, h = blendSec / 2
        // Each part's weight: it fades in around its start and out around its end.
        let wH = Self.ramp(t, 0, blendSec) * (1 - Self.ramp(t, p - h, p + h))
        let wV = Self.ramp(t, p - h, p + h) * (1 - Self.ramp(t, 2 * p - h, 2 * p + h))
        let w8 = Self.ramp(t, 2 * p - h, 2 * p + h) * (1 - Self.ramp(t, durationSec - blendSec, durationSec))
        let tau = 2 * Double.pi
        let x = wH * sin(tau * t / horizontalPeriodSec) + w8 * sin(tau * (t - 2 * p) / eightPeriodSec)
        let y = wV * sin(tau * (t - p) / verticalPeriodSec) + w8 * sin(2 * tau * (t - 2 * p) / eightPeriodSec)
        return (reachX * x, reachY * y)
    }

    /// The target's centre at `t` seconds on a screen of `size` (screen pt, origin top-left, y down).
    public func position(at t: Double, in size: Vec2) -> Vec2 {
        let o = offset(at: t)
        return Vec2(size.x * (0.5 + o.x), size.y * (0.5 + o.y))
    }

    /// How near the gaze must be to count as on the target (screen pt): a base radius plus the calibration's
    /// measured miss, the same idea as the meteors' hit zone. `measuredErrorPt` nil: played by finger.
    public static func onTargetRadius(measuredErrorPt: Double?) -> Double {
        60 + max(30, min(measuredErrorPt ?? 30, 115))
    }
}

/// Counts the frames of one warm-up: how many had the gaze near the target, and how far it was on average.
public struct PursuitTally: Equatable, Sendable {
    public struct Count: Equatable, Sendable {
        public var frames = 0
        public var onTarget = 0
        /// On-target frames as a share of all, 0...1; nil without frames.
        public var share: Double? { frames > 0 ? Double(onTarget) / Double(frames) : nil }
    }

    /// The gaze counts as on the target within this distance (screen pt).
    public let radiusPt: Double
    public private(set) var all = Count()
    public private(set) var horizontal = Count()
    public private(set) var vertical = Count()
    public private(set) var eight = Count()
    /// Frames with no gaze point: the face was lost or the player looked away. They count as off the target.
    public private(set) var lost = 0
    private var distanceSum = 0.0
    private var distanceFrames = 0

    public init(radiusPt: Double) { self.radiusPt = radiusPt }

    /// One frame of `part`: the distance from the gaze to the target's centre (screen pt), nil when there was no
    /// gaze point.
    public mutating func add(part: PursuitPlan.Part, distance: Double?) {
        let on = distance.map { $0.isFinite && $0 <= radiusPt } ?? false
        all.frames += 1
        if on { all.onTarget += 1 }
        switch part {
        case .horizontal: horizontal.frames += 1; if on { horizontal.onTarget += 1 }
        case .vertical: vertical.frames += 1; if on { vertical.onTarget += 1 }
        case .eight: eight.frames += 1; if on { eight.onTarget += 1 }
        }
        if let d = distance, d.isFinite {
            distanceSum += d
            distanceFrames += 1
        } else {
            lost += 1
        }
    }

    public var isEmpty: Bool { all.frames == 0 }

    /// Mean distance from the gaze to the target over the frames that had a gaze point (screen pt).
    public var meanDistancePt: Double? { distanceFrames > 0 ? distanceSum / Double(distanceFrames) : nil }

    /// Share of the frames without a gaze point, 0...1.
    public var lostShare: Double? { all.frames > 0 ? Double(lost) / Double(all.frames) : nil }
}
