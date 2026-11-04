import Foundation

/// Ridge regression from a feature vector to a screen point (screen pt).
/// Features are standardised; the bias is not penalised. A NaN feature (no value this frame, such as a missing
/// pupil) counts as the calibration average, so it adds nothing to the prediction.
public struct RidgeModel: Codable, Sendable {
    public var mean: [Double]
    public var scale: [Double]
    public var wx: [Double]   // [bias, w1...wd]
    public var wy: [Double]
    public var featureSet: String
    /// Smallest and largest value of each feature seen during calibration.
    public var lo: [Double]
    public var hi: [Double]

    /// How far past the calibrated range a feature may go, as a share of that range, before it is clamped.
    /// The quadratic terms otherwise extrapolate to thousands of points when the eyes leave the screen.
    public static let clampMargin = 0.25
    /// How far past the calibrated range the lookAt hit may go before the player counts as looking away.
    public static let lookingAwayMargin = 1.0

    public func predict(_ x: [Double]) -> Vec2 {
        var px = wx[0], py = wy[0]
        for j in 0..<min(x.count, mean.count) where !x[j].isNaN {
            let span = hi[j] - lo[j]
            let v = min(max(x[j], lo[j] - Self.clampMargin * span), hi[j] + Self.clampMargin * span)
            let z = (v - mean[j]) / scale[j]
            px += wx[j + 1] * z
            py += wy[j + 1] * z
        }
        return Vec2(px, py)
    }

    /// True when any of `features` lies further outside its calibrated range than `margin` times that range.
    /// With the lookAt hit (features 0 and 1 of `GazeFeatures.vector`) this means the eyes point well off the
    /// screen: a glance away, which should hide the aim rather than send it flying. NaN never counts.
    public func outOfRange(_ x: [Double], features: Range<Int>, margin: Double) -> Bool {
        for j in features where j < x.count && j < lo.count && !x[j].isNaN {
            let span = hi[j] - lo[j]
            if x[j] < lo[j] - margin * span || x[j] > hi[j] + margin * span { return true }
        }
        return false
    }

    /// `lambda` is per sample: the penalty added to the normal equations is lambda * n.
    public static func fit(features X: [[Double]], targets Y: [Vec2], lambda: Double = 0.01, featureSet: String = "") -> RidgeModel? {
        let n = X.count
        guard n > 0, n == Y.count, let d = X.first?.count, d > 0, X.allSatisfy({ $0.count == d }) else { return nil }
        var mean = [Double](repeating: 0, count: d), scale = [Double](repeating: 0, count: d)
        var lo = [Double](repeating: .infinity, count: d), hi = [Double](repeating: -.infinity, count: d)
        var count = [Double](repeating: 0, count: d)
        for x in X { for j in 0..<d where !x[j].isNaN { mean[j] += x[j]; count[j] += 1; lo[j] = min(lo[j], x[j]); hi[j] = max(hi[j], x[j]) } }
        for j in 0..<d { mean[j] = count[j] > 0 ? mean[j] / count[j] : 0 }
        for x in X { for j in 0..<d where !x[j].isNaN { scale[j] += (x[j] - mean[j]) * (x[j] - mean[j]) } }
        for j in 0..<d {
            scale[j] = count[j] > 0 ? (scale[j] / count[j]).squareRoot() : 0
            if scale[j] < 1e-12 { scale[j] = 1 }
            if count[j] == 0 { lo[j] = 0; hi[j] = 0 }
        }
        let Z = X.map { x in [1.0] + (0..<d).map { x[$0].isNaN ? 0 : (x[$0] - mean[$0]) / scale[$0] } }
        let D = d + 1
        var A = [[Double]](repeating: [Double](repeating: 0, count: D), count: D)
        var bx = [Double](repeating: 0, count: D), by = [Double](repeating: 0, count: D)
        for k in 0..<n {
            let z = Z[k]
            for i in 0..<D {
                for j in 0..<D { A[i][j] += z[i] * z[j] }
                bx[i] += z[i] * Y[k].x
                by[i] += z[i] * Y[k].y
            }
        }
        for i in 1..<D { A[i][i] += lambda * Double(n) }
        guard let wx = solve(A, bx), let wy = solve(A, by) else { return nil }
        return RidgeModel(mean: mean, scale: scale, wx: wx, wy: wy, featureSet: featureSet, lo: lo, hi: hi)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var M = a
        var v = b
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(M[r][c]) > abs(M[p][c]) { p = r }
            if abs(M[p][c]) < 1e-12 { return nil }
            M.swapAt(c, p); v.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = M[r][c] / M[c][c]
                if f == 0 { continue }
                for j in c..<n { M[r][j] -= f * M[c][j] }
                v[r] -= f * v[c]
            }
        }
        return (0..<n).map { v[$0] / M[$0][$0] }
    }
}

/// Calibration and check layouts as fractions of the screen (portrait).
public enum CalibrationLayout {
    /// 9 calibration points.
    public static let calibration: [Vec2] = [0.1, 0.5, 0.9].flatMap { y in [0.1, 0.5, 0.9].map { x in Vec2(x, y) } }
    /// 13 check points, none of them shared with the calibration grid.
    public static let validation: [Vec2] = [
        Vec2(0.3, 0.3), Vec2(0.7, 0.3), Vec2(0.3, 0.7), Vec2(0.7, 0.7),
        Vec2(0.5, 0.2), Vec2(0.5, 0.8), Vec2(0.2, 0.5), Vec2(0.8, 0.5),
        Vec2(0.15, 0.25), Vec2(0.85, 0.25), Vec2(0.15, 0.75), Vec2(0.85, 0.75), Vec2(0.5, 0.4),
    ]
    /// Fraction -> screen pt.
    public static func point(_ f: Vec2, in size: Vec2) -> Vec2 { Vec2(f.x * size.x, f.y * size.y) }
}
