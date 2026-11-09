import Foundation

// The living background of the atlas screens. Lianas hang from the top edge and sway, two branching trees grow
// from the bottom corners, spores drift up, and now and then a light pulse runs down a liana like a signal along a
// cable. In rhythm play, `Distraction`s add brighter movement in the corner of the eye: a firefly crossing, a flower
// opening at a liana's tip, a seed spinning down, a surge along a branch, a liana swinging. They try to pull the
// eyes off the notes, which is what an attention game should practise.
//
// Everything comes from a seed, and a frame is a pure function of the garden and the time, so drawing keeps no
// state. Screen pt (origin top left, y down), times in seconds.

public struct Garden: Sendable {
    public struct Leaf: Sendable, Equatable {
        /// Fraction of the liana's length where it grows, the side it points to (-1 left, +1 right), length (pt).
        public var at: Double
        public var side: Double
        public var size: Double
    }

    public struct Liana: Sendable, Equatable {
        public var anchorX: Double
        public var length: Double
        public var width: Double
        /// Sideways swing of the tip (pt), its period (s) and phase (radians).
        public var sway: Double
        public var period: Double
        public var phase: Double
        /// A fixed sideways curl of the tip (pt).
        public var curl: Double
        public var leaves: [Leaf]
        /// A light pulse runs down it every `pulseEvery` seconds, the first one starting at `pulseOffset`.
        public var pulseEvery: Double
        public var pulseOffset: Double
    }

    public struct Segment: Sendable, Equatable {
        /// The segment it grows from, nil for the trunk.
        public var parent: Int?
        /// Direction relative to the parent's (radians); the trunk's is absolute (0 points right, -π/2 up).
        public var angle: Double
        public var length: Double
        public var depth: Int
        public var phase: Double
        /// No segment grows from it.
        public var isTip: Bool
    }

    public struct Tree: Sendable, Equatable {
        public var root: Vec2
        /// Parents come before their children.
        public var segments: [Segment]
        public var maxDepth: Int
    }

    public struct Spore: Sendable, Equatable {
        public var x: Double
        public var y: Double
        /// Rise speed (pt/s), sideways wobble (pt) and its period (s).
        public var rise: Double
        public var wobble: Double
        public var period: Double
        public var phase: Double
        public var size: Double
        /// A few spores glow like fireflies; the rest are ink.
        public var glows: Bool
    }

    /// One drawn segment of a tree.
    public struct Twig: Sendable, Equatable {
        public var a: Vec2
        public var b: Vec2
        public var depth: Int
        public var isTip: Bool
        /// The segment's index in its tree.
        public var index: Int
    }

    public let size: Vec2
    public let lianas: [Liana]
    public let trees: [Tree]
    public let spores: [Spore]

    /// Seconds a pulse takes down a liana, and how long the tip flashes when it arrives.
    public static let pulseTravelSec = 1.6
    public static let pulseFlashSec = 0.5

    public init(size: Vec2, seed: UInt64, lianaCount: Int = 7, sporeCount: Int = 22) {
        self.size = size
        var rng = Rng(seed: seed)
        func r(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * rng.next() }
        let w = size.x, h = size.y

        var lianas: [Liana] = []
        for i in 0..<max(0, lianaCount) {
            let x = w * (Double(i) + 0.5 + r(-0.3...0.3)) / Double(lianaCount)
            // Longer at the sides, short in the middle, so the middle ones end above the notes and the long ones
            // frame the screen like a canopy.
            let edge = min(1, abs(x / w - 0.5) * 2)
            let length = h * (0.1 + 0.46 * pow(edge, 1.6) + r(0...0.06))
            let count = max(2, Int(length / 17))
            var leaves: [Leaf] = []
            for k in 0..<count {
                leaves.append(Leaf(at: 0.14 + 0.82 * (Double(k) + r(0...0.45)) / Double(count),
                                   side: k % 2 == 0 ? 1 : -1, size: r(6...11)))
            }
            let every = r(5...11)
            lianas.append(Liana(anchorX: x, length: length, width: r(1.1...2.0), sway: r(3...6) + length * 0.04,
                                period: r(4...7), phase: r(0...(2 * .pi)), curl: r(-10...10), leaves: leaves,
                                pulseEvery: every, pulseOffset: r(0...every)))
        }
        self.lianas = lianas

        var trees: [Tree] = []
        for side in [-1.0, 1.0] {
            let root = Vec2(side < 0 ? -6 : w + 6, h + 6)
            // Mostly up, leaning in from the corner.
            let trunk = -Double.pi / 2 + side * -0.32
            var segs = [Segment(parent: nil, angle: trunk, length: h * r(0.15...0.19), depth: 0, phase: r(0...6), isTip: true)]
            var open = [0]
            let maxDepth = 4
            while !open.isEmpty {
                let p = open.removeFirst()
                let parent = segs[p]
                guard parent.depth < maxDepth else { continue }
                // Two branches, sometimes one higher up; the inner one a little longer, so the crown leans in.
                let children = parent.depth >= 2 && rng.next() < 0.25 ? 1 : 2
                for c in 0..<children {
                    let spread = r(0.3...0.55)
                    let dir: Double = children == 1 ? (rng.next() < 0.5 ? -1 : 1) : (c == 0 ? -1 : 1)
                    let inner = dir == side * -1 ? 1.08 : 0.92
                    segs[p].isTip = false
                    segs.append(Segment(parent: p, angle: dir * spread, length: parent.length * r(0.66...0.78) * inner,
                                        depth: parent.depth + 1, phase: r(0...6), isTip: true))
                    open.append(segs.count - 1)
                }
            }
            trees.append(Tree(root: root, segments: segs, maxDepth: segs.map(\.depth).max() ?? 0))
        }
        self.trees = trees

        var spores: [Spore] = []
        for i in 0..<max(0, sporeCount) {
            spores.append(Spore(x: r(0...w), y: r(0...h), rise: r(4...11), wobble: r(5...14), period: r(3...7),
                                phase: r(0...(2 * .pi)), size: r(1.4...2.8), glows: i % 4 == 0))
        }
        self.spores = spores
    }

    // MARK: lianas

    /// Liana `i` at `time` as a polyline from the anchor (just above the top edge) to the tip. `extraSway` (pt)
    /// adds to the tip's swing, for a liana a distraction sets swinging.
    public func lianaPoints(_ i: Int, time: Double, extraSway: Double = 0, count: Int = 18) -> [Vec2] {
        let l = lianas[i]
        let wave = 2 * Double.pi * time / l.period + l.phase
        return (0...max(1, count)).map { k in
            let s = Double(k) / Double(max(1, count))
            let swing = (l.sway + extraSway) * pow(s, 1.6) * sin(wave + s * 1.8)
            return Vec2(l.anchorX + swing + l.curl * s * s, -4 + l.length * s)
        }
    }

    /// The point `fraction` (0...1) of the way along a polyline with evenly spaced points, and the direction there
    /// (radians, 0 points right).
    public static func along(_ points: [Vec2], _ fraction: Double) -> (point: Vec2, angle: Double) {
        guard points.count >= 2 else { return (points.first ?? .zero, Double.pi / 2) }
        let f = min(1, max(0, fraction)) * Double(points.count - 1)
        let k = min(points.count - 2, Int(f))
        let a = points[k], b = points[k + 1]
        let u = f - Double(k)
        return (a + (b - a) * u, atan2(b.y - a.y, b.x - a.x))
    }

    /// The light pulse on liana `i` at `time`: how far down it is (0...1, nil when none runs) and how far the flash
    /// at the tip has gone once it arrived (0...1, nil when none).
    public func pulse(_ i: Int, time: Double) -> (at: Double?, flash: Double?) {
        let l = lianas[i]
        let local = Self.wrap(time - l.pulseOffset, l.pulseEvery)
        if local < Self.pulseTravelSec {
            let u = local / Self.pulseTravelSec
            return (u * u * (3 - 2 * u), nil)
        }
        if local < Self.pulseTravelSec + Self.pulseFlashSec {
            return (nil, (local - Self.pulseTravelSec) / Self.pulseFlashSec)
        }
        return (nil, nil)
    }

    // MARK: trees

    /// Tree `t` at `time`, grown to `growth` (0 nothing ... 1 whole): the trunk grows first, then each level of
    /// branches after the one below it. Branches sway more the further out they are.
    public func twigs(_ t: Int, time: Double, growth: Double = 1) -> [Twig] {
        let tree = trees[t]
        let levels = Double(tree.maxDepth + 1)
        let grown = min(1, max(0, growth)) * levels
        var absAngle = [Double](repeating: 0, count: tree.segments.count)
        var end = [Vec2](repeating: tree.root, count: tree.segments.count)
        var shown = [Bool](repeating: false, count: tree.segments.count)
        var out: [Twig] = []
        for (i, s) in tree.segments.enumerated() {
            let base = s.parent.map { absAngle[$0] } ?? 0
            let start = s.parent.map { end[$0] } ?? tree.root
            let sway = 0.03 * Double(s.depth) * sin(time * 0.7 + s.phase)
            absAngle[i] = base + s.angle + sway
            let f = min(1, max(0, grown - Double(s.depth)))
            let parentShown = s.parent.map { shown[$0] } ?? true
            let b = start + Vec2(cos(absAngle[i]), sin(absAngle[i])) * (s.length * f)
            end[i] = b
            guard parentShown, f > 0 else { continue }
            shown[i] = true
            out.append(Twig(a: start, b: b, depth: s.depth, isTip: s.isTip, index: i))
        }
        return out
    }

    /// The points from the root of tree `t` to the end of segment `tip`, at `time`.
    public func path(tree t: Int, to tip: Int, time: Double) -> [Vec2] {
        let twigs = twigs(t, time: time)
        var byIndex: [Int: Twig] = [:]
        for w in twigs { byIndex[w.index] = w }
        var chain: [Int] = []
        var i: Int? = tip
        while let k = i, k < trees[t].segments.count {
            chain.append(k)
            i = trees[t].segments[k].parent
        }
        var points = [trees[t].root]
        for k in chain.reversed() { if let w = byIndex[k] { points.append(w.b) } }
        return points
    }

    // MARK: spores

    /// Spore `i` at `time`: where it is, and how bright it twinkles (0.2...1).
    public func spore(_ i: Int, time: Double) -> (position: Vec2, twinkle: Double) {
        let s = spores[i]
        let span = size.y + 20
        let y = Self.wrap(s.y - s.rise * time + 10, span) - 10
        let x = s.x + s.wobble * sin(2 * Double.pi * time / s.period + s.phase)
        return (Vec2(x, y), 0.6 + 0.4 * sin(time * 1.7 + s.phase * 3))
    }

    static func wrap(_ v: Double, _ period: Double) -> Double {
        guard period > 0 else { return 0 }
        let r = v.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }
}

/// A brief movement at the edge of the play that tries to catch the eye during rhythm play.
public struct Distraction: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// A glowing firefly flies along a curve.
        case firefly
        /// A flower opens and closes at a liana's tip.
        case bloom
        /// A winged seed spins down from the top edge.
        case seed
        /// A light runs up a tree from the root to one branch tip and sparks there.
        case surge
        /// A liana swings wide.
        case swing
    }

    public var kind: Kind
    /// Track time (s) it starts at, and how long it lasts.
    public var start: Double
    public var duration: Double
    /// firefly and seed: the curve's ends and control points (screen pt).
    public var from: Vec2
    public var c1: Vec2
    public var c2: Vec2
    public var to: Vec2
    /// bloom and swing: the liana; surge: the tree.
    public var index: Int
    /// surge: the segment the light runs to.
    public var tip: Int

    public init(kind: Kind, start: Double, duration: Double, from: Vec2 = .zero, c1: Vec2 = .zero, c2: Vec2 = .zero,
                to: Vec2 = .zero, index: Int = 0, tip: Int = 0) {
        self.kind = kind; self.start = start; self.duration = duration
        self.from = from; self.c1 = c1; self.c2 = c2; self.to = to
        self.index = index; self.tip = tip
    }

    /// 0...1 through it at `time`, nil before or after.
    public func progress(at time: Double) -> Double? {
        guard duration > 0, time >= start, time <= start + duration else { return nil }
        return (time - start) / duration
    }

    /// Where a firefly or a seed is at `time` (nil before or after, and for the other kinds).
    public func position(at time: Double) -> Vec2? {
        guard kind == .firefly || kind == .seed, let u = progress(at: time) else { return nil }
        return Self.bezier(from, c1, c2, to, u)
    }

    static func bezier(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ u: Double) -> Vec2 {
        let v = 1 - u
        return p0 * (v * v * v) + p1 * (3 * v * v * u) + p2 * (3 * v * u * u) + p3 * (u * u * u)
    }
}

public enum DistractionPlan {
    /// Seconds between two distractions on each level: easy is calm, hard is busy.
    public static func gap(_ level: RhythmLevel) -> ClosedRange<Double> {
        switch level {
        case .easy: return 6...9
        case .normal: return 3.5...5.5
        case .hard: return 2.2...3.4
        }
    }

    /// The play area the notes are placed in (ChartGenerator.area), in screen pt.
    public static func noteArea(_ size: Vec2) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let a = ChartGenerator.area
        return (a.x.lowerBound * size.x...a.x.upperBound * size.x, a.y.lowerBound * size.y...a.y.upperBound * size.y)
    }

    /// The distractions of one rhythm play between track times `from` and `to` (s). On easy and normal they keep to
    /// the margins outside the note area; on hard some fireflies and seeds cross it.
    public static func make(level: RhythmLevel, garden: Garden, from: Double, to: Double, seed: UInt64) -> [Distraction] {
        var rng = Rng(seed: seed)
        func r(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * rng.next() }
        let w = garden.size.x, h = garden.size.y
        let area = noteArea(garden.size)
        let crossing = level == .hard ? 0.35 : 0
        var out: [Distraction] = []
        var t = from + r(1.5...3)
        while true {
            let roll = rng.next()
            let kind: Distraction.Kind = roll < 0.35 ? .firefly : roll < 0.55 ? .bloom : roll < 0.7 ? .seed
                : roll < 0.85 ? .surge : .swing
            var d = Distraction(kind: kind, start: t, duration: 1)
            switch kind {
            case .firefly:
                d.duration = r(2.2...3.2)
                if rng.next() < crossing {
                    // Corner to corner, through the note area.
                    let leftToRight = rng.next() < 0.5
                    d.from = Vec2(leftToRight ? -20 : w + 20, r(0...(h * 0.3)))
                    d.to = Vec2(leftToRight ? w + 20 : -20, r((h * 0.7)...h))
                } else {
                    // Along the top or the bottom margin.
                    let top = rng.next() < 0.5
                    let band = top ? (h * 0.03)...max(h * 0.03, area.y.lowerBound - 18)
                        : min(h * 0.97, area.y.upperBound + 18)...(h * 0.97)
                    let leftToRight = rng.next() < 0.5
                    d.from = Vec2(leftToRight ? -20 : w + 20, r(band))
                    d.to = Vec2(leftToRight ? w + 20 : -20, r(band))
                    d.c1 = Vec2(w * r(0.25...0.4), r(band))
                    d.c2 = Vec2(w * r(0.6...0.75), r(band))
                }
                if d.c1 == .zero {
                    d.c1 = d.from + (d.to - d.from) * 0.33 + Vec2(0, r(-40...40))
                    d.c2 = d.from + (d.to - d.from) * 0.66 + Vec2(0, r(-40...40))
                }
            case .seed:
                d.duration = r(2.6...3.4)
                let x: Double
                if rng.next() < crossing {
                    x = r((w * 0.2)...(w * 0.8))
                } else {
                    // In the side margins.
                    let left = rng.next() < 0.5
                    x = left ? r((w * 0.01)...max(w * 0.01, area.x.lowerBound - 16))
                        : r(min(w * 0.99, area.x.upperBound + 16)...(w * 0.99))
                }
                let drift = r(-1...1) * min(16, w * 0.02)
                d.from = Vec2(x, -14)
                d.to = Vec2(x + drift, h * r(0.75...0.95))
                d.c1 = Vec2(x - drift, h * 0.3)
                d.c2 = Vec2(x + 2 * drift, h * 0.6)
            case .bloom:
                d.duration = 1.8
                d.index = garden.lianas.isEmpty ? 0 : Int(rng.next() * Double(garden.lianas.count)) % garden.lianas.count
            case .surge:
                d.duration = 0.9
                d.index = garden.trees.isEmpty ? 0 : Int(rng.next() * Double(garden.trees.count)) % garden.trees.count
                let tips = garden.trees.isEmpty ? [] : garden.trees[d.index].segments.indices.filter { garden.trees[d.index].segments[$0].isTip }
                d.tip = tips.isEmpty ? 0 : tips[Int(rng.next() * Double(tips.count)) % tips.count]
            case .swing:
                d.duration = 2.2
                d.index = garden.lianas.isEmpty ? 0 : Int(rng.next() * Double(garden.lianas.count)) % garden.lianas.count
            }
            guard t + d.duration <= to else { break }
            if (kind == .bloom || kind == .swing) && garden.lianas.isEmpty { t += r(gap(level)); continue }
            if kind == .surge && garden.trees.isEmpty { t += r(gap(level)); continue }
            out.append(d)
            t += r(gap(level))
        }
        return out
    }

    /// A stable seed from a text (FNV-1a), so a track's distractions are the same on every play.
    public static func seed(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }
}
