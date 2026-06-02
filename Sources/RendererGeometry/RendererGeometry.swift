import Foundation

/// Public catalog over the generated geometry renderers + the live panning engine.
///
/// Output convention: indices 0..29 = the 30 dome speakers (id = index + 1); index 30 = the sub.
/// The dome matrix is a flat gain map. The sub (output 30) is produced by the bass-management
/// stage (a mono bass downmix, low-passed ~400 Hz) — frequency-dependent, so it is NOT a flat
/// gain here; `subInputs` lists what feeds it. The app low-passes that bus; the club's own sub
/// crossover does the final cut.
public enum RendererGeometry {
    public static var all: [GeneratedRenderer] { GeneratedRenderers.all }
    public static func renderer(layout: String) -> GeneratedRenderer? { GeneratedRenderers.byLayout(layout) }
    public static func renderers(channelCount n: Int) -> [GeneratedRenderer] { GeneratedRenderers.byChannelCount(n) }

    public static let domeSpeakerCount = GeneratedRenderers.domeSpeakerCount   // 30
    public static let subOutputIndex = GeneratedRenderers.subOutputIndex       // 30
    public static let totalOutputs = GeneratedRenderers.totalOutputs           // 31

    /// Dense dome matrix: rows = input channels, columns = the 30 dome speakers.
    public static func domeMatrix(_ r: GeneratedRenderer) -> [[Double]] {
        r.domeKernel.map { entries in
            var row = [Double](repeating: 0, count: domeSpeakerCount)
            for e in entries where e.output >= 0 && e.output < domeSpeakerCount { row[e.output] = e.gain }
            return row
        }
    }

    /// Parametric Stereo: dome matrix computed live for a given L↔R angle (0...180°).
    /// L at −angle/2, R at +angle/2, each panned onto the dome. 0° = mono, 180° = hard sides.
    public static func stereoDomeMatrix(angleDegrees: Double) -> [[Double]] {
        let a = max(0, min(180, angleDegrees))
        return [SphereGeometry.pan(azimuthDeg: -a / 2), SphereGeometry.pan(azimuthDeg: a / 2)]
    }

    /// Input channel indices that feed the sub: the mono bass downmix (full-range) and any discrete LFE.
    public static func subInputs(_ r: GeneratedRenderer) -> (fullRange: [Int], lfe: [Int]) {
        (r.subBass.fullRangeInputs, r.subBass.lfeInputs)
    }

    /// Full input-major gain matrix (inputCount × 31), ready to wrap in the app's `RendererMatrix`.
    /// Outputs 0..29 = dome; output 30 (sub) is 0 here and supplied by the bass-management filter.
    public static func gainMatrix(_ r: GeneratedRenderer) -> [[Double]] {
        domeMatrix(r).map { $0 + [0.0] }
    }
}
