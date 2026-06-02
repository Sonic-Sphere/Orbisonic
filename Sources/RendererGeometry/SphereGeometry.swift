import Foundation

/// Direction panning onto the 30-speaker dome — the geometry engine behind every renderer.
/// Used to compute the parametric Stereo bed live and to verify the generated kernels.
public enum SphereGeometry {
    public static let cosineSharpness = 3.0
    public static let perSpeakerPowerCap = 0.22
    private static let capIterations = 6

    /// Unit-normalized dome speaker directions (index 0..29, id = index + 1).
    public static let unitSpeakers: [(x: Double, y: Double, z: Double)] = GeneratedRenderers.sphereSpeakers.map {
        let m = ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot()
        return m > 0 ? (x: $0.x / m, y: $0.y / m, z: $0.z / m) : $0
    }

    /// Azimuth (deg from front, + to the right) of a dome speaker output index.
    public static func azimuthDeg(ofOutput index: Int) -> Double {
        guard index >= 0, index < unitSpeakers.count else { return 0 }
        let s = unitSpeakers[index]
        return atan2(s.x, s.y) * 180 / .pi
    }

    public static func direction(azimuthDeg: Double, elevationDeg: Double = 0) -> (x: Double, y: Double, z: Double) {
        let a = azimuthDeg * .pi / 180, e = elevationDeg * .pi / 180
        return (x: sin(a) * cos(e), y: cos(a) * cos(e), z: sin(e))
    }

    private static func normalizePower(_ v: [Double]) -> [Double] {
        let p = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return p > 0 ? v.map { $0 / p } : v
    }

    static func capAndNormalize(_ v: [Double]) -> [Double] {
        let cap = perSpeakerPowerCap.squareRoot()
        var r = normalizePower(v)
        for _ in 0..<capIterations {
            var clipped = false
            for i in r.indices where r[i] > cap { r[i] = cap; clipped = true }
            r = normalizePower(r)
            if !clipped { break }
        }
        return normalizePower(r)
    }

    /// Pan a unit direction across the 30 dome speakers (cosine-power + per-speaker power cap).
    /// Returns a dense 30-element gain vector with sum of squares ≈ 1.
    public static func pan(azimuthDeg: Double, elevationDeg: Double = 0) -> [Double] {
        let d = direction(azimuthDeg: azimuthDeg, elevationDeg: elevationDeg)
        let raw = unitSpeakers.map { sp -> Double in
            let dot = d.x * sp.x + d.y * sp.y + d.z * sp.z
            return dot > 0 ? pow(dot, cosineSharpness) : 0
        }
        return capAndNormalize(raw)
    }
}
