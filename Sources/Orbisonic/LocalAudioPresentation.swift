import Foundation

// Ported from Orbisonic Realtime (renderer I/O tab + multi-stream selector).
// Adapted for Sonic-Sphere/Orbisonic: layout naming is derived from channel
// count rather than the Realtime FFmpeg-channel-layout role mapper, so this
// file does not depend on (or override) the fork's ChannelRoleLayoutDescriptor
// channel-identity logic. The multi-stream selector remains fully functional;
// only the per-stream layout *label* is count-derived (e.g. "7.1").

enum LocalAudioCodecClass: String, Sendable {
    case lossless
    case lossy
    case unknown

    var displayText: String {
        switch self {
        case .lossless:
            "lossless"
        case .lossy:
            "lossy"
        case .unknown:
            "unknown"
        }
    }
}

struct LocalAudioPresentation: Identifiable, Equatable, Sendable {
    static let defaultRendererTargetSampleRate: Double = 48_000

    let streamIndex: Int
    let audioStreamOrdinal: Int
    let displayTitle: String
    let rawCodecName: String
    let codecName: String
    let profile: String?
    let codecClass: LocalAudioCodecClass
    let channelCount: Int
    let channelLayout: String?
    let sampleRate: Double?
    let bitDepth: UInt32
    let duration: TimeInterval?
    let isDefaultStream: Bool
    let hasDolbyAtmos: Bool
    let hasExplicitAuroMetadata: Bool
    let hasHeightChannels: Bool
    let isEligibleForRenderer: Bool
    let channelLayoutConfidence: ChannelLayoutConfidence
    let preferenceReason: String

    var id: Int { streamIndex }

    var isLossless: Bool {
        codecClass == .lossless
    }

    var layoutText: String {
        Self.layoutText(channelLayout: channelLayout, channelCount: channelCount)
    }

    var preferenceSummaryText: String {
        let rateText = sampleRate.map(Self.sampleRateText) ?? "unknown rate"
        return "\(codecName) \(layoutText), \(rateText) \(codecClass.displayText)"
    }

    var menuTitle: String {
        "Stream \(audioStreamOrdinal + 1) · \(codecName) \(layoutText) · \(sampleRate.map(Self.sampleRateText) ?? "unknown rate") · \(codecClass.displayText)"
    }

    func withPreferenceReason(_ reason: String) -> LocalAudioPresentation {
        LocalAudioPresentation(
            streamIndex: streamIndex,
            audioStreamOrdinal: audioStreamOrdinal,
            displayTitle: displayTitle,
            rawCodecName: rawCodecName,
            codecName: codecName,
            profile: profile,
            codecClass: codecClass,
            channelCount: channelCount,
            channelLayout: channelLayout,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            duration: duration,
            isDefaultStream: isDefaultStream,
            hasDolbyAtmos: hasDolbyAtmos,
            hasExplicitAuroMetadata: hasExplicitAuroMetadata,
            hasHeightChannels: hasHeightChannels,
            isEligibleForRenderer: isEligibleForRenderer,
            channelLayoutConfidence: channelLayoutConfidence,
            preferenceReason: reason
        )
    }

    static func resolvedTargetSampleRate(_ sampleRate: Double?) -> Double {
        guard let sampleRate,
              sampleRate.isFinite,
              sampleRate > 0
        else {
            return defaultRendererTargetSampleRate
        }
        return sampleRate
    }

    static func preferredPresentation(
        from presentations: [LocalAudioPresentation],
        targetSampleRate: Double?
    ) -> LocalAudioPresentation? {
        rankedEligiblePresentations(
            presentations,
            targetSampleRate: targetSampleRate
        ).first
    }

    static func selectedPresentation(
        from presentations: [LocalAudioPresentation],
        selectedStreamIndex: Int?,
        targetSampleRate: Double?
    ) -> LocalAudioPresentation? {
        let eligible = presentations.filter(\.isEligibleForRenderer)
        if let selectedStreamIndex,
           let selected = eligible.first(where: { $0.streamIndex == selectedStreamIndex }) {
            return selected
        }
        return preferredPresentation(from: presentations, targetSampleRate: targetSampleRate)
    }

    static func rankedEligiblePresentations(
        _ presentations: [LocalAudioPresentation],
        targetSampleRate: Double?
    ) -> [LocalAudioPresentation] {
        let target = resolvedTargetSampleRate(targetSampleRate)
        return presentations
            .filter(\.isEligibleForRenderer)
            .sorted { lhs, rhs in
                if lhs.channelCount != rhs.channelCount {
                    return lhs.channelCount > rhs.channelCount
                }
                if lhs.isLossless != rhs.isLossless {
                    return lhs.isLossless && !rhs.isLossless
                }
                let lhsTargetMatch = matchesRendererTarget(lhs, targetSampleRate: target)
                let rhsTargetMatch = matchesRendererTarget(rhs, targetSampleRate: target)
                if lhsTargetMatch != rhsTargetMatch {
                    return lhsTargetMatch
                }
                if lhs.channelLayoutConfidence != rhs.channelLayoutConfidence {
                    return lhs.channelLayoutConfidence > rhs.channelLayoutConfidence
                }
                if lhs.isDefaultStream != rhs.isDefaultStream {
                    return lhs.isDefaultStream && !rhs.isDefaultStream
                }
                return lhs.streamIndex < rhs.streamIndex
            }
    }

    static func preferredReason(
        for preferred: LocalAudioPresentation,
        among presentations: [LocalAudioPresentation],
        targetSampleRate: Double?
    ) -> String {
        let ranked = rankedEligiblePresentations(presentations, targetSampleRate: targetSampleRate)
        guard let runnerUp = ranked.first(where: { $0.streamIndex != preferred.streamIndex }) else {
            return "Preferred: \(preferred.preferenceSummaryText)."
        }

        let target = resolvedTargetSampleRate(targetSampleRate)
        let reason: String
        if preferred.channelCount > runnerUp.channelCount {
            reason = "it has more renderable channels"
        } else if preferred.isLossless, !runnerUp.isLossless {
            reason = "it is lossless at the same channel count"
        } else if matchesRendererTarget(preferred, targetSampleRate: target),
                  !matchesRendererTarget(runnerUp, targetSampleRate: target) {
            reason = "it avoids renderer/Dante resampling"
        } else if preferred.channelLayoutConfidence > runnerUp.channelLayoutConfidence {
            reason = "it has higher channel-layout confidence"
        } else if preferred.isDefaultStream, !runnerUp.isDefaultStream {
            reason = "it is the container default stream"
        } else {
            reason = "it is the lowest-index matching stream"
        }

        return "Preferred: \(preferred.preferenceSummaryText); chosen over \(runnerUp.codecName) because \(reason)."
    }

    static func codecDisplayName(
        rawCodecName: String?,
        profile: String?,
        title: String?,
        hasAuro: Bool,
        hasAtmos: Bool
    ) -> String {
        let raw = rawCodecName?.trimmedNilIfBlank?.lowercased() ?? ""
        let profileText = profile?.trimmedNilIfBlank?.lowercased() ?? ""
        let titleText = title?.trimmedNilIfBlank?.lowercased() ?? ""
        let combined = [raw, profileText, titleText].joined(separator: " ")

        if raw == "flac" {
            return hasAuro ? "Auro-3D FLAC" : "FLAC"
        }
        if raw.hasPrefix("pcm_") || raw == "pcm" || raw == "lpcm" {
            return hasAuro ? "Auro-3D PCM" : "PCM"
        }
        if raw == "truehd" || raw == "mlp" || combined.contains("truehd") || combined.contains("true hd") {
            return hasAtmos ? "TrueHD Atmos" : "TrueHD"
        }
        if raw == "eac3" {
            return hasAtmos || combined.contains("joc") ? "E-AC-3 JOC" : "E-AC-3"
        }
        if raw == "ac3" {
            return "AC-3"
        }
        if raw == "aac" {
            return "AAC"
        }
        if raw == "alac" {
            return "ALAC"
        }
        if raw == "dts" {
            return profileText.contains("ma") || combined.contains("dts-hd ma") ? "DTS-HD MA" : "DTS"
        }
        if raw == "opus" {
            return "Opus"
        }
        if raw == "vorbis" {
            return "Vorbis"
        }
        return raw.isEmpty ? "Unknown" : raw.uppercased()
    }

    static func codecClass(rawCodecName: String?, profile: String?) -> LocalAudioCodecClass {
        let raw = rawCodecName?.trimmedNilIfBlank?.lowercased() ?? ""
        let profile = profile?.trimmedNilIfBlank?.lowercased() ?? ""

        if raw == "flac" ||
            raw == "alac" ||
            raw == "truehd" ||
            raw == "mlp" ||
            raw.hasPrefix("pcm_") ||
            raw == "pcm" ||
            raw == "lpcm" ||
            (raw == "dts" && (profile.contains("ma") || profile.contains("hd ma"))) {
            return .lossless
        }

        if ["eac3", "ac3", "aac", "mp3", "opus", "vorbis", "dts"].contains(raw) {
            return .lossy
        }

        return raw.isEmpty ? .unknown : .lossy
    }

    static func codecIsSupportedByFFmpegDecode(_ rawCodecName: String?) -> Bool {
        let raw = rawCodecName?.trimmedNilIfBlank?.lowercased() ?? ""
        guard !raw.isEmpty else { return false }
        if raw.hasPrefix("pcm_") { return true }
        return [
            "flac",
            "alac",
            "truehd",
            "mlp",
            "eac3",
            "ac3",
            "aac",
            "mp3",
            "opus",
            "vorbis",
            "dts"
        ].contains(raw)
    }

    static func hasAtmosIndicator(in values: [String?]) -> Bool {
        let combined = values
            .compactMap { $0?.trimmedNilIfBlank }
            .joined(separator: " ")
            .lowercased()
        guard !combined.isEmpty else { return false }
        return combined.contains("atmos") ||
            combined.contains("joc") ||
            combined.contains("object-based dolby") ||
            combined.contains("object based dolby")
    }

    static func hasHeightChannels(channelLayout: String?, channelCount: Int, hasAuro: Bool, hasAtmos: Bool) -> Bool {
        let lowercased = channelLayout?.lowercased() ?? ""
        if lowercased.contains("top") || lowercased.contains("height") || lowercased.contains("wide") {
            return true
        }
        if hasAuro, channelCount > 8 {
            return true
        }
        if hasAtmos, channelCount > 8 {
            return true
        }
        for marker in ["7.1.2", "7.1.4", "9.1.4", "9.1.6", "5.1.2", "5.1.4"] where lowercased.contains(marker) {
            return true
        }
        return false
    }

    static func layoutConfidence(channelLayout: String?, channelCount: Int, hasAuro: Bool) -> ChannelLayoutConfidence {
        if hasAuro {
            return .low
        }
        return channelCount <= 2 ? .high : .low
    }

    static func sampleRateText(_ sampleRate: Double) -> String {
        let kilohertz = sampleRate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return "\(Int(kilohertz.rounded())) kHz"
        }
        return String(format: "%.1f kHz", kilohertz)
    }

    private static func matchesRendererTarget(
        _ presentation: LocalAudioPresentation,
        targetSampleRate: Double
    ) -> Bool {
        guard let sampleRate = presentation.sampleRate,
              sampleRate.isFinite,
              sampleRate > 0
        else { return false }
        return abs(sampleRate - targetSampleRate) < 0.5
    }

    static func layoutText(channelLayout: String?, channelCount: Int) -> String {
        if let descriptor = channelLayout?.trimmedNilIfBlank, !isOpaqueLayoutToken(descriptor) {
            return descriptor
        }

        switch channelCount {
        case 1:
            return "Mono"
        case 2:
            return "Stereo"
        case 3:
            return "3.0"
        case 4:
            return "Quad"
        case 5:
            return "5.0"
        case 6:
            return "5.1"
        case 7:
            return "6.1"
        case 8:
            return "7.1"
        case 10:
            return "7.1.2"
        case 12:
            return "7.1.4"
        case 14:
            return "9.1.4"
        case 16:
            return "9.1.6"
        case 30:
            return "Direct 30"
        case 31:
            return "Direct 30.1"
        default:
            return channelCount > 0 ? "\(channelCount)ch" : "Unknown"
        }
    }

    private static func isOpaqueLayoutToken(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.hasPrefix("0x") { return true }
        if lowered == "unknown" || lowered == "none" { return true }
        // Reject bare numeric channel masks; keep human-readable names like "5.1(side)".
        return value.allSatisfy { $0.isNumber }
    }
}
