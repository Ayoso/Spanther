import Foundation

/// Energy pool and 3-blink reload numbers. Lives in balance.json under "energy".
public struct EnergyConfig: Codable, Sendable {
    /// Blink detection on ARKit `eyeBlinkLeft` / `eyeBlinkRight` blend shapes (0 open ... 1 closed).
    /// Each threshold is the larger of a fixed value and "this eye's open level + a rise", because the lid
    /// drops (and eyeBlink grows) when the player looks down toward Earth, where it matters most.
    public struct Blink: Codable, Sendable {
        /// Both eyes at or above this value count as closed.
        public var closeThreshold: Double = 0.6
        /// Both eyes below this value count as open again (hysteresis).
        public var openThreshold: Double = 0.35
        /// Rises above the eye's open level for closed / open / freeze.
        public var closeRise: Double = 0.3
        public var openRise: Double = 0.15
        public var freezeRise: Double = 0.2
        /// The open level is the lowest value of each eye over this window (longer than any blink)...
        public var baselineWindowSec: Double = 0.8
        /// ...but never above this, so eyes held shut do not become the new "open".
        public var baselineCap: Double = 0.5
        /// Lids lowered this long without closing is a look down or a squint, not a blink: stop holding the gaze.
        public var maxLidHoldSec: Double = 0.3
        /// Shorter closures are noise (one bad frame), not a blink.
        public var minClosedSec: Double = 0.05
        /// Longer closures are "eyes shut", not a blink, and reset the reload count.
        public var maxClosedSec: Double = 0.5
        /// Hold the gaze point while either eye is above this value: the pupil detector drifts as the lid closes.
        public var freezeThreshold: Double = 0.35
        /// Keep holding this long after the eyes open, while the pupils settle.
        public var holdAfterOpenSec: Double = 0.08
        public init() {}

        // Missing keys keep their defaults, so balance.json can list only what it tunes.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            closeThreshold = try c.decodeIfPresent(Double.self, forKey: .closeThreshold) ?? closeThreshold
            openThreshold = try c.decodeIfPresent(Double.self, forKey: .openThreshold) ?? openThreshold
            minClosedSec = try c.decodeIfPresent(Double.self, forKey: .minClosedSec) ?? minClosedSec
            maxClosedSec = try c.decodeIfPresent(Double.self, forKey: .maxClosedSec) ?? maxClosedSec
            closeRise = try c.decodeIfPresent(Double.self, forKey: .closeRise) ?? closeRise
            openRise = try c.decodeIfPresent(Double.self, forKey: .openRise) ?? openRise
            freezeRise = try c.decodeIfPresent(Double.self, forKey: .freezeRise) ?? freezeRise
            baselineWindowSec = try c.decodeIfPresent(Double.self, forKey: .baselineWindowSec) ?? baselineWindowSec
            baselineCap = try c.decodeIfPresent(Double.self, forKey: .baselineCap) ?? baselineCap
            maxLidHoldSec = try c.decodeIfPresent(Double.self, forKey: .maxLidHoldSec) ?? maxLidHoldSec
            freezeThreshold = try c.decodeIfPresent(Double.self, forKey: .freezeThreshold) ?? freezeThreshold
            holdAfterOpenSec = try c.decodeIfPresent(Double.self, forKey: .holdAfterOpenSec) ?? holdAfterOpenSec
        }
    }

    public var max: Int = 10
    /// Energy one kill costs, by asteroid class.
    public var costByClass: [String: Int] = ["S": 1, "M": 2, "L": 3, "XL": 5]
    /// Blinks needed for a reload, and the window they must all fall into.
    public var reloadBlinks: Int = 3
    public var reloadWindowSec: Double = 2.0
    /// Touch mode: taps on the energy bar for a reload, same window.
    public var touchReloadTaps: Int = 3
    public var blink: Blink = Blink()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        max = try c.decodeIfPresent(Int.self, forKey: .max) ?? max
        costByClass = try c.decodeIfPresent([String: Int].self, forKey: .costByClass) ?? costByClass
        reloadBlinks = try c.decodeIfPresent(Int.self, forKey: .reloadBlinks) ?? reloadBlinks
        reloadWindowSec = try c.decodeIfPresent(Double.self, forKey: .reloadWindowSec) ?? reloadWindowSec
        touchReloadTaps = try c.decodeIfPresent(Int.self, forKey: .touchReloadTaps) ?? touchReloadTaps
        blink = try c.decodeIfPresent(Blink.self, forKey: .blink) ?? blink
    }

    public func cost(_ className: String) -> Int { costByClass[className] ?? 1 }
}

/// Counts presses (blinks or taps) and fires when `count` of them land inside `windowSec`.
public struct BurstCounter: Sendable {
    public let count: Int
    public let windowSec: Double
    public private(set) var times: [Double] = []

    public init(count: Int, windowSec: Double) {
        self.count = Swift.max(1, count)
        self.windowSec = windowSec
    }

    /// Registers one press at `time`. Returns true when this press completes a burst; the counter then starts over.
    public mutating func press(at time: Double) -> Bool {
        times.removeAll { time - $0 > windowSec }
        times.append(time)
        if times.count >= count { times.removeAll(); return true }
        return false
    }

    /// Presses so far in the current window (for the HUD: "2 of 3").
    public func pending(at time: Double) -> Int { times.filter { time - $0 <= windowSec }.count }

    public mutating func reset() { times.removeAll() }
}

/// What the blink detector saw on one frame.
public struct BlinkUpdate: Sendable, Equatable {
    /// Hold the last gaze point instead of using this frame's prediction.
    public var freezeGaze: Bool
    /// Both eyes are shut right now.
    public var eyesClosed: Bool
    /// A complete blink just ended on this frame (eyes reopened), with its closed time.
    public var blinkEnded: Double?
    /// This blink completed the reload burst.
    public var reload: Bool
}

/// Turns per-frame eye-closure values into blinks, a 3-blink reload signal and a gaze-freeze flag.
/// Plain Swift so it can be tested with synthetic blink curves; the app feeds it ARKit blend shapes.
public struct BlinkDetector: Sendable {
    public let config: EnergyConfig.Blink
    public private(set) var burst: BurstCounter
    public private(set) var eyesClosed = false
    private var closedSince: Double?
    private var lastFreezeTime: Double?
    private var history: [(time: Double, left: Double, right: Double)] = []
    private var lidMovingSince: Double?

    public init(_ energy: EnergyConfig) {
        config = energy.blink
        burst = BurstCounter(count: energy.reloadBlinks, windowSec: energy.reloadWindowSec)
    }

    /// How long the eyes have been shut at `time` (0 when open).
    public func closedFor(at time: Double) -> Double { closedSince.map { time - $0 } ?? 0 }

    /// Open level of each eye right now (0 open ... 1 closed), for the debug overlay.
    public func openLevel() -> (left: Double, right: Double) {
        let l = history.map(\.left).min() ?? 0, r = history.map(\.right).min() ?? 0
        return (Swift.min(l, config.baselineCap), Swift.min(r, config.baselineCap))
    }

    /// `left` / `right`: eye closure 0...1 (ARKit eyeBlinkLeft / eyeBlinkRight). `time` in seconds.
    public mutating func update(time: Double, left: Double, right: Double) -> BlinkUpdate {
        var ended: Double?
        var reload = false
        history.removeAll { time - $0.time > config.baselineWindowSec }
        history.append((time, left, right))
        let base = openLevel()
        func over(_ v: Double, _ fixed: Double, _ rise: Double, _ b: Double) -> Bool { v >= Swift.max(fixed, b + rise) }
        let leftDown = over(left, config.closeThreshold, config.closeRise, base.left)
        let rightDown = over(right, config.closeThreshold, config.closeRise, base.right)
        let leftUp = !over(left, config.openThreshold, config.openRise, base.left)
        let rightUp = !over(right, config.openThreshold, config.openRise, base.right)
        let lidMoving = over(left, config.freezeThreshold, config.freezeRise, base.left)
            || over(right, config.freezeThreshold, config.freezeRise, base.right)

        if !eyesClosed, leftDown && rightDown {
            eyesClosed = true
            closedSince = time
        } else if eyesClosed, leftUp || rightUp {
            eyesClosed = false
            let dur = time - (closedSince ?? time)
            closedSince = nil
            if dur >= config.minClosedSec && dur <= config.maxClosedSec {
                ended = dur
                reload = burst.press(at: time)
            } else if dur > config.maxClosedSec {
                burst.reset()
            }
        }

        // Hold while the eyes are shut, or while a lid is coming down, but only briefly if it never closes.
        if lidMoving { if lidMovingSince == nil { lidMovingSince = time } } else { lidMovingSince = nil }
        let lidHold = lidMovingSince.map { time - $0 <= config.maxLidHoldSec } ?? false
        if eyesClosed || lidHold { lastFreezeTime = time }
        let freeze = lastFreezeTime.map { time - $0 <= config.holdAfterOpenSec } ?? false
        return BlinkUpdate(freezeGaze: freeze, eyesClosed: eyesClosed, blinkEnded: ended, reload: reload)
    }

    /// Blinks counted toward the next reload.
    public func pendingBlinks(at time: Double) -> Int { burst.pending(at: time) }

    /// Face lost: forget a half-finished blink but keep the count, so a dropped frame does not cost a blink.
    public mutating func faceLost() {
        eyesClosed = false
        closedSince = nil
        lidMovingSince = nil
        history.removeAll()
    }
}
