import Foundation
import RendererGeometry
import RendererResolver

// Bridge from the geometry render plan (RendererGeometry + RendererResolver) to the app's
// RendererMatrix and the mono sub-bass feed. Part of the geometry-engine integration (#15).
// The render math this relies on is fully unit-tested in the RendererGeometry / RendererResolver
// library targets; this file is the thin app-side adapter.

extension RendererMatrix {
    /// Dome routing for a geometry plan. The sub (output 30) is left at 0 here and produced by the
    /// bass-management stage (mono sum of `plan.subSourceInputs`, low-passed at `plan.subLowPassHz`).
    init(geometryPlan plan: GeometryRenderPlan) {
        self.init(gains: plan.gainMatrix, lfeInputIndexes: [])
    }
}

/// Resolves a source layout to a complete geometry render plan for the live audio path,
/// and renders the dome + mono sub-bass for a block of interleaved-by-channel samples.
enum GeometryRenderBridge {
    static func plan(channelCount: Int,
                     labels: [String]? = nil,
                     layoutTag: String? = nil,
                     sidecarLayoutId: String? = nil) -> GeometryRenderPlan? {
        GeometryRenderPlan(source: SourceLayout(channelCount: channelCount,
                                                labels: labels,
                                                layoutTag: layoutTag,
                                                sidecarLayoutId: sidecarLayoutId))
    }

    /// One-line diagnostics for the resolved renderer (for the diagnostics log / status line).
    static func describe(_ plan: GeometryRenderPlan) -> String {
        "\(plan.resolved.displayName) [\(plan.resolved.layoutId)] via \(plan.resolved.reason); "
            + "sub: \(plan.subSourceInputs.count)-ch mono ≤ \(Int(plan.subLowPassHz)) Hz"
    }
}
