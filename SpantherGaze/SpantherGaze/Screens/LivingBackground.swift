import QuartzCore
import SwiftUI

/// Draws a `Garden` (GazeCore) in the atlas look: trees and lianas in thin ink with moss leaves, node dots where
/// branches fork (the futuristic part: the plants read a little like circuits, and light runs along them), spores
/// as tiny stars, a few of them glowing amber. Distractions, when given, are drawn brighter on top.
/// Screen pt, y down. `time` is host time (CACurrentMediaTime), so the sway carries on from screen to screen.
enum GardenPainter {
    static func draw(_ g: inout GraphicsContext, _ garden: Garden, time: Double, growth: Double = 1,
                     distractions: [Distraction] = [], trackTime: Double? = nil) {
        var active: [(Distraction, Double)] = []
        if let t = trackTime {
            for d in distractions {
                if d.start > t { break }
                if let u = d.progress(at: t) { active.append((d, u)) }
            }
        }
        for i in garden.trees.indices { drawTree(&g, garden, i, time: time, growth: growth) }
        for i in garden.lianas.indices {
            var extra = 0.0
            for (d, u) in active where d.kind == .swing && d.index == i { extra += 24 * sin(Double.pi * u) }
            drawLiana(&g, garden, i, time: time, extraSway: extra, growth: growth)
        }
        for i in garden.spores.indices { drawSpore(&g, garden, i, time: time) }
        for (d, u) in active { drawDistraction(&g, garden, d, u, time: time, trackTime: trackTime ?? 0) }
    }

    private static func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }

    private static func dot(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    private static func drawTree(_ g: inout GraphicsContext, _ garden: Garden, _ t: Int, time: Double, growth: Double) {
        for w in garden.twigs(t, time: time, growth: growth) {
            var line = Path()
            line.move(to: cg(w.a))
            line.addLine(to: cg(w.b))
            let width = CGFloat(0.6 + 2.6 * pow(0.68, Double(w.depth)))
            g.stroke(line, with: .color(Atlas.ink.opacity(0.2)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            if w.depth > 0 {
                g.stroke(dot(cg(w.a), 2), with: .color(Atlas.ink.opacity(0.24)), lineWidth: 0.8)
            }
            if w.isTip, w.a.distance(to: w.b) > 2 {
                let angle = atan2(w.b.y - w.a.y, w.b.x - w.a.x)
                g.fill(Atlas.leaf(cg(w.b), 9, angle), with: .color(Atlas.moss.opacity(0.32)))
            }
        }
    }

    /// A smooth line through the points (quadratic curves through the midpoints).
    private static func smooth(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        guard pts.count > 2 else {
            if let last = pts.last { p.addLine(to: last) }
            return p
        }
        for k in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[k].x + pts[k + 1].x) / 2, y: (pts[k].y + pts[k + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[k])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    private static func drawLiana(_ g: inout GraphicsContext, _ garden: Garden, _ i: Int, time: Double,
                                  extraSway: Double, growth: Double) {
        let l = garden.lianas[i]
        var pts = garden.lianaPoints(i, time: time, extraSway: extraSway)
        // While the garden grows in, the lianas unroll from the top.
        let shown = min(1, max(0, growth * 1.25))
        if shown < 1 {
            let keep = max(2, Int(Double(pts.count) * shown))
            pts = Array(pts.prefix(keep))
            if shown <= 0 { return }
        }
        let line = smooth(pts.map(cg))
        g.stroke(line, with: .color(Atlas.ink.opacity(0.26)), style: StrokeStyle(lineWidth: CGFloat(l.width), lineCap: .round))
        for leaf in l.leaves where leaf.at <= shown {
            let at = Garden.along(pts, leaf.at / shown)
            let flutter = 0.14 * sin(time * 2.1 + leaf.at * 9 + l.phase)
            let angle = at.angle + leaf.side * 1.0 + flutter
            let base = cg(at.point)
            let shape = Atlas.leaf(base, CGFloat(leaf.size), angle)
            g.fill(shape, with: .color(Atlas.moss.opacity(0.3)))
            g.stroke(shape, with: .color(Atlas.ink.opacity(0.22)), lineWidth: 0.6)
            g.fill(dot(base, 0.9), with: .color(Atlas.ink.opacity(0.4)))
        }
        guard shown >= 1, let tip = pts.last else { return }
        let pulse = garden.pulse(i, time: time)
        if let flash = pulse.flash {
            let r = CGFloat(2.4 + 7 * flash)
            g.stroke(dot(cg(tip), r), with: .color(Atlas.moss.opacity(0.55 * (1 - flash))), lineWidth: 1.2)
            g.fill(dot(cg(tip), 2.6), with: .color(Atlas.moss.opacity(0.9 - 0.5 * flash)))
        } else {
            g.fill(dot(cg(tip), 2.2), with: .color(Atlas.ink.opacity(0.35)))
        }
        if let at = pulse.at {
            for k in (0..<4).reversed() {
                let p = cg(Garden.along(pts, max(0, at - Double(k) * 0.035)).point)
                let fade = 1 - Double(k) / 4
                if k == 0 { g.fill(dot(p, 7), with: .color(Atlas.moss.opacity(0.15))) }
                g.fill(dot(p, CGFloat(2.2 - 0.3 * Double(k))), with: .color(Atlas.moss.opacity(0.85 * fade)))
            }
        }
    }

    private static func drawSpore(_ g: inout GraphicsContext, _ garden: Garden, _ i: Int, time: Double) {
        let s = garden.spores[i]
        let (pos, twinkle) = garden.spore(i, time: time)
        let p = cg(pos)
        if s.glows {
            g.fill(dot(p, 6), with: .color(Atlas.amber.opacity(0.14 * twinkle)))
            g.fill(Atlas.star(p, CGFloat(s.size + 0.6)), with: .color(Atlas.amber.opacity(0.8 * twinkle)))
        } else {
            g.fill(Atlas.star(p, CGFloat(s.size)), with: .color(Atlas.ink.opacity(0.24 * twinkle)))
        }
    }

    private static func drawDistraction(_ g: inout GraphicsContext, _ garden: Garden, _ d: Distraction, _ u: Double,
                                        time: Double, trackTime: Double) {
        let fade = min(1, u / 0.12, (1 - u) / 0.12)
        switch d.kind {
        case .firefly:
            for k in (0..<8).reversed() {
                guard let q = d.position(at: trackTime - Double(k) * 0.035) else { continue }
                let p = cg(q + Vec2(0, 5 * sin((trackTime - Double(k) * 0.035) * 11)))
                if k == 0 {
                    g.fill(dot(p, 15), with: .color(Atlas.amber.opacity(0.16 * fade)))
                    g.fill(dot(p, 6.5), with: .color(Atlas.amber.opacity(0.35 * fade)))
                    g.fill(dot(p, 2.8), with: .color(Atlas.amber.opacity(0.95 * fade)))
                    g.fill(dot(p, 1.1), with: .color(Atlas.onAccent.opacity(fade)))
                } else {
                    g.fill(dot(p, CGFloat(2.2 - 0.2 * Double(k))), with: .color(Atlas.amber.opacity(0.5 * fade * (1 - Double(k) / 8))))
                }
            }
        case .seed:
            guard let q = d.position(at: trackTime) else { return }
            let p = cg(q)
            let spin = u * 7 * Double.pi
            var gg = g
            gg.opacity = fade
            gg.fill(Atlas.leaf(p, 17, spin, width: 5), with: .color(Atlas.ink.opacity(0.5)))
            gg.stroke(Atlas.leaf(p, 17, spin, width: 5), with: .color(Atlas.ink.opacity(0.6)), lineWidth: 0.6)
            gg.fill(dot(p, 2.6), with: .color(Atlas.ink.opacity(0.75)))
        case .bloom:
            guard d.index < garden.lianas.count, let tip = garden.lianaPoints(d.index, time: time).last else { return }
            let open = u < 0.3 ? u / 0.3 : u > 0.75 ? (1 - u) / 0.25 : 1
            let c = cg(tip)
            g.fill(dot(c, CGFloat(16 * open)), with: .color(Atlas.amber.opacity(0.14 * open)))
            for k in 0..<6 {
                let angle = time * 0.6 + Double(k) * Double.pi / 3
                let petal = Atlas.leaf(c, CGFloat(5 + 10 * open), angle, width: CGFloat(4.5 * open))
                g.fill(petal, with: .color(Atlas.amber.opacity(0.8 * open)))
                g.stroke(petal, with: .color(Atlas.ink.opacity(0.35 * open)), lineWidth: 0.6)
            }
            g.fill(dot(c, 2.6), with: .color(Atlas.ink.opacity(0.6)))
        case .surge:
            guard d.index < garden.trees.count else { return }
            let path = garden.path(tree: d.index, to: d.tip, time: time)
            guard path.count >= 2 else { return }
            var lengths = [0.0]
            for k in 1..<path.count { lengths.append(lengths[k - 1] + path[k].distance(to: path[k - 1])) }
            let total = max(1, lengths.last ?? 1)
            func point(_ f: Double) -> CGPoint {
                let s = min(1, max(0, f)) * total
                let k = max(1, lengths.firstIndex { $0 >= s } ?? path.count - 1)
                let span = max(1e-6, lengths[k] - lengths[k - 1])
                return cg(path[k - 1] + (path[k] - path[k - 1]) * ((s - lengths[k - 1]) / span))
            }
            let run = 0.75
            if u < run {
                let f = u / run
                for k in (0..<5).reversed() {
                    let p = point(f - Double(k) * 0.04)
                    if k == 0 { g.fill(dot(p, 9), with: .color(Atlas.amber.opacity(0.2))) }
                    g.fill(dot(p, CGFloat(2.6 - 0.35 * Double(k))), with: .color(Atlas.amber.opacity(0.95 * (1 - Double(k) / 5))))
                }
            } else {
                let k = (u - run) / (1 - run)
                let c = point(1)
                var rays = Path()
                for r in 0..<6 {
                    let a = Double(r) * Double.pi / 3 + 0.3
                    rays.move(to: Atlas.polar(c, CGFloat(3 + 4 * k), a))
                    rays.addLine(to: Atlas.polar(c, CGFloat(6 + 10 * k), a))
                }
                g.stroke(rays, with: .color(Atlas.amber.opacity(1 - k)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                g.fill(dot(c, CGFloat(3 * (1 - k) + 1)), with: .color(Atlas.amber.opacity(1 - k)))
            }
        case .swing:
            break
        }
    }
}

/// Keeps the garden for the last screen size, so it is not rebuilt on every frame.
final class GardenCache {
    private var garden: Garden?

    func garden(for size: CGSize, seed: UInt64) -> Garden {
        let s = Vec2(Double(size.width), Double(size.height))
        if let g = garden, g.size == s { return g }
        let g = Garden(size: s, seed: seed)
        garden = g
        return g
    }
}

/// The garden as a background view for the screens without a canvas of their own. It does not take touches and
/// is hidden from VoiceOver.
struct LivingBackground: View {
    /// Host time the garden started growing (the app's launch), so it grows in once and not on every screen.
    var growFrom: Double = 0
    static let growSec = 2.4
    @State private var cache = GardenCache()

    var body: some View {
        TimelineView(.animation) { _ in
            let now = CACurrentMediaTime()
            Canvas { g, size in
                let garden = cache.garden(for: size, seed: Atlas.gardenSeed)
                let growth = min(1, max(0, (now - growFrom) / Self.growSec))
                GardenPainter.draw(&g, garden, time: now, growth: growth)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
