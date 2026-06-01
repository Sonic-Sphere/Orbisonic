import Foundation

struct RendererSourceFactsModel: Equatable, Sendable {
    let sourceText: String
    let formatText: String
    let channelText: String
    let compactStreamText: String
    let outputText: String

    static func make(
        metadata: AudioSourceMetadata?,
        fallbackSourceText: String,
        outputRoute: OutputRouteInfo,
        outputNoneText: String = "not set"
    ) -> RendererSourceFactsModel {
        guard let metadata else {
            return RendererSourceFactsModel(
                sourceText: fallbackSourceText,
                formatText: "-",
                channelText: "-",
                compactStreamText: fallbackSourceText,
                outputText: compactOutputText(for: outputRoute, noneText: outputNoneText)
            )
        }

        return RendererSourceFactsModel(
            sourceText: sourceText(for: metadata),
            formatText: formatText(for: metadata),
            channelText: channelText(for: metadata),
            compactStreamText: compactStreamText(for: metadata),
            outputText: compactOutputText(for: outputRoute, noneText: outputNoneText)
        )
    }

    static func compactStreamText(
        metadata: AudioSourceMetadata?,
        fallbackText: String = "No source loaded"
    ) -> String {
        guard let metadata else { return fallbackText }
        return compactStreamText(for: metadata)
    }

    static func compactOutputText(for route: OutputRouteInfo, noneText: String = "not set") -> String {
        guard route.isAvailable else { return noneText }
        return "\(route.deviceName) · \(route.outputChannelCount) ch"
    }

    static func rendererOutputSampleRateText(for route: OutputRouteInfo, noneText: String = "not set") -> String {
        guard route.isAvailable else { return noneText }
        return rendererSampleRateText(route.nominalSampleRate)
    }

    static func rendererContainerText(_ value: String?) -> String {
        guard let text = value?.trimmedNilIfBlank else { return "Unknown" }
        let lowercased = text.lowercased()
        if ["unknown", "audio", "local file", "probing", "-"].contains(lowercased) {
            return "Unknown"
        }
        if lowercased.contains("matroska") || lowercased == "mkv" || lowercased == "mka" {
            return "MKV"
        }
        if lowercased.contains("mpeg-4") || lowercased == "mp4" || lowercased == "m4a" || lowercased.contains("quicktime") {
            return "MP4"
        }
        if lowercased == "wave" || lowercased == "wav" {
            return "WAV"
        }
        if lowercased == "aiff" || lowercased == "aifc" {
            return "AIFF"
        }
        if lowercased == "flac" {
            return "FLAC"
        }
        return text.count <= 5 ? text.uppercased() : text
    }

    static func rendererCodecText(_ value: String?) -> String {
        guard let text = value?.trimmedNilIfBlank else { return "Unknown" }
        let lowercased = text.lowercased()
        if ["unknown", "audio", "local file", "probing", "-"].contains(lowercased) {
            return "Unknown"
        }

        let base: String
        let isLossless: Bool
        if lowercased.contains("flac") {
            base = "FLAC"
            isLossless = true
        } else if lowercased.contains("truehd") || lowercased.contains("true hd") || lowercased.contains("mlp") {
            base = "TrueHD"
            isLossless = true
        } else if lowercased.contains("alac") || lowercased.contains("apple lossless") {
            base = "ALAC"
            isLossless = true
        } else if lowercased.contains("aiff") || lowercased.contains("aifc") {
            base = "AIFF"
            isLossless = true
        } else if lowercased == "wav" || lowercased == "wave" {
            base = "WAV"
            isLossless = true
        } else if lowercased.contains("pcm") || lowercased.contains("lpcm") || lowercased.contains("float32") {
            base = "PCM"
            isLossless = true
        } else if lowercased.contains("joc") {
            base = "E-AC-3 JOC"
            isLossless = false
        } else if lowercased.contains("eac3") || lowercased.contains("e-ac-3") || lowercased.contains("digital plus") {
            base = "E-AC-3"
            isLossless = false
        } else if lowercased.contains("ac3") || lowercased.contains("ac-3") || lowercased.contains("dolby digital") {
            base = "AC-3"
            isLossless = false
        } else if lowercased == "aac" || lowercased.contains("advanced audio coding") {
            base = "AAC"
            isLossless = false
        } else {
            base = normalizedFormatText(text) ?? text
            isLossless = lowercased.contains("lossless")
        }

        guard isLossless, !base.localizedCaseInsensitiveContains("lossless") else { return base }
        return "\(base) lossless"
    }

    static func rendererChannelLayoutText(layout: String?, channels: Int?) -> String {
        compactLayoutText(layout: layout, channels: channels) ?? "Unknown"
    }

    static func rendererSampleRateText(_ sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate.isFinite, sampleRate > 0 else { return "Unknown" }
        return compactSampleRateText(sampleRate)
    }

    static func formatTrackSummary(
        isAtmos: Bool? = nil,
        format: String? = nil,
        codec: String? = nil,
        sampleRate: Double? = nil,
        layout: String? = nil,
        channels: Int? = nil
    ) -> String {
        var parts: [String] = []

        if isAtmos == true || (isAtmos == nil && containsAtmosIndicator([format, codec, layout])) {
            parts.append("Dolby Atmos")
        }

        if let formatText = preferredFormatText(format: format, codec: codec) {
            parts.append(formatText)
        }

        if let sampleRate, sampleRate > 0 {
            parts.append(compactSampleRateText(sampleRate))
        }

        if let layoutText = compactLayoutText(layout: layout, channels: channels) {
            parts.append(layoutText)
        }

        return parts.isEmpty ? "Unknown format" : parts.joined(separator: " · ")
    }

    private static func sourceText(for metadata: AudioSourceMetadata) -> String {
        if isExplicitAuro(metadata) {
            return auroSourceText(for: metadata)
        }

        if isAtmosObjectMetadataNote(metadata.formatNote) {
            return "Dolby Atmos \(bedLayoutText(count: metadata.channelCount, layoutName: metadata.layoutName))"
        }

        switch metadata.channelCount {
        case 1:
            return "Mono"
        case 2:
            return "Stereo"
        case 3:
            return "3.0"
        case 4:
            return "Quad"
        case 30:
            return "Direct 30"
        case 31:
            return "Direct 30.1"
        default:
            if let bed = standardDolbyBedText(for: metadata) {
                return "Dolby \(bed)"
            }
            return metadata.channelCount > 0 ? "\(metadata.channelCount)-channel" : "Unknown"
        }
    }

    private static func formatText(for metadata: AudioSourceMetadata) -> String {
        let codec = metadata.codecName.trimmedNilIfBlank ??
            metadata.containerName.trimmedNilIfBlank ??
            "Audio"
        guard metadata.sampleRate > 0 else { return codec }
        return "\(codec) \(metadata.sampleRateText)"
    }

    private static func compactStreamText(for metadata: AudioSourceMetadata) -> String {
        formatTrackSummary(
            isAtmos: isAtmosTrack(metadata),
            format: metadata.containerName,
            codec: metadata.codecName,
            sampleRate: metadata.sampleRate,
            layout: metadata.layoutName,
            channels: metadata.channelCount
        )
    }

    private static func channelText(for metadata: AudioSourceMetadata) -> String {
        metadata.channelCount > 0 ? "\(metadata.channelCount)" : "-"
    }

    private static func compactSampleRateText(_ sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "unknown rate" }

        let kilohertz = sampleRate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return "\(Int(kilohertz.rounded())) kHz"
        }

        return String(format: "%.1f kHz", kilohertz)
    }

    private static func compactLayoutText(for metadata: AudioSourceMetadata) -> String? {
        if isExplicitAuro(metadata) {
            return auroSourceText(for: metadata)
        }

        if isAtmosObjectMetadataNote(metadata.formatNote) {
            return bedLayoutText(count: metadata.channelCount, layoutName: metadata.layoutName)
        }

        if let bed = standardDolbyBedText(for: metadata) {
            return bed
        }

        switch metadata.channelCount {
        case 1:
            return "Mono"
        case 2:
            return "Stereo"
        case 3:
            return "3.0"
        case 4:
            return "Quad"
        case 30:
            return "Direct 30"
        case 31:
            return "Direct 30.1"
        default:
            return metadata.layoutName.trimmedNilIfBlank
        }
    }

    private static func preferredFormatText(format: String?, codec: String?) -> String? {
        for candidate in [codec, format] {
            if let text = normalizedFormatText(candidate) {
                return text
            }
        }
        return nil
    }

    private static func normalizedFormatText(_ value: String?) -> String? {
        guard var text = value?.trimmedNilIfBlank else { return nil }
        text = text.replacingOccurrences(
            of: #"(?i)\s+\d(?:\.\d){0,2}\s+bed$"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)\s+bed$"#,
            with: "",
            options: .regularExpression
        )
        let lowercased = text.lowercased()
        switch lowercased {
        case "unknown", "audio", "local file", "probing", "-":
            return nil
        case "flac":
            return "FLAC"
        case "aac":
            return "AAC"
        case "eac3", "e-ac-3", "dolby digital plus":
            return "E-AC-3"
        case "truehd", "dolby truehd":
            return "TrueHD"
        case "pcm", "lpcm", "pcm_s24le", "pcm_s16le", "float32", "coreaudio float32":
            return "PCM"
        default:
            return text
        }
    }

    private static func compactLayoutText(layout: String?, channels: Int?) -> String? {
        if let layout = normalizedLayoutText(layout) {
            return layout
        }

        guard let channels, channels > 0 else { return nil }
        switch channels {
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
        case 9:
            return "9.0"
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
            return "\(channels)ch"
        }
    }

    private static func normalizedLayoutText(_ value: String?) -> String? {
        guard let text = value?.trimmedNilIfBlank else { return nil }
        let lowercased = text.lowercased()
        if ["unknown", "audio", "-", "not set"].contains(lowercased) {
            return nil
        }

        if lowercased.contains("auro") {
            for layout in ["13.1", "12.1", "11.1", "10.1", "9.1", "8.0"] where lowercased.contains(layout) {
                return "Auro \(layout)"
            }
            return "Auro"
        }

        for layout in ["9.1.6", "9.1.4", "9.2", "9.0", "7.1.4", "7.1.2", "7.1", "6.1", "5.1.4", "5.1.2", "5.1", "5.0", "3.0"] where lowercased.contains(layout) {
            return layout
        }

        if lowercased.contains("stereo") || lowercased == "2.0" {
            return "Stereo"
        }
        if lowercased.contains("mono") || lowercased == "1.0" {
            return "Mono"
        }
        if lowercased.contains("quad") {
            return "Quad"
        }
        if lowercased.contains("direct 30.1") {
            return "Direct 30.1"
        }
        if lowercased.contains("direct 30") {
            return "Direct 30"
        }

        if text.contains(",") {
            let count = text
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .count
            return compactLayoutText(layout: nil, channels: count)
        }

        return text
    }

    private static func isExplicitAuro(_ metadata: AudioSourceMetadata) -> Bool {
        [
            metadata.layoutName,
            metadata.codecName,
            metadata.formatNote,
            metadata.channelLayoutSourceDescription
        ].contains { value in
            value?.localizedCaseInsensitiveContains("Auro") == true
        }
    }

    private static func isAtmosObjectMetadataNote(_ note: String?) -> Bool {
        guard let note = note?.trimmedNilIfBlank else { return false }
        return note.localizedCaseInsensitiveContains("Dolby Atmos metadata present") &&
            note.localizedCaseInsensitiveContains("object rendering")
    }

    private static func isAtmosTrack(_ metadata: AudioSourceMetadata) -> Bool {
        containsAtmosIndicator([
            metadata.containerName,
            metadata.codecName,
            metadata.layoutName,
            metadata.formatNote,
            metadata.channelLayoutSourceDescription
        ])
    }

    private static func containsAtmosIndicator(_ values: [String?]) -> Bool {
        let combined = values
            .compactMap { $0?.trimmedNilIfBlank }
            .joined(separator: " ")
            .lowercased()

        guard !combined.isEmpty else { return false }
        return combined.contains("dolby atmos") ||
            combined.contains("truehd atmos") ||
            combined.contains("atmos") ||
            combined.contains("e-ac-3 joc") ||
            combined.contains("eac3 joc") ||
            combined.contains("joc") ||
            combined.contains("object-based dolby") ||
            combined.contains("object based dolby") ||
            combined.contains("spatial audio metadata") ||
            combined.contains("blu-ray atmos")
    }

    private static func auroSourceText(for metadata: AudioSourceMetadata) -> String {
        let combined = [
            metadata.layoutName,
            metadata.codecName,
            metadata.formatNote,
            metadata.channelLayoutSourceDescription
        ]
        .compactMap { $0?.trimmedNilIfBlank }
        .joined(separator: " ")
        .lowercased()

        for layout in ["13.1", "12.1", "11.1", "10.1", "9.1", "8.0"] where combined.contains(layout) {
            return "Auro \(layout)"
        }

        switch metadata.channelCount {
        case 8:
            return "Auro 8.0"
        case 10:
            return "Auro 9.1"
        case 11:
            return "Auro 10.1"
        case 12:
            return "Auro 11.1"
        case 13:
            return "Auro 12.1"
        case 14:
            return "Auro 13.1"
        default:
            return "Auro"
        }
    }

    private static func standardDolbyBedText(for metadata: AudioSourceMetadata) -> String? {
        let lowercasedLayout = metadata.layoutName.lowercased()
        for layout in ["9.1.6", "9.1.4", "9.2", "9.0", "7.1.4", "7.1.2", "7.1", "6.1", "5.1", "5.0"] where lowercasedLayout.contains(layout) {
            return layout
        }

        switch metadata.channelCount {
        case 5:
            return "5.0"
        case 6:
            return "5.1"
        case 7:
            return "6.1"
        case 8:
            return "7.1"
        case 9:
            return "9.0"
        case 10:
            return "7.1.2"
        case 11:
            return "9.2"
        case 12:
            return "7.1.4"
        case 14:
            return "9.1.4"
        case 16:
            return "9.1.6"
        default:
            return nil
        }
    }

    private static func bedLayoutText(count: Int, layoutName: String) -> String {
        let lowercased = layoutName.lowercased()
        for layout in ["9.1.6", "7.1.4", "7.1.2", "7.1", "5.1.4", "5.1.2", "5.1"] where lowercased.contains(layout) {
            return layout
        }

        switch count {
        case 6:
            return "5.1"
        case 8:
            return "7.1"
        case 12:
            return "7.1.4"
        case 16:
            return "9.1.6"
        default:
            return layoutName
        }
    }
}
