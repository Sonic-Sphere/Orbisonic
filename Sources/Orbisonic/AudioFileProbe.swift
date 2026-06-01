import AVFoundation
import CoreAudioTypes
import Foundation

struct AudioAssetDescriptor: Sendable {
    let url: URL
    let durationFrames: AVAudioFramePosition?
    let durationSeconds: Double?
    let sourceSampleRate: Double
    let channelCount: Int
    let estimatedDecodedBytes: Int64?
    let codecDescription: String?
    let channelLayout: SurroundLayout
    let containerDescription: String?
    // Multi-stream presentation support (ported from Orbisonic Realtime).
    let selectedPresentation: LocalAudioPresentation?
    let preferredPresentation: LocalAudioPresentation?
    let availablePresentations: [LocalAudioPresentation]
    let preferredPresentationReason: String?

    init(
        url: URL,
        durationFrames: AVAudioFramePosition?,
        durationSeconds: Double?,
        sourceSampleRate: Double,
        channelCount: Int,
        estimatedDecodedBytes: Int64?,
        codecDescription: String?,
        channelLayout: SurroundLayout,
        containerDescription: String?,
        selectedPresentation: LocalAudioPresentation? = nil,
        preferredPresentation: LocalAudioPresentation? = nil,
        availablePresentations: [LocalAudioPresentation] = [],
        preferredPresentationReason: String? = nil
    ) {
        self.url = url
        self.durationFrames = durationFrames
        self.durationSeconds = durationSeconds
        self.sourceSampleRate = sourceSampleRate
        self.channelCount = channelCount
        self.estimatedDecodedBytes = estimatedDecodedBytes
        self.codecDescription = codecDescription
        self.channelLayout = channelLayout
        self.containerDescription = containerDescription
        self.selectedPresentation = selectedPresentation
        self.preferredPresentation = preferredPresentation
        self.availablePresentations = availablePresentations
        self.preferredPresentationReason = preferredPresentationReason
    }

    var logFields: [String] {
        [
            "durationFrames=\(durationFrames.map(String.init) ?? "unknown")",
            "durationSeconds=\(durationSeconds.map { String(format: "%.3f", $0) } ?? "unknown")",
            "sampleRate=\(String(format: "%.1f", sourceSampleRate))",
            "channelCount=\(channelCount)",
            "layout=\"\(channelLayout.name)\"",
            "estimatedDecodedBytes=\(estimatedDecodedBytes.map(String.init) ?? "unknown")",
            "codec=\"\(codecDescription ?? "unknown")\"",
            "container=\"\(containerDescription ?? "unknown")\"",
            "selectedStream=\(selectedPresentation.map { String($0.streamIndex) } ?? "none")",
            "availableStreams=\(availablePresentations.count)"
        ]
    }

    var eligiblePresentations: [LocalAudioPresentation] {
        availablePresentations.filter(\.isEligibleForRenderer)
    }

    var hasMultipleEligibleAudioPresentations: Bool {
        eligiblePresentations.count > 1
    }

    /// Returns a copy with the multi-stream presentations attached and the primary
    /// single-stream facts (sample rate, channels, codec, layout) derived from the
    /// selected presentation, so the renderer/UI reflect the chosen audio stream.
    func attachingPresentations(
        available: [LocalAudioPresentation],
        selected: LocalAudioPresentation?,
        preferred: LocalAudioPresentation?,
        reason: String?
    ) -> AudioAssetDescriptor {
        let resolvedSampleRate = selected?.sampleRate ?? sourceSampleRate
        let resolvedChannelCount = selected?.channelCount ?? channelCount
        return AudioAssetDescriptor(
            url: url,
            durationFrames: durationFrames,
            durationSeconds: selected?.duration ?? durationSeconds,
            sourceSampleRate: resolvedSampleRate > 0 ? resolvedSampleRate : sourceSampleRate,
            channelCount: resolvedChannelCount > 0 ? resolvedChannelCount : channelCount,
            estimatedDecodedBytes: estimatedDecodedBytes,
            codecDescription: selected?.codecName ?? codecDescription,
            channelLayout: selected.map { SurroundLayoutDetector.fallbackLayout(for: $0.channelCount) } ?? channelLayout,
            containerDescription: containerDescription,
            selectedPresentation: selected,
            preferredPresentation: preferred,
            availablePresentations: available,
            preferredPresentationReason: reason
        )
    }
}

enum AudioFileProbeError: LocalizedError, Equatable {
    case fileMissing(String)
    case missingFFProbe(String)
    case unsupportedAudioFile(String, String)
    case invalidFFProbeOutput(String)
    case noAudioStream(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let name):
            "Could not find \(name)."
        case .missingFFProbe(let name):
            "Could not cheaply inspect \(name) because ffprobe is unavailable."
        case .unsupportedAudioFile(let name, let message):
            "Could not inspect \(name): \(message)"
        case .invalidFFProbeOutput(let message):
            "Could not parse audio probe output: \(message)"
        case .noAudioStream(let name):
            "\(name) does not contain an audio stream."
        }
    }
}

struct AudioFileProbe {
    func probe(url: URL, selectedStreamIndex: Int? = nil) async throws -> AudioAssetDescriptor {
        try await probe(url: url, debugTiming: nil, selectedStreamIndex: selectedStreamIndex)
    }

    func probe(
        url: URL,
        debugTiming: DebugTimingContext?,
        priority: TaskPriority = .utility,
        selectedStreamIndex: Int? = nil
    ) async throws -> AudioAssetDescriptor {
        let timing = debugTiming ?? DebugTimingLog.makeCommand(prefix: "audio-probe")
        let start = DispatchTime.now().uptimeNanoseconds
        timing.log("descriptor probe scheduled", fileURL: url)

        let probeTask = Task.detached(priority: priority) {
            try Self.probeSynchronously(url: url, debugTiming: timing, selectedStreamIndex: selectedStreamIndex)
        }
        let descriptor = try await withTaskCancellationHandler {
            try await probeTask.value
        } onCancel: {
            probeTask.cancel()
        }

        var fields = descriptor.logFields
        fields.append("probeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0))")
        timing.log("descriptor probe finished", fileURL: url, extra: fields)
        return descriptor
    }

    static func probeSynchronously(
        url: URL,
        debugTiming: DebugTimingContext? = nil,
        selectedStreamIndex: Int? = nil
    ) throws -> AudioAssetDescriptor {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioFileProbeError.fileMissing(url.lastPathComponent)
        }

        let base: AudioAssetDescriptor
        if MatroskaFLACSupport.isMatroska(url) {
            base = try probeMatroska(url: url, debugTiming: debugTiming)
        } else {
            do {
                base = try probeAVAudioFile(url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                base = try probeWithFFProbe(url: url, originalError: error)
            }
        }

        // Multi-stream presentation enumeration. Only containers that can carry
        // multiple audio streams pay for the extra ffprobe pass; single-stream
        // formats (FLAC/WAV/MP3/AIFF) return the base descriptor unchanged.
        guard containerMayHaveMultipleAudioStreams(url) else { return base }
        try Task.checkCancellation()
        let presentations = enumeratePresentations(url: url)
        guard presentations.count > 1 else { return base }

        let target = base.sourceSampleRate > 0 ? base.sourceSampleRate : nil
        let preferred = LocalAudioPresentation.preferredPresentation(
            from: presentations,
            targetSampleRate: target
        )
        let selected = LocalAudioPresentation.selectedPresentation(
            from: presentations,
            selectedStreamIndex: selectedStreamIndex,
            targetSampleRate: target
        ) ?? preferred
        let reason = preferred.map {
            LocalAudioPresentation.preferredReason(for: $0, among: presentations, targetSampleRate: target)
        }
        return base.attachingPresentations(
            available: presentations,
            selected: selected,
            preferred: preferred,
            reason: reason
        )
    }

    private static func containerMayHaveMultipleAudioStreams(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return [
            "mkv", "mka", "mp4", "m4a", "m4v", "mov",
            "ts", "m2ts", "mts", "webm", "avi", "vob"
        ].contains(ext)
    }

    /// Enumerates every audio stream via ffprobe and builds a renderable
    /// `LocalAudioPresentation` for each. Best-effort: returns `[]` when ffprobe
    /// is unavailable or the file cannot be parsed.
    static func enumeratePresentations(url: URL) -> [LocalAudioPresentation] {
        guard let ffprobeURL = FFmpegToolLocator.ffprobeURL() else { return [] }
        guard
            let result = try? MatroskaAudioProbe.runProcess(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-print_format", "json",
                    "-show_format",
                    "-show_streams",
                    "-select_streams", "a",
                    url.path
                ]
            ),
            result.terminationStatus == 0,
            let output = try? JSONDecoder().decode(AudioProbeFFProbeOutput.self, from: result.outputData)
        else { return [] }

        let audioStreams = output.streams.filter { $0.codecType == "audio" }
        guard audioStreams.count > 1 else { return [] }

        let formatTagValues = output.format?.tags?.values.map(Optional.some) ?? []
        return audioStreams.enumerated().map { ordinal, stream in
            let rawCodec = stream.codecName
            let channelCount = stream.channels ?? 0
            let sampleRate = Double(stream.sampleRate ?? "")
            let title = stream.title
            let hasAtmos = LocalAudioPresentation.hasAtmosIndicator(
                in: [rawCodec, stream.profile, stream.channelLayout, title] + formatTagValues
            )
            let hasAuro = [title, stream.channelLayout, stream.profile]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains("auro") }
            let codecName = LocalAudioPresentation.codecDisplayName(
                rawCodecName: rawCodec,
                profile: stream.profile,
                title: title,
                hasAuro: hasAuro,
                hasAtmos: hasAtmos
            )
            let isEligible = LocalAudioPresentation.codecIsSupportedByFFmpegDecode(rawCodec) && channelCount > 0
            return LocalAudioPresentation(
                streamIndex: stream.index ?? ordinal,
                audioStreamOrdinal: ordinal,
                displayTitle: title ?? "Stream \(ordinal + 1)",
                rawCodecName: rawCodec ?? "",
                codecName: codecName,
                profile: stream.profile,
                codecClass: LocalAudioPresentation.codecClass(rawCodecName: rawCodec, profile: stream.profile),
                channelCount: channelCount,
                channelLayout: stream.channelLayout,
                sampleRate: sampleRate,
                bitDepth: stream.resolvedBitDepth,
                duration: stream.durationValue,
                isDefaultStream: (stream.disposition?.default ?? 0) == 1,
                hasDolbyAtmos: hasAtmos,
                hasExplicitAuroMetadata: hasAuro,
                hasHeightChannels: LocalAudioPresentation.hasHeightChannels(
                    channelLayout: stream.channelLayout,
                    channelCount: channelCount,
                    hasAuro: hasAuro,
                    hasAtmos: hasAtmos
                ),
                isEligibleForRenderer: isEligible,
                channelLayoutConfidence: LocalAudioPresentation.layoutConfidence(
                    channelLayout: stream.channelLayout,
                    channelCount: channelCount,
                    hasAuro: hasAuro
                ),
                preferenceReason: ""
            )
        }
    }

    private static func probeMatroska(url: URL, debugTiming: DebugTimingContext?) throws -> AudioAssetDescriptor {
        try Task.checkCancellation()
        debugTiming?.log("descriptor container probe start", fileURL: url, extra: ["container=\"Matroska\""])
        let streamInfo = try MatroskaAudioProbe().probe(url: url)
        try Task.checkCancellation()
        debugTiming?.log("descriptor container probe end", fileURL: url, extra: ["container=\"Matroska\""])

        let layout = SurroundLayoutDetector.fallbackLayout(for: streamInfo.channelCount)
        let durationFrames = durationFrames(durationSeconds: streamInfo.duration, sampleRate: streamInfo.sampleRate)
        return AudioAssetDescriptor(
            url: url,
            durationFrames: durationFrames,
            durationSeconds: positiveDuration(streamInfo.duration),
            sourceSampleRate: streamInfo.sampleRate,
            channelCount: streamInfo.channelCount,
            estimatedDecodedBytes: estimatedDecodedBytes(durationFrames: durationFrames, durationSeconds: streamInfo.duration, sampleRate: streamInfo.sampleRate, channelCount: streamInfo.channelCount),
            codecDescription: streamInfo.codecName,
            channelLayout: layout,
            containerDescription: "Matroska"
        )
    }

    private static func probeAVAudioFile(url: URL) throws -> AudioAssetDescriptor {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        try Task.checkCancellation()

        let processingFormat = file.processingFormat
        let sampleRate = processingFormat.sampleRate > 0 ? processingFormat.sampleRate : file.fileFormat.sampleRate
        let channelCount = Int(processingFormat.channelCount)
        let durationFrames = file.length >= 0 ? file.length : nil
        let durationSeconds = durationFrames.flatMap { frames in
            sampleRate > 0 ? Double(frames) / sampleRate : nil
        }
        let layout = SurroundLayoutDetector.detect(for: processingFormat)

        return AudioAssetDescriptor(
            url: url,
            durationFrames: durationFrames,
            durationSeconds: durationSeconds,
            sourceSampleRate: sampleRate,
            channelCount: channelCount,
            estimatedDecodedBytes: estimatedDecodedBytes(durationFrames: durationFrames, durationSeconds: durationSeconds, sampleRate: sampleRate, channelCount: channelCount),
            codecDescription: codecDescription(for: file.fileFormat.streamDescription.pointee.mFormatID),
            channelLayout: layout,
            containerDescription: url.pathExtension.trimmedNilIfBlank?.uppercased()
        )
    }

    private static func probeWithFFProbe(url: URL, originalError: Error) throws -> AudioAssetDescriptor {
        try Task.checkCancellation()
        guard let ffprobeURL = FFmpegToolLocator.ffprobeURL() else {
            throw AudioFileProbeError.unsupportedAudioFile(url.lastPathComponent, originalError.localizedDescription)
        }

        let result = try MatroskaAudioProbe.runProcess(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_streams",
                "-show_format",
                "-select_streams", "a:0",
                url.path
            ]
        )
        try Task.checkCancellation()

        guard result.terminationStatus == 0 else {
            throw AudioFileProbeError.unsupportedAudioFile(
                url.lastPathComponent,
                result.errorText.trimmedNilIfBlank ?? "ffprobe exited \(result.terminationStatus)"
            )
        }

        do {
            let output = try JSONDecoder().decode(AudioProbeFFProbeOutput.self, from: result.outputData)
            guard let stream = output.streams.first(where: { $0.codecType == "audio" }) else {
                throw AudioFileProbeError.noAudioStream(url.lastPathComponent)
            }

            let sampleRate = Double(stream.sampleRate ?? "") ?? 0
            let channelCount = stream.channels ?? 0
            let durationSeconds = stream.durationValue ?? output.format?.durationValue
            let frames = durationSeconds.flatMap { durationFrames(durationSeconds: $0, sampleRate: sampleRate) }
            let layout = SurroundLayoutDetector.fallbackLayout(for: channelCount)

            return AudioAssetDescriptor(
                url: url,
                durationFrames: frames,
                durationSeconds: durationSeconds.flatMap(positiveDuration),
                sourceSampleRate: sampleRate,
                channelCount: channelCount,
                estimatedDecodedBytes: estimatedDecodedBytes(durationFrames: frames, durationSeconds: durationSeconds, sampleRate: sampleRate, channelCount: channelCount),
                codecDescription: codecDescription(forFFProbeCodec: stream.codecName),
                channelLayout: layout,
                containerDescription: url.pathExtension.trimmedNilIfBlank?.uppercased()
            )
        } catch let error as AudioFileProbeError {
            throw error
        } catch {
            throw AudioFileProbeError.invalidFFProbeOutput(error.localizedDescription)
        }
    }

    private static func estimatedDecodedBytes(
        durationFrames: AVAudioFramePosition?,
        durationSeconds: Double?,
        sampleRate: Double,
        channelCount: Int
    ) -> Int64? {
        if let durationFrames,
           let estimate = PreparedPCMPolicy.estimatedDecodedPCMBytes(
            frameCount: durationFrames,
            channelCount: channelCount
           ) {
            return Int64(estimate)
        }

        guard let durationSeconds,
              let estimate = PreparedPCMPolicy.estimatedDecodedPCMBytes(
                durationSeconds: durationSeconds,
                sampleRate: sampleRate,
                channelCount: channelCount
              )
        else { return nil }

        return Int64(estimate)
    }

    private static func durationFrames(durationSeconds: Double, sampleRate: Double) -> AVAudioFramePosition? {
        guard let durationSeconds = positiveDuration(durationSeconds),
              sampleRate.isFinite,
              sampleRate > 0
        else { return nil }

        let frames = durationSeconds * sampleRate
        guard frames.isFinite,
              frames >= 0,
              frames <= Double(AVAudioFramePosition.max)
        else { return nil }

        return AVAudioFramePosition(frames.rounded(.toNearestOrAwayFromZero))
    }

    private static func positiveDuration(_ value: Double) -> Double? {
        guard value.isFinite,
              value > 0
        else { return nil }
        return value
    }

    private static func codecDescription(for formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatLinearPCM:
            "PCM"
        case kAudioFormatAppleLossless:
            "Apple Lossless"
        case kAudioFormatFLAC:
            "FLAC"
        case kAudioFormatMPEG4AAC:
            "AAC"
        case kAudioFormatMPEGLayer3:
            "MP3"
        case kAudioFormatAC3:
            "AC-3"
        case kAudioFormatEnhancedAC3:
            "E-AC-3"
        default:
            fourCCString(from: formatID)
        }
    }

    private static func codecDescription(forFFProbeCodec codecName: String?) -> String? {
        guard let codec = codecName?.trimmedNilIfBlank else { return nil }
        let lower = codec.lowercased()
        if lower == "flac" { return "FLAC" }
        if lower.hasPrefix("pcm_") { return "PCM" }
        if lower == "aac" { return "AAC" }
        if lower == "mp3" { return "MP3" }
        if lower == "ac3" { return "AC-3" }
        if lower == "eac3" { return "E-AC-3" }
        return codec.uppercased()
    }

    private static func fourCCString(from formatID: AudioFormatID) -> String {
        let value = CFSwapInt32HostToBig(formatID)
        let scalar0 = UnicodeScalar((value >> 24) & 0xFF)
        let scalar1 = UnicodeScalar((value >> 16) & 0xFF)
        let scalar2 = UnicodeScalar((value >> 8) & 0xFF)
        let scalar3 = UnicodeScalar(value & 0xFF)

        let characters = [scalar0, scalar1, scalar2, scalar3].compactMap { $0 }.map(Character.init)
        let text = String(characters)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Format \(formatID)" : trimmed
    }
}

private struct AudioProbeFFProbeOutput: Decodable {
    let streams: [AudioProbeFFProbeStream]
    let format: AudioProbeFFProbeFormat?
}

private struct AudioProbeFFProbeStream: Decodable {
    let index: Int?
    let codecType: String?
    let codecName: String?
    let profile: String?
    let sampleRate: String?
    let channels: Int?
    let channelLayout: String?
    let bitsPerRawSample: String?
    let bitsPerSample: Int?
    let duration: String?
    let disposition: Disposition?
    let tags: [String: String]?

    struct Disposition: Decodable {
        let `default`: Int?
    }

    var durationValue: TimeInterval? {
        duration.flatMap(TimeInterval.init)
    }

    var title: String? {
        guard let tags else { return nil }
        return tags["title"] ?? tags["TITLE"] ?? tags["Title"]
    }

    var resolvedBitDepth: UInt32 {
        if let bitsPerRawSample, let value = UInt32(bitsPerRawSample), value > 0 {
            return value
        }
        if let bitsPerSample, bitsPerSample > 0 {
            return UInt32(bitsPerSample)
        }
        return 0
    }

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case profile
        case sampleRate = "sample_rate"
        case channels
        case channelLayout = "channel_layout"
        case bitsPerRawSample = "bits_per_raw_sample"
        case bitsPerSample = "bits_per_sample"
        case duration
        case disposition
        case tags
    }
}

private struct AudioProbeFFProbeFormat: Decodable {
    let duration: String?
    let tags: [String: String]?

    var durationValue: TimeInterval? {
        duration.flatMap(TimeInterval.init)
    }
}
