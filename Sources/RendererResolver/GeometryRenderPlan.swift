import Foundation
import RendererGeometry

/// A one-pole low-pass — the gentle ~400 Hz roll-off on the mono sub bus.
/// The club's own sub crossover does the steep final cut; this just band-limits the feed.
public struct OnePoleLowPass: Sendable {
    private var state = 0.0
    private let a: Double
    public init(cutoffHz: Double, sampleRate: Double) {
        let c = max(1.0, min(cutoffHz, sampleRate / 2))
        a = exp(-2.0 * .pi * c / sampleRate)
    }
    public mutating func process(_ x: Double) -> Double {
        state = x * (1 - a) + state * a
        return state
    }
    public mutating func reset() { state = 0 }
}

/// A complete, source-indexed render plan: resolve a source, reorder its channels into the
/// chosen renderer, and expose the dome gain matrix + the mono sub-bass feed.
///
/// `gainMatrix` is `[sourceChannel][31]`: outputs 0..29 = dome speakers, output 30 = sub (left 0 —
/// it is produced by mono-summing `subSourceInputs` and low-passing at `subLowPassHz`).
public struct GeometryRenderPlan: Sendable {
    public let resolved: ResolvedRenderer
    public let channelCount: Int
    public let gainMatrix: [[Double]]
    public let subSourceInputs: [Int]
    public let subLowPassHz: Double

    public init?(source: SourceLayout) {
        guard let resolved = RendererResolver.resolve(source),
              let r = RendererGeometry.renderer(layout: resolved.layoutId),
              r.channelCount == source.channelCount else { return nil }
        self.resolved = resolved
        self.channelCount = source.channelCount
        self.subLowPassHz = r.subBass.lowPassHz

        // Renderer dome rows → source-indexed gain matrix (apply the input permutation).
        let dome = RendererGeometry.domeMatrix(r)
        var src = Array(repeating: [Double](repeating: 0, count: 31), count: source.channelCount)
        for k in 0..<r.channelCount {
            let s = resolved.inputPermutation[k]
            guard s >= 0, s < source.channelCount else { continue }
            for o in 0..<30 { src[s][o] = dome[k][o] }   // output 30 (sub) stays 0 — bass-managed
        }
        self.gainMatrix = src

        // Mono sub feed: renderer full-range + discrete LFE inputs → source channel indices.
        let subRendererInputs = r.subBass.fullRangeInputs + r.subBass.lfeInputs
        self.subSourceInputs = subRendererInputs.compactMap { k in
            (k >= 0 && k < resolved.inputPermutation.count) ? resolved.inputPermutation[k] : nil
        }
    }

    /// The sub sample for one frame: mono sum of the `subSourceInputs` (caller low-passes via `OnePoleLowPass`).
    public func subMonoSum(frame samples: [Double]) -> Double {
        var s = 0.0
        for i in subSourceInputs where i >= 0 && i < samples.count { s += samples[i] }
        return s
    }
}
