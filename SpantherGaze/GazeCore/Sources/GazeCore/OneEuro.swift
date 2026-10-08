import Foundation

/// One Euro filter (Casiez, Roussel, Vogel 2012). Low lag on fast moves, strong smoothing when still.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    private var x: Double?
    private var dx = 0.0
    private var lastT = 0.0

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let r = 2 * Double.pi * cutoff * dt
        return r / (r + 1)
    }

    /// `t` in seconds.
    public mutating func filter(_ value: Double, t: Double) -> Double {
        guard let prev = x else { x = value; lastT = t; return value }
        let dt = max(1e-3, t - lastT)
        lastT = t
        let rawD = (value - prev) / dt
        dx += Self.alpha(dCutoff, dt) * (rawD - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let out = prev + Self.alpha(cutoff, dt) * (value - prev)
        x = out
        return out
    }

    public mutating func reset() { x = nil; dx = 0 }
}

/// Filters a screen point (screen pt). beta is tuned for point units: ~0.007 per pt/s.
public struct OneEuroFilter2D: Sendable {
    public var fx: OneEuroFilter
    public var fy: OneEuroFilter
    public init(minCutoff: Double = 1.0, beta: Double = 0.007) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        fy = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }
    public mutating func filter(_ p: Vec2, t: Double) -> Vec2 { Vec2(fx.filter(p.x, t: t), fy.filter(p.y, t: t)) }
    public mutating func reset() { fx.reset(); fy.reset() }
}
