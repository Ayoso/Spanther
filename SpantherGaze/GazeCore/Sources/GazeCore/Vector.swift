import Foundation

/// 2D vector. Used for screen points (screen pt, origin top-left, y down) unless a function says otherwise.
public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to o: Vec2) -> Double { (self - o).length }
}

/// 3D vector in metres. Which space it lives in (face, world, camera) is stated by the caller.
public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, k: Double) -> Vec3 { Vec3(a.x * k, a.y * k, a.z * k) }
    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vec3 { let l = length; return l > 0 ? self * (1 / l) : self }
}

/// 4x4 matrix stored column-major, matching simd_float4x4 / ARKit transforms.
/// `m[c * 4 + r]` is row r, column c.
public struct Mat4: Equatable, Sendable {
    public var m: [Double]

    public init(columns c0: [Double], _ c1: [Double], _ c2: [Double], _ c3: [Double]) {
        precondition(c0.count == 4 && c1.count == 4 && c2.count == 4 && c3.count == 4)
        m = c0 + c1 + c2 + c3
    }
    public init(columnMajor values: [Double]) {
        precondition(values.count == 16)
        m = values
    }
    public static let identity = Mat4(columns: [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1])

    public subscript(r: Int, c: Int) -> Double { m[c * 4 + r] }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        var out = [Double](repeating: 0, count: 16)
        for c in 0..<4 { for r in 0..<4 {
            var s = 0.0
            for k in 0..<4 { s += a[r, k] * b[k, c] }
            out[c * 4 + r] = s
        } }
        return Mat4(columnMajor: out)
    }

    /// Transforms a point (w = 1).
    public func point(_ p: Vec3) -> Vec3 {
        Vec3(self[0, 0] * p.x + self[0, 1] * p.y + self[0, 2] * p.z + self[0, 3],
             self[1, 0] * p.x + self[1, 1] * p.y + self[1, 2] * p.z + self[1, 3],
             self[2, 0] * p.x + self[2, 1] * p.y + self[2, 2] * p.z + self[2, 3])
    }
    /// Transforms a direction (w = 0).
    public func direction(_ d: Vec3) -> Vec3 {
        Vec3(self[0, 0] * d.x + self[0, 1] * d.y + self[0, 2] * d.z,
             self[1, 0] * d.x + self[1, 1] * d.y + self[1, 2] * d.z,
             self[2, 0] * d.x + self[2, 1] * d.y + self[2, 2] * d.z)
    }
    public var translation: Vec3 { Vec3(self[0, 3], self[1, 3], self[2, 3]) }
    public var xAxis: Vec3 { Vec3(self[0, 0], self[1, 0], self[2, 0]) }
    public var yAxis: Vec3 { Vec3(self[0, 1], self[1, 1], self[2, 1]) }
    public var zAxis: Vec3 { Vec3(self[0, 2], self[1, 2], self[2, 2]) }

    /// Inverse of a rigid transform (rotation + translation), which every ARKit pose is.
    public var rigidInverse: Mat4 {
        let t = translation
        let r0 = xAxis, r1 = yAxis, r2 = zAxis  // columns of R become rows of R^T
        let tx = -r0.dot(t), ty = -r1.dot(t), tz = -r2.dot(t)
        return Mat4(columns: [r0.x, r1.x, r2.x, 0], [r0.y, r1.y, r2.y, 0], [r0.z, r1.z, r2.z, 0], [tx, ty, tz, 1])
    }

    public static func translation(_ t: Vec3) -> Mat4 {
        Mat4(columns: [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [t.x, t.y, t.z, 1])
    }
    public static func rotationY(_ a: Double) -> Mat4 {
        Mat4(columns: [cos(a), 0, -sin(a), 0], [0, 1, 0, 0], [sin(a), 0, cos(a), 0], [0, 0, 0, 1])
    }
    public static func rotationX(_ a: Double) -> Mat4 {
        Mat4(columns: [1, 0, 0, 0], [0, cos(a), sin(a), 0], [0, -sin(a), cos(a), 0], [0, 0, 0, 1])
    }
}
