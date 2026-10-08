import Foundation

/// Ridge regression from a feature vector to a screen point (screen pt).
/// Features are standardised; the bias is not penalised.
public struct RidgeModel: Codable, Sendable {
    public var mean: [Double]
    public var scale: [Double]
    public var wx: [Double]   // [bias, w1...wd]
    public var wy: [Double]
    public var featureSet: String

    public func predict(_ x: [Double]) -> Vec2 {
        var px = wx[0], py = wy[0]
        for j in 0..<min(x.count, mean.count) {
            let z = (x[j] - mean[j]) / scale[j]
            px += wx[j + 1] * z
            py += wy[j + 1] * z
        }
        return Vec2(px, py)
    }

    /// `lambda` is per sample: the penalty added to the normal equations is lambda * n.
    public static func fit(features X: [[Double]], targets Y: [Vec2], lambda: Double = 0.01, featureSet: String = "") -> RidgeModel? {
        let n = X.count
        guard n > 0, n == Y.count, let d = X.first?.count, d > 0 else { return nil }
        var mean = [Double](repeating: 0, count: d), scale = [Double](repeating: 0, count: d)
        for x in X { for j in 0..<d { mean[j] += x[j] / Double(n) } }
        for x in X { for j in 0..<d { scale[j] += (x[j] - mean[j]) * (x[j] - mean[j]) / Double(n) } }
        for j in 0..<d { scale[j] = scale[j].squareRoot(); if scale[j] < 1e-12 { scale[j] = 1 } }
        let Z = X.map { x in [1.0] + (0..<d).map { (x[$0] - mean[$0]) / scale[$0] } }
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
        return RidgeModel(mean: mean, scale: scale, wx: wx, wy: wy, featureSet: featureSet)
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
