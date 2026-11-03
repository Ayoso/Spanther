import Foundation

/// Energy pool and 3-blink reload numbers. Lives in balance.json under "energy".
public struct EnergyConfig: Codable, Sendable {
    /// Blink detection on ARKit `eyeBlinkLeft` / `eyeBlinkRight` blend shapes (0 open ... 1 closed).
    public struct Blink: Codable, Sendable {
        /// Both eyes at or above this value count as closed.
        public var closeThreshold: Double = 0.6
        /// Both eyes below this value count as open again (hysteresis).
        public var openThreshold: Double = 0.35
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
    public var cheapestCost: Int { costByClass.values.min() ?? 1 }
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

    public init(_ energy: EnergyConfig) {
        config = energy.blink
        burst = BurstCounter(count: energy.reloadBlinks, windowSec: energy.reloadWindowSec)
    }

    /// How long the eyes have been shut at `time` (0 when open).
    public func closedFor(at time: Double) -> Double { closedSince.map { time - $0 } ?? 0 }

    /// `left` / `right`: eye closure 0...1 (ARKit eyeBlinkLeft / eyeBlinkRight). `time` in seconds.
    public mutating func update(time: Double, left: Double, right: Double) -> BlinkUpdate {
        var ended: Double?
        var reload = false
        let both = Swift.min(left, right)
        let either = Swift.max(left, right)

        if !eyesClosed, both >= config.closeThreshold {
            eyesClosed = true
            closedSince = time
        } else if eyesClosed, both < config.openThreshold {
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

        if either >= config.freezeThreshold || eyesClosed { lastFreezeTime = time }
        let freeze = lastFreezeTime.map { time - $0 <= config.holdAfterOpenSec } ?? false
        return BlinkUpdate(freezeGaze: freeze, eyesClosed: eyesClosed, blinkEnded: ended, reload: reload)
    }

    /// Blinks counted toward the next reload.
    public func pendingBlinks(at time: Double) -> Int { burst.pending(at: time) }

    /// Face lost: forget a half-finished blink but keep the count, so a dropped frame does not cost a blink.
    public mutating func faceLost() {
        eyesClosed = false
        closedSince = nil
    }
}
