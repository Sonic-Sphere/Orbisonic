import Foundation
import RendererGeometry

/// What we know about an incoming source's channel layout.
public struct SourceLayout: Sendable, Equatable {
    public let channelCount: Int
    /// Per-source-channel labels in source order, when known (e.g. ["L","R","C","LFE","Ls","Rs"]).
    public let labels: [String]?
    /// Core Audio `AudioChannelLayoutTag` name, when known (e.g. "MPEG_5_1_A", "DTS_5_1").
    public let layoutTag: String?
    /// Explicit per-song override from a sidecar file (a renderer layout id, e.g. "7_1").
    public let sidecarLayoutId: String?
    public init(channelCount: Int, labels: [String]? = nil, layoutTag: String? = nil, sidecarLayoutId: String? = nil) {
        self.channelCount = channelCount
        self.labels = labels
        self.layoutTag = layoutTag
        self.sidecarLayoutId = sidecarLayoutId
    }
}

/// The renderer chosen for a source, plus how to reorder the source channels into the
/// renderer's expected input order.
public struct ResolvedRenderer: Sendable, Equatable {
    public let layoutId: String
    public let displayName: String
    /// Which rule fired (for diagnostics).
    public let reason: String
    /// `inputPermutation[k]` = the source channel index feeding renderer input `k`.
    public let inputPermutation: [Int]
}

/// Resolves a source layout to a geometry renderer, handling channel-count collisions and
/// channel-order variants (the "two kinds of 5.1") by canonical role, not by raw count.
public enum RendererResolver {

    /// Priority: sidecar override → decoder layout tag/variant → channel role labels → channel-count default.
    public static func resolve(_ src: SourceLayout) -> ResolvedRenderer? {
        // 1) Per-song sidecar override.
        if let id = src.sidecarLayoutId,
           let r = RendererGeometry.renderer(layout: id), r.channelCount == src.channelCount {
            return resolved(r, src, reason: "sidecar override")
        }
        // 2) Decoder layout tag (carries the exact channel order / variant).
        if let tag = src.layoutTag, let entry = tagTable[tag],
           let r = RendererGeometry.renderer(layout: entry.layout), r.channelCount == entry.order.count,
           let perm = permutation(renderer: r, sourceRoles: entry.order.map(role(for:))) {
            return ResolvedRenderer(layoutId: r.layout, displayName: r.displayName,
                                    reason: "layout tag \(tag)", inputPermutation: perm)
        }
        // 3) Channel role labels — disambiguates same-count layouts (7.1 vs Auro 8.0 vs …).
        if let labels = src.labels, labels.count == src.channelCount {
            let srcRoles = labels.map(role(for:))
            for r in RendererGeometry.renderers(channelCount: src.channelCount) {
                if let perm = permutation(renderer: r, sourceRoles: srcRoles) {
                    return ResolvedRenderer(layoutId: r.layout, displayName: r.displayName,
                                            reason: "channel labels", inputPermutation: perm)
                }
            }
        }
        // 4) Channel-count default.
        if let id = countDefault[src.channelCount], let r = RendererGeometry.renderer(layout: id) {
            return ResolvedRenderer(layoutId: r.layout, displayName: r.displayName,
                                    reason: "channel-count default", inputPermutation: Array(0..<r.channelCount))
        }
        return nil
    }

    // MARK: - role matching

    /// Canonical role for a channel label, normalizing Dolby/DTS/Auro/SMPTE aliases.
    static func role(for label: String) -> String {
        switch label.uppercased() {
        case "L", "FL", "LF": return "frontLeft"
        case "R", "FR", "RF": return "frontRight"
        case "C", "FC", "CTR": return "center"
        case "LFE", "LFE1", "SW", "SUB": return "lfe"
        case "LS", "LSS", "LSD", "SL": return "sideLeft"
        case "RS", "RSS", "RSD", "SR": return "sideRight"
        case "LRS", "LSR", "LR", "LB", "RLS": return "rearLeft"
        case "RRS", "RSR", "RR", "RB": return "rearRight"
        case "LC", "FLC": return "frontLeftCenter"
        case "RC", "FRC": return "frontRightCenter"
        case "LW", "LWIDE": return "wideLeft"
        case "RW", "RWIDE": return "wideRight"
        case "LTF", "TFL": return "topFrontLeft"
        case "RTF", "TFR": return "topFrontRight"
        case "LTR", "TRL": return "topRearLeft"
        case "RTR", "TRR": return "topRearRight"
        case "LTM", "TML": return "topMiddleLeft"
        case "RTM", "TMR": return "topMiddleRight"
        case "HL": return "heightFrontLeft"
        case "HR": return "heightFrontRight"
        case "HLS": return "heightRearLeft"
        case "HRS": return "heightRearRight"
        case "T", "TS", "VOG": return "topCenter"
        case "HC": return "heightCenter"
        default: return "discrete:\(label)"
        }
    }

    /// Builds renderer-input → source-index permutation by matching canonical roles 1:1.
    /// Returns nil if the source role multiset doesn't match the renderer's.
    static func permutation(renderer r: GeneratedRenderer, sourceRoles: [String]) -> [Int]? {
        guard sourceRoles.count == r.channelCount else { return nil }
        var used = Array(repeating: false, count: sourceRoles.count)
        var perm = [Int](); perm.reserveCapacity(r.channelCount)
        for ch in r.channels {
            var found = -1
            for j in sourceRoles.indices where !used[j] && sourceRoles[j] == ch.role { found = j; break }
            if found < 0 { return nil }
            used[found] = true
            perm.append(found)
        }
        return perm
    }

    static func resolved(_ r: GeneratedRenderer, _ src: SourceLayout, reason: String) -> ResolvedRenderer {
        let perm: [Int]
        if let labels = src.labels, labels.count == r.channelCount,
           let p = permutation(renderer: r, sourceRoles: labels.map(role(for:))) {
            perm = p
        } else {
            perm = Array(0..<r.channelCount)
        }
        return ResolvedRenderer(layoutId: r.layout, displayName: r.displayName, reason: reason, inputPermutation: perm)
    }

    // MARK: - tables

    /// Default renderer per channel count (used when nothing more specific is known).
    static let countDefault: [Int: String] = [
        1: "mono_1_0", 2: "stereo_2_0", 4: "quad_4_0", 6: "5_1",
        8: "7_1", 10: "7_1_2", 11: "auro_10_1", 12: "7_1_4", 14: "9_1_4", 16: "9_1_6",
    ]

    /// Decoder layout tag → (renderer layout, source channel labels in tag order). Extensible.
    static let tagTable: [String: (layout: String, order: [String])] = [
        "MPEG_5_1_A": ("5_1", ["L", "R", "C", "LFE", "Ls", "Rs"]),
        "ITU_5_1":    ("5_1", ["L", "R", "C", "LFE", "Ls", "Rs"]),
        "MPEG_5_1_B": ("5_1", ["L", "R", "Ls", "Rs", "C", "LFE"]),
        "MPEG_5_1_C": ("5_1", ["L", "C", "R", "Ls", "Rs", "LFE"]),
        "MPEG_5_1_D": ("5_1", ["C", "L", "R", "Ls", "Rs", "LFE"]),
        "DTS_5_1":    ("5_1", ["C", "L", "R", "Ls", "Rs", "LFE"]),
        "AAC_5_1":    ("5_1", ["C", "L", "R", "Ls", "Rs", "LFE"]),
        "ITU_7_1":      ("7_1", ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs"]),
        "MPEG_7_1_C":   ("7_1", ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]),
        "Atmos_7_1_4":  ("7_1_4", ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Ltf", "Rtf", "Ltr", "Rtr"]),
    ]
}
