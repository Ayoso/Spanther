import simd

// ARKit (simd, Float) -> GazeCore (Double). No coordinate change happens here; spaces stay as ARKit defines them.

extension Mat4 {
    init(_ t: simd_float4x4) {
        func col(_ c: simd_float4) -> [Double] { [Double(c.x), Double(c.y), Double(c.z), Double(c.w)] }
        self.init(columns: col(t.columns.0), col(t.columns.1), col(t.columns.2), col(t.columns.3))
    }
}

extension Vec3 {
    init(_ v: simd_float3) { self.init(Double(v.x), Double(v.y), Double(v.z)) }
}
