import Foundation

/// Which eye a wink used. `both` is an ordinary blink (or a deliberate two-eye close).
public enum WinkSide: String, Sendable, CaseIterable {
    case left, right, both
}

/// One-eye wink detection on ARKit `eyeBlinkLeft` / `eyeBlinkRight` (0 open ... 1 closed), for the wink test and
/// the rhythm mode that will follow it. Thresholds ride on each eye's open level, like the reload blink detector
/// (`EnergyConfig.Blink`), because the lids drop when the player looks down.
public struct WinkConfig: Equatable, Sendable {
    /// An eye at or above max(closeThreshold, open level + closeRise) is closed.
    public var closeThreshold = 0.6
    public var closeRise = 0.3
    /// It is open again below max(openThreshold, open level + openRise) (hysteresis).
    public var openThreshold = 0.35
    public var openRise = 0.15
    public var baselineWindowSec = 0.8
    public var baselineCap = 0.5
    /// The other eye has this long after the first one to close too and make the event a blink. If it closes
    /// later, the event stays a wink of the first eye, with the other eye squinting along. Natural blinks cross the
    /// close level within 0-17 ms of each other (Aziz's second iPhone session, 53 blinks, and the blinks in his wink
    /// test on 2026-11-07), while in that wink test his right eye followed his left wink 33-50 ms later on 4 of 30
    /// left cues. At least 1.5 frame intervals, so at 30 fps the next frame still counts as together.
    public var pairWindowSec = 0.025
    /// Closures shorter than this are one bad frame, not a wink.
    public var minClosedSec = 0.05
    public init() {}
}

/// A detected closure. `onset` is when the first eye crossed the close threshold (seconds, the tracking clock):
/// that is the moment a rhythm judgement uses, although the side is known only up to `pairWindowSec` later.
public struct WinkEvent: Equatable, Sendable {
    public var side: WinkSide
    public var onset: Double
    /// When the side was decided (onset + about minClosedSec): the extra delay before the game can react.
    public var decided: Double
    /// Highest closure of the other eye while the side was being decided (0 for `both`): how much it squints
    /// along with a wink. It can pass the close level when that eye closed after the pair window.
    public var otherPeak: Double

    public init(side: WinkSide, onset: Double, decided: Double, otherPeak: Double) {
        self.side = side
        self.onset = onset
        self.decided = decided
        self.otherPeak = otherPeak
    }
}

public struct WinkDetector: Sendable {
    public let config: WinkConfig
    private var history: [(time: Double, left: Double, right: Double)] = []
    /// A closure whose side is not known yet: the eye that closed first, the pair window it got (from the frame
    /// interval at its onset), and whether the other eye closed after that window.
    private var pending: (onset: Double, first: WinkSide, window: Double, otherPeak: Double, otherLate: Bool)?
    /// Time between the last two frames (s).
    private var frameInterval = 1.0 / 60
    /// An event has been sent for the current closure: wait until both eyes are open again.
    private var latched = false

    public init(_ config: WinkConfig = WinkConfig()) { self.config = config }

    /// Open level of each eye (0 open ... 1 closed): its lowest value over the baseline window, capped.
    public func openLevel() -> (left: Double, right: Double) {
        let l = history.map(\.left).min() ?? 0, r = history.map(\.right).min() ?? 0
        return (Swift.min(l, config.baselineCap), Swift.min(r, config.baselineCap))
    }

    /// The closure level at which each eye counts as closed now.
    public func closeLevel() -> (left: Double, right: Double) {
        let base = openLevel()
        return (Swift.max(config.closeThreshold, base.left + config.closeRise),
                Swift.max(config.closeThreshold, base.right + config.closeRise))
    }

    /// Feed one frame. `left` / `right`: eye closure 0...1; `time` in seconds. Returns an event once its side is
    /// known, at most once per closure.
    public mutating func update(time: Double, left: Double, right: Double) -> WinkEvent? {
        if let last = history.last?.time, time > last, time - last < 0.2 { frameInterval = time - last }
        history.removeAll { time - $0.time > config.baselineWindowSec }
        // The open level is taken before this frame joins it, so a closure never lifts its own threshold.
        let base = history.isEmpty
            ? (left: Swift.min(left, config.baselineCap), right: Swift.min(right, config.baselineCap))
            : openLevel()
        history.append((time, left, right))
        let lClosed = left >= Swift.max(config.closeThreshold, base.left + config.closeRise)
        let rClosed = right >= Swift.max(config.closeThreshold, base.right + config.closeRise)
        let lOpen = left < Swift.max(config.openThreshold, base.left + config.openRise)
        let rOpen = right < Swift.max(config.openThreshold, base.right + config.openRise)

        if latched {
            if lOpen && rOpen { latched = false }
            return nil
        }
        if var p = pending {
            let otherClosed = p.first == .left ? rClosed : lClosed
            let firstOpen = p.first == .left ? lOpen : rOpen
            let otherOpen = p.first == .left ? rOpen : lOpen
            // Frame times jitter by microseconds, so the windows get a hair of slack.
            let held = time - p.onset + 1e-6
            if otherClosed && !p.otherLate {
                if held <= p.window {
                    // Both eyes within the pair window: a blink.
                    pending = nil
                    latched = true
                    return WinkEvent(side: .both, onset: p.onset, decided: time, otherPeak: 0)
                }
                p.otherLate = true
            }
            p.otherPeak = Swift.max(p.otherPeak, p.first == .left ? right : left)
            pending = p
            if firstOpen && held < config.minClosedSec && !p.otherLate {
                // One bad frame.
                pending = nil
                return nil
            }
            if held >= Swift.max(p.window, config.minClosedSec) || firstOpen {
                pending = nil
                // A wink that has already reopened needs no latch; an eye still closed must open first.
                latched = !(firstOpen && otherOpen)
                return WinkEvent(side: p.first, onset: p.onset, decided: time, otherPeak: p.otherPeak)
            }
            return nil
        }
        if lClosed || rClosed {
            if lClosed && rClosed {
                latched = true
                return WinkEvent(side: .both, onset: time, decided: time, otherPeak: 0)
            }
            let window = Swift.max(config.pairWindowSec, 1.5 * frameInterval)
            pending = (time, lClosed ? .left : .right, window, lClosed ? right : left, false)
        }
        return nil
    }

    /// Face lost: drop a half-seen closure.
    public mutating func faceLost() {
        pending = nil
        latched = false
        history.removeAll()
    }
}

/// The wink test: a click on every beat and the eye to wink on it. 4 count-in clicks, then 20 left, 20 right and
/// 20 alternating, with 4 silent beats between blocks. 60 BPM by default: winking faster than once a second is hard
/// for most people, and this test is about timing and which eye, not speed.
public struct WinkTestPlan: Equatable, Sendable {
    public struct Cue: Equatable, Sendable {
        public var side: WinkSide
        /// Seconds after the first count-in click.
        public var offset: Double
        /// 0 left block, 1 right block, 2 alternating block.
        public var block: Int

        public init(side: WinkSide, offset: Double, block: Int) {
            self.side = side
            self.offset = offset
            self.block = block
        }
    }

    public let cues: [Cue]
    public let periodSec: Double
    /// Count-in clicks, seconds after the first one (no wink asked).
    public let countIn: [Double]

    public init(perBlock: Int = 20, periodSec: Double = 1.0, restBeats: Int = 4, countInBeats: Int = 4) {
        self.periodSec = periodSec
        countIn = (0..<countInBeats).map { Double($0) * periodSec }
        var cues: [Cue] = []
        var beat = countInBeats
        for block in 0..<3 {
            for i in 0..<perBlock {
                let side: WinkSide = block == 0 ? .left : block == 1 ? .right : (i % 2 == 0 ? .left : .right)
                cues.append(Cue(side: side, offset: Double(beat) * periodSec, block: block))
                beat += 1
            }
            if block < 2 { beat += restBeats }
        }
        self.cues = cues
    }

    /// Every click: the count-in and one per cue.
    public var clicks: [Double] { countIn + cues.map(\.offset) }
    public var durationSec: Double { (cues.last?.offset ?? 0) + periodSec }
}

/// Results of a wink test, per eye. Times in seconds unless the name says ms.
public struct WinkStats: Equatable, Sendable {
    public struct Eye: Equatable, Sendable {
        public var cues = 0
        /// Cues answered by a wink of the asked eye inside the match window.
        public var hits = 0
        /// Cues answered by the other eye or by both eyes.
        public var wrongEye = 0
        public var bothEyes = 0
        /// Mean and SD of (wink onset - beat), ms. Positive = late.
        public var meanOffsetMs = 0.0
        public var sdOffsetMs = 0.0
        /// Hits within ±100 / ±180 / ±250 ms of the beat once the mean offset is removed (the per-player offset a
        /// rhythm game calibrates away).
        public var within100 = 0, within180 = 0, within250 = 0
        /// Median of the other eye's peak while winking this eye.
        public var medianOtherPeak = 0.0
        /// Mean time from onset to the side being decided, ms.
        public var meanDecisionMs = 0.0
        public init() {}
    }

    public var left = Eye()
    public var right = Eye()
    /// Closures not near any cue: one-eye ones are false triggers, `both` ones are mostly natural blinks.
    public var strayOneEye = 0
    public var strayBoth = 0

    public init(left: Eye = Eye(), right: Eye = Eye(), strayOneEye: Int = 0, strayBoth: Int = 0) {
        self.left = left
        self.right = right
        self.strayOneEye = strayOneEye
        self.strayBoth = strayBoth
    }

    /// Each cue takes the nearest unused event within `matchWindowSec` of its beat. `beats` are absolute times (the
    /// same clock as the events) in cue order.
    public static func compute(cues: [WinkTestPlan.Cue], beats: [Double], events: [WinkEvent],
                               matchWindowSec: Double = 0.45) -> WinkStats {
        var used = Set<Int>()
        var offsets: [WinkSide: [Double]] = [.left: [], .right: []]
        var others: [WinkSide: [Double]] = [.left: [], .right: []]
        var decisions: [WinkSide: [Double]] = [.left: [], .right: []]
        var eyes: [WinkSide: Eye] = [.left: Eye(), .right: Eye()]
        for (cue, beat) in zip(cues, beats) where cue.side != .both {
            eyes[cue.side]!.cues += 1
            var best: Int?
            for (i, e) in events.enumerated() where !used.contains(i) && abs(e.onset - beat) <= matchWindowSec {
                if best == nil || abs(e.onset - beat) < abs(events[best!].onset - beat) { best = i }
            }
            guard let b = best else { continue }
            used.insert(b)
            let e = events[b]
            if e.side == cue.side {
                eyes[cue.side]!.hits += 1
                offsets[cue.side]!.append(e.onset - beat)
                others[cue.side]!.append(e.otherPeak)
                decisions[cue.side]!.append(e.decided - e.onset)
            } else if e.side == .both {
                eyes[cue.side]!.bothEyes += 1
            } else {
                eyes[cue.side]!.wrongEye += 1
            }
        }
        for side in [WinkSide.left, .right] {
            let o = offsets[side]!
            guard !o.isEmpty else { continue }
            let mean = o.reduce(0, +) / Double(o.count)
            let sd = (o.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(o.count)).squareRoot()
            eyes[side]!.meanOffsetMs = mean * 1000
            eyes[side]!.sdOffsetMs = sd * 1000
            eyes[side]!.within100 = o.filter { abs($0 - mean) <= 0.100 }.count
            eyes[side]!.within180 = o.filter { abs($0 - mean) <= 0.180 }.count
            eyes[side]!.within250 = o.filter { abs($0 - mean) <= 0.250 }.count
            let sorted = others[side]!.sorted()
            eyes[side]!.medianOtherPeak = sorted[sorted.count / 2]
            let d = decisions[side]!
            eyes[side]!.meanDecisionMs = d.reduce(0, +) / Double(d.count) * 1000
        }
        var stats = WinkStats(left: eyes[.left]!, right: eyes[.right]!)
        for (i, e) in events.enumerated() where !used.contains(i) {
            if e.side == .both { stats.strayBoth += 1 } else { stats.strayOneEye += 1 }
        }
        return stats
    }
}

/// A scripted player for the wink test, for the Simulator smoke test (which has no face tracking) and for tests.
/// It winks the asked eye on most cues, 80 ms late with up to ±60 ms of jitter, and the other eye squints to 0.3.
/// Out of every 20 cues it uses the wrong eye once, blinks instead once and misses one. A natural blink falls
/// half a beat after every 6th cue. With the default plan that is 27 of 30 hits on the left eye, 24 of 30 on the
/// right, 3 cues answered by the wrong eye, 3 by a blink, and 10 stray blinks.
public struct WinkBot: Sendable {
    public enum Answer: Equatable, Sendable { case asked, otherEye, blink, none }

    public struct Closure: Equatable, Sendable {
        public var side: WinkSide
        public var onset: Double
        public var duration: Double
    }

    /// One per cue, in cue order.
    public let answers: [Answer]
    public let closures: [Closure]
    public var openLevel = 0.1, closedLevel = 0.9, squint = 0.3

    /// `start`: the run's first click, on the clock the lids are read with.
    public init(plan: WinkTestPlan, start: Double) {
        var answers: [Answer] = [], closures: [Closure] = []
        for (i, cue) in plan.cues.enumerated() {
            let beat = start + cue.offset
            let answer: Answer = i % 20 == 7 ? .otherEye : i % 20 == 13 ? .blink : i % 20 == 17 ? .none : .asked
            answers.append(answer)
            // (i * 37) % 13 runs through 0...12, so the jitter averages out to zero.
            let onset = beat + 0.08 + Double((i * 37) % 13 - 6) * 0.01
            let other: WinkSide = cue.side == .left ? .right : .left
            switch answer {
            case .asked: closures.append(Closure(side: cue.side, onset: onset, duration: 0.22))
            case .otherEye: closures.append(Closure(side: other, onset: onset, duration: 0.22))
            case .blink: closures.append(Closure(side: .both, onset: onset, duration: 0.12))
            case .none: break
            }
            if i % 6 == 5 { closures.append(Closure(side: .both, onset: beat + plan.periodSec / 2, duration: 0.12)) }
        }
        self.answers = answers
        self.closures = closures
    }

    /// Eyelid closure at `t`, 0 open ... 1 closed, like ARKit eyeBlinkLeft / eyeBlinkRight.
    public func lids(at t: Double) -> (left: Double, right: Double) {
        var l = openLevel, r = openLevel
        for c in closures where t >= c.onset && t < c.onset + c.duration {
            switch c.side {
            case .left: l = closedLevel; r = Swift.max(r, squint)
            case .right: r = closedLevel; l = Swift.max(l, squint)
            case .both: l = closedLevel; r = closedLevel
            }
        }
        return (l, r)
    }
}
