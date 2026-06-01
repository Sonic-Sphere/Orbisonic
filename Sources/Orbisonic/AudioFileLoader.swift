import Accelerate
import AVFoundation
import CoreAudio
import CoreAudioTypes

struct LoadedAudioFile: @unchecked Sendable {
    let url: URL
    let monoFormat: AVAudioFormat
    let monitorFormat: AVAudioFormat
    let sampleRate: Double
    let frameCount: AVAudioFramePosition
    let layout: SurroundLayout
    let metadata: AudioSourceMetadata
    let monoBuffers: [AVAudioPCMBuffer]
    let monitorBuffer: AVAudioPCMBuffer

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    var preparedPCMByteCount: Int {
        PreparedPCMPolicy.estimatedDecodedPCMBytes(
            frameCount: frameCount,
            channelCount: monoBuffers.count
        ) ?? 0
    }

    // Rebind the identity URL without touching decoded audio. Used after an
    // offline managed transcode so the displayed/highlighted file stays the
    // user's original path even though the decoded copy came from a cache CAF.
    func withURL(_ newURL: URL) -> LoadedAudioFile {
        LoadedAudioFile(
            url: newURL,
            monoFormat: monoFormat,
            monitorFormat: monitorFormat,
            sampleRate: sampleRate,
            frameCount: frameCount,
            layout: layout,
            metadata: metadata,
            monoBuffers: monoBuffers,
            monitorBuffer: monitorBuffer
        )
    }
}

enum PreparedPCMPolicy {
    static let bytesPerSample = MemoryLayout<Float>.size
    static let maxFullPreparedPCMBytes = 128 * 1_024 * 1_024
    static let maxAdjacentFullPreloadPCMBytes = 0
    static let maxPreparedCacheEntries = 2
    static let maxPreparedCacheBytes = maxFullPreparedPCMBytes

    /// Fraction of installed physical RAM a single full-prepare load may occupy.
    static let fullPreparePhysicalMemoryFraction = 0.5
    /// Floor so normal files are never refused on small or odd memory readings.
    static let minFullPreparedPCMBytes = 512 * 1_024 * 1_024
    /// Used when the memory reading is unavailable (total == 0).
    static let unknownMemoryFullPreparedPCMBytes = 2 * 1_024 * 1_024 * 1_024

    /// Dynamic full-prepare cap derived from installed RAM. Computed once when
    /// the loader is constructed; installed physical memory does not change at runtime.
    static func defaultMaxFullPreparedPCMBytes(
        provider: SystemMemoryProviding = HostSystemMemoryProvider()
    ) -> Int {
        let total = provider.snapshot().totalBytes
        guard total > 0 else { return unknownMemoryFullPreparedPCMBytes }
        return max(Int(Double(total) * fullPreparePhysicalMemoryFraction), minFullPreparedPCMBytes)
    }

    /// Returns true only when there is a concrete estimate that exceeds the cap.
    /// Unknown estimates (nil) return false so unknown-size files keep their
    /// existing behavior rather than being refused outright.
    static func exceedsFullPrepareBudget(
        estimatedDecodedBytes: Int?,
        maxBytes: Int = Self.maxFullPreparedPCMBytes
    ) -> Bool {
        guard let estimatedDecodedBytes else { return false }
        return estimatedDecodedBytes > maxBytes
    }

    static func estimatedDecodedPCMBytes(
        durationSeconds: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        bytesPerSample: Int = Self.bytesPerSample
    ) -> Int? {
        guard durationSeconds.isFinite,
              sampleRate.isFinite,
              durationSeconds >= 0,
              sampleRate > 0,
              channelCount > 0,
              bytesPerSample > 0
        else { return nil }

        let estimate = durationSeconds * sampleRate * Double(channelCount) * Double(bytesPerSample)
        guard estimate.isFinite,
              estimate >= 0,
              estimate <= Double(Int.max)
        else { return nil }

        return Int(estimate.rounded(.up))
    }

    static func estimatedDecodedPCMBytes(
        frameCount: AVAudioFramePosition,
        channelCount: Int,
        bytesPerSample: Int = Self.bytesPerSample
    ) -> Int? {
        guard frameCount >= 0,
              channelCount > 0,
              bytesPerSample > 0
        else { return nil }

        let estimate = Double(frameCount) * Double(channelCount) * Double(bytesPerSample)
        guard estimate.isFinite,
              estimate <= Double(Int.max)
        else { return nil }

        return Int(estimate.rounded(.up))
    }

    static func formatMiB(_ bytes: Int) -> String {
        String(format: "%.2f MiB", Double(bytes) / 1_048_576.0)
    }
}

enum AudioFileLoaderError: LocalizedError {
    case fileMissing(String)
    case unsupportedAudioFile(String, String)
    case unsupportedChannelCount(UInt32, maxSupported: Int)
    case fileTooLarge
    case fileTooLargeToPrepare(estimatedBytes: Int?, maxBytes: Int)
    case sourceBufferAllocationFailed
    case layoutCreationFailed(UInt32)
    case surroundFormatCreationFailed(Double, UInt32)
    case convertedBufferAllocationFailed
    case monitorBufferAllocationFailed
    case monoFormatCreationFailed(Double)
    case monoBufferAllocationFailed
    case converterCreationFailed
    case formatConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let fileName):
            "That local file is no longer available: \(fileName). Rescan local music to remove stale entries."
        case .unsupportedAudioFile(let fileName, let message):
            "Could not open \(fileName). The audio container or codec may not be supported by this build. \(message)"
        case .unsupportedChannelCount(let count, let maxSupported):
            count == 0
                ? "Expected at least 1 channel, but got 0."
                : "Orbisonic supports up to \(maxSupported) source channels in this build. This file has \(count) channels."
        case .fileTooLarge:
            "This build reads the file into memory and the file is too large for that path."
        case .fileTooLargeToPrepare(let estimatedBytes, let maxBytes):
            "This track needs about \(estimatedBytes.map { PreparedPCMPolicy.formatMiB($0) } ?? "an unknown amount") of memory to load, which exceeds this device's \(PreparedPCMPolicy.formatMiB(maxBytes)) limit. Large-file streaming isn't enabled in this build."
        case .sourceBufferAllocationFailed:
            "Unable to allocate the source audio buffer."
        case .layoutCreationFailed(let channelCount):
            "Unable to create an internal layout for \(channelCount) channels."
        case .surroundFormatCreationFailed(let sampleRate, let channels):
            "Unable to create an internal \(channels)-channel float format at \(sampleRate) Hz."
        case .convertedBufferAllocationFailed:
            "Unable to allocate the converted audio buffer."
        case .monitorBufferAllocationFailed:
            "Unable to allocate the reference stereo monitor buffer."
        case .monoFormatCreationFailed(let sampleRate):
            "Unable to create an internal mono float format at \(sampleRate) Hz."
        case .monoBufferAllocationFailed:
            "Unable to allocate a mono playback buffer."
        case .converterCreationFailed:
            "Unable to create the audio format converter."
        case .formatConversionFailed(let message):
            "Audio conversion failed: \(message)"
        }
    }
}

final class AudioFileLoader {
    private let maxFullPreparedPCMBytes: Int

    init(maxFullPreparedPCMBytes: Int = PreparedPCMPolicy.defaultMaxFullPreparedPCMBytes()) {
        self.maxFullPreparedPCMBytes = maxFullPreparedPCMBytes
    }

    func load(
        url: URL,
        forceFFmpegFLACFallback: Bool = false,
        selectedAudioStreamOrdinal: Int? = nil,
        debugTiming: DebugTimingContext? = nil
    ) throws -> LoadedAudioFile {
        let timing = debugTiming ?? DebugTimingLog.makeCommand(prefix: "audio-load")
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        var decodeSucceeded = false
        var finalSampleRate: Double?
        var finalChannelCount: UInt32?
        var finalDuration: TimeInterval?
        var finalPreparedBufferBytes: Int?
        var decodeCanceled = false

        func checkCancellation(_ phase: String, fileURL: URL? = nil) throws {
            if Task.isCancelled {
                decodeCanceled = true
                timing.log(
                    "decode canceled",
                    fileURL: fileURL ?? url,
                    extra: ["phase=\"\(phase)\""]
                )
            }
            try Task.checkCancellation()
        }

        timing.log(
            "decode start",
            fileURL: url,
            extra: [
                "fileSizeBytes=\(Self.fileSizeBytes(url) ?? -1)",
                "scope=\"loader\""
            ]
        )
        defer {
            let result = decodeSucceeded ? "success" : (decodeCanceled ? "canceled" : "failed")
            var fields = [
                "totalDecodeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000.0))",
                "result=\"\(result)\"",
                "scope=\"loader\""
            ]
            if let finalSampleRate {
                fields.append("sampleRate=\(String(format: "%.1f", finalSampleRate))")
            }
            if let finalChannelCount {
                fields.append("channelCount=\(finalChannelCount)")
            }
            if let finalDuration {
                fields.append("durationSeconds=\(String(format: "%.3f", finalDuration))")
            }
            if let finalPreparedBufferBytes {
                fields.append("preparedBufferBytes=\(finalPreparedBufferBytes)")
                fields.append("preparedBufferMiB=\(String(format: "%.2f", Double(finalPreparedBufferBytes) / 1_048_576.0))")
            }
            timing.log("decode finish", fileURL: url, extra: fields)
        }

        try checkCancellation("before file existence check")
        AppLogger.shared.info(category: "loader", "Opening file: \(url.path)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioFileLoaderError.fileMissing(url.lastPathComponent)
        }
        try checkCancellation("after file existence check")

        var readURL = url
        var temporaryDecodedURL: URL?
        var matroskaStreamInfo: MatroskaAudioStreamInfo?
        var codecNameOverride: String?
        try checkCancellation("before metadata tag read")
        var tags = AudioMetadataBuilder.tags(for: url)
        try checkCancellation("after metadata tag read")

        if let ordinal = selectedAudioStreamOrdinal, ordinal > 0 {
            // Multi-stream presentation selector picked a non-default audio stream.
            // Decode that specific stream to CAF via ffmpeg (0:a:<ordinal>); the
            // default/first stream keeps the fork's existing decode path untouched.
            try checkCancellation("before multi-stream ffmpeg decode")
            let containerDecodeStart = DispatchTime.now().uptimeNanoseconds
            timing.log(
                "container decode start",
                fileURL: url,
                extra: ["decoder=\"ffmpeg\"", "audioStreamOrdinal=\(ordinal)"]
            )
            let decodedURL = try FFmpegAudioDecoder().decodeToCAF(
                url: url,
                sourceDescription: "audio stream \(ordinal)",
                audioStreamOrdinal: ordinal
            )
            try checkCancellation("after multi-stream ffmpeg decode")
            timing.log(
                "container decode end",
                fileURL: url,
                extra: [
                    "decoder=\"ffmpeg\"",
                    "audioStreamOrdinal=\(ordinal)",
                    "containerDecodeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - containerDecodeStart) / 1_000_000.0))"
                ]
            )
            readURL = decodedURL
            temporaryDecodedURL = decodedURL
            AppLogger.shared.notice(
                category: "loader",
                "Decoded selected audio stream ordinal=\(ordinal) for file=\(url.lastPathComponent)"
            )
        } else if MatroskaFLACSupport.isMatroska(url) {
            try checkCancellation("before Matroska probe")
            let containerDecodeStart = DispatchTime.now().uptimeNanoseconds
            timing.log("container decode start", fileURL: url, extra: ["container=\"Matroska\""])
            let streamInfo = try MatroskaAudioProbe().probe(url: url)
            try checkCancellation("after Matroska probe")
            try checkCancellation("before Matroska demux")
            let decodedURL = try MatroskaFLACDemuxer().demuxToCAF(url: url, streamInfo: streamInfo)
            try checkCancellation("after Matroska demux")
            timing.log(
                "container decode end",
                fileURL: url,
                extra: [
                    "container=\"Matroska\"",
                    "containerDecodeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - containerDecodeStart) / 1_000_000.0))"
                ]
            )
            readURL = decodedURL
            temporaryDecodedURL = decodedURL
            matroskaStreamInfo = streamInfo
            tags = streamInfo.tags
            AppLogger.shared.info(
                category: "loader",
                "Decoded Matroska FLAC stream index=\(streamInfo.streamIndex) channels=\(streamInfo.channelCount) " +
                    "sampleRate=\(streamInfo.sampleRate) bitDepth=\(streamInfo.bitDepth)"
            )
        } else if StandaloneFLACSupport.isFLAC(url), forceFFmpegFLACFallback {
            try checkCancellation("before forced FLAC ffmpeg decode")
            let containerDecodeStart = DispatchTime.now().uptimeNanoseconds
            timing.log("container decode start", fileURL: url, extra: ["container=\"FLAC\"", "decoder=\"ffmpeg\""])
            let decodedURL = try FFmpegAudioDecoder().decodeToCAF(url: url, sourceDescription: "FLAC")
            try checkCancellation("after forced FLAC ffmpeg decode")
            timing.log(
                "container decode end",
                fileURL: url,
                extra: [
                    "container=\"FLAC\"",
                    "decoder=\"ffmpeg\"",
                    "containerDecodeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - containerDecodeStart) / 1_000_000.0))"
                ]
            )
            readURL = decodedURL
            temporaryDecodedURL = decodedURL
            codecNameOverride = "FLAC"
            AppLogger.shared.notice(category: "loader", "Forced FLAC ffmpeg fallback for file=\(url.lastPathComponent)")
        }

        defer {
            if let temporaryDecodedURL {
                try? FileManager.default.removeItem(at: temporaryDecodedURL)
            }
        }

        var file: AVAudioFile
        let openStart = DispatchTime.now().uptimeNanoseconds
        try checkCancellation("before open audio file", fileURL: readURL)
        timing.log("open audio file start", fileURL: readURL)
        do {
            file = try AVAudioFile(forReading: readURL)
            try checkCancellation("after open audio file", fileURL: readURL)
            timing.log(
                "open audio file end",
                fileURL: readURL,
                extra: ["openMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - openStart) / 1_000_000.0))"]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard StandaloneFLACSupport.isFLAC(url), temporaryDecodedURL == nil else {
                throw AudioFileLoaderError.unsupportedAudioFile(url.lastPathComponent, error.localizedDescription)
            }
            timing.log(
                "open audio file end",
                fileURL: readURL,
                extra: [
                    "openMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - openStart) / 1_000_000.0))",
                    "error=\"\(error.localizedDescription)\""
                ]
            )
            let fallbackDecodeStart = DispatchTime.now().uptimeNanoseconds
            try checkCancellation("before fallback FLAC ffmpeg decode", fileURL: url)
            timing.log("container decode start", fileURL: url, extra: ["container=\"FLAC\"", "decoder=\"ffmpeg\"", "reason=\"native open failed\""])
            let decodedURL = try FFmpegAudioDecoder().decodeToCAF(url: url, sourceDescription: "FLAC")
            try checkCancellation("after fallback FLAC ffmpeg decode", fileURL: url)
            timing.log(
                "container decode end",
                fileURL: url,
                extra: [
                    "container=\"FLAC\"",
                    "decoder=\"ffmpeg\"",
                    "containerDecodeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - fallbackDecodeStart) / 1_000_000.0))"
                ]
            )
            readURL = decodedURL
            temporaryDecodedURL = decodedURL
            codecNameOverride = "FLAC"
            AppLogger.shared.notice(
                category: "loader",
                "Native FLAC open failed; decoded with ffmpeg file=\(url.lastPathComponent) error=\(error.localizedDescription)"
            )
            let fallbackOpenStart = DispatchTime.now().uptimeNanoseconds
            try checkCancellation("before fallback open audio file", fileURL: readURL)
            timing.log("open audio file start", fileURL: readURL, extra: ["decoder=\"ffmpeg\""])
            file = try AVAudioFile(forReading: readURL)
            try checkCancellation("after fallback open audio file", fileURL: readURL)
            timing.log(
                "open audio file end",
                fileURL: readURL,
                extra: [
                    "decoder=\"ffmpeg\"",
                    "openMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - fallbackOpenStart) / 1_000_000.0))"
                ]
            )
        }
        let inputFormat = file.processingFormat
        let channelCount = inputFormat.channelCount
        let estimatedDuration = inputFormat.sampleRate > 0 ? Double(file.length) / inputFormat.sampleRate : 0
        let estimatedPreparedBytes = PreparedPCMPolicy.estimatedDecodedPCMBytes(
            durationSeconds: estimatedDuration,
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(channelCount)
        )
        let estimatedPreparedBytesText = estimatedPreparedBytes.map(String.init) ?? "unknown"
        let maxFullPreparedBytes = maxFullPreparedPCMBytes
        let fullPrepareWithinBudget = estimatedPreparedBytes.map { $0 <= maxFullPreparedBytes } ?? false
        let fullPrepareReason = fullPrepareWithinBudget
            ? "within selected-track full prepare budget"
            : "streaming required but fallback full prepare used for selected track"
        timing.log(
            "full prepare budget check",
            fileURL: url,
            extra: [
                "estimatedDecodedBytes=\(estimatedPreparedBytesText)",
                "maxFullPreparedPCMBytes=\(maxFullPreparedBytes)",
                "allowed=\(fullPrepareWithinBudget)",
                "reason=\"\(fullPrepareReason)\""
            ]
        )
        if PreparedPCMPolicy.exceedsFullPrepareBudget(
            estimatedDecodedBytes: estimatedPreparedBytes,
            maxBytes: maxFullPreparedBytes
        ) {
            AppLogger.shared.error(
                category: "loader",
                "Refusing oversized full prepare file=\(url.lastPathComponent) estimatedBytes=\(estimatedPreparedBytesText) maxBytes=\(maxFullPreparedBytes) reason=\"\(fullPrepareReason)\""
            )
            throw AudioFileLoaderError.fileTooLargeToPrepare(
                estimatedBytes: estimatedPreparedBytes,
                maxBytes: maxFullPreparedBytes
            )
        } else if !fullPrepareWithinBudget {
            AppLogger.shared.notice(
                category: "loader",
                "Full prepared PCM estimate exceeds preferred budget file=\(url.lastPathComponent) estimatedBytes=\(estimatedPreparedBytesText) maxBytes=\(maxFullPreparedBytes) reason=\"\(fullPrepareReason)\""
            )
        }

        guard OrbisonicAudioLimits.supportsSourceChannelCount(Int(channelCount)) else {
            throw AudioFileLoaderError.unsupportedChannelCount(
                channelCount,
                maxSupported: OrbisonicAudioLimits.maxSourceChannelCount
            )
        }

        guard file.length <= AVAudioFramePosition(UInt32.max) else {
            throw AudioFileLoaderError.fileTooLarge
        }

        let layoutDescriptor = SurroundLayoutDetector.descriptor(for: inputFormat)
        let detectedLayout = layoutDescriptor.layout
        let inputLayout = try buildChannelLayout(for: inputFormat, fallback: detectedLayout)
        for warning in layoutDescriptor.warningDescriptions {
            AppLogger.shared.notice(category: "loader", "Channel layout warning file=\(url.lastPathComponent) warning=\"\(warning)\"")
        }

        AppLogger.shared.info(
            category: "loader",
            "Detected source format codec=\(AudioMetadataBuilder.build(for: file, layout: detectedLayout, duration: 0, sourceURL: url, containerName: matroskaStreamInfo == nil ? nil : "Matroska", codecName: matroskaStreamInfo?.codecName ?? codecNameOverride, bitDepth: matroskaStreamInfo?.bitDepth, tags: tags).codecName) " +
                "sampleRate=\(inputFormat.sampleRate) channelCount=\(channelCount) layout=\(detectedLayout.name) channels=\(detectedLayout.channelSummary)"
        )

        let frameCapacity = AVAudioFrameCount(file.length)
        let sourceAllocationStart = DispatchTime.now().uptimeNanoseconds
        try checkCancellation("before source buffer allocation", fileURL: readURL)
        timing.log("buffer allocation start", fileURL: readURL, extra: ["buffer=\"source\"", "frameCapacity=\(frameCapacity)"])
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
            throw AudioFileLoaderError.sourceBufferAllocationFailed
        }
        try checkCancellation("after source buffer allocation", fileURL: readURL)
        timing.log(
            "buffer allocation end",
            fileURL: readURL,
            extra: [
                "buffer=\"source\"",
                "allocationMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - sourceAllocationStart) / 1_000_000.0))"
            ]
        )
        let fullReadStart = DispatchTime.now().uptimeNanoseconds
        try checkCancellation("before blocking full read", fileURL: readURL)
        timing.log(
            "full read start",
            fileURL: readURL,
            extra: [
                "frames=\(file.length)",
                "reason=\"blocking AVAudioFile full read remains streaming migration target\""
            ]
        )
        try file.read(into: sourceBuffer)
        try checkCancellation("after blocking full read", fileURL: readURL)
        timing.log(
            "full read end",
            fileURL: readURL,
            extra: [
                "frames=\(sourceBuffer.frameLength)",
                "readMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - fullReadStart) / 1_000_000.0))"
            ]
        )

        let surroundFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            interleaved: false,
            channelLayout: inputLayout
        )

        guard surroundFormat.channelCount == channelCount else {
            throw AudioFileLoaderError.surroundFormatCreationFailed(inputFormat.sampleRate, channelCount)
        }

        let conversionAllocationStart = DispatchTime.now().uptimeNanoseconds
        try checkCancellation("before conversion buffer allocation", fileURL: readURL)
        timing.log("buffer allocation start", fileURL: readURL, extra: ["buffer=\"converted\"", "frameCapacity=\(sourceBuffer.frameLength)"])
        guard let surroundBuffer = AVAudioPCMBuffer(pcmFormat: surroundFormat, frameCapacity: sourceBuffer.frameLength) else {
            throw AudioFileLoaderError.convertedBufferAllocationFailed
        }
        try checkCancellation("after conversion buffer allocation", fileURL: readURL)
        timing.log(
            "buffer allocation end",
            fileURL: readURL,
            extra: [
                "buffer=\"converted\"",
                "allocationMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - conversionAllocationStart) / 1_000_000.0))"
            ]
        )

        guard let converter = AVAudioConverter(from: inputFormat, to: surroundFormat) else {
            throw AudioFileLoaderError.converterCreationFailed
        }

        var suppliedInput = false
        var conversionError: NSError?

        let conversionStart = DispatchTime.now().uptimeNanoseconds
        try checkCancellation("before format conversion", fileURL: readURL)
        timing.log("format conversion start", fileURL: readURL)
        let status = converter.convert(to: surroundBuffer, error: &conversionError) { _, outStatus in
            if Task.isCancelled {
                outStatus.pointee = .noDataNow
                return nil
            }

            if suppliedInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            suppliedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        try checkCancellation("after format conversion", fileURL: readURL)

        if status == .error || conversionError != nil {
            throw AudioFileLoaderError.formatConversionFailed(conversionError?.localizedDescription ?? "unknown converter error")
        }
        timing.log(
            "format conversion end",
            fileURL: readURL,
            extra: ["conversionMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - conversionStart) / 1_000_000.0))"]
        )

        surroundBuffer.frameLength = sourceBuffer.frameLength

        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: surroundFormat.sampleRate,
            channels: 1
        ) else {
            throw AudioFileLoaderError.monoFormatCreationFailed(surroundFormat.sampleRate)
        }

        guard let channelData = surroundBuffer.floatChannelData else {
            throw AudioFileLoaderError.formatConversionFailed("missing float channel data")
        }

        let splitStart = DispatchTime.now().uptimeNanoseconds
        try checkCancellation("before channel split", fileURL: readURL)
        timing.log("channel split start", fileURL: readURL, extra: ["channels=\(channelCount)", "frames=\(surroundBuffer.frameLength)"])
        let splitChunkFrames = 65_536
        let monoBuffers = try (0..<Int(channelCount)).map { channelIndex in
            try checkCancellation("before channel split allocation \(channelIndex)", fileURL: readURL)
            guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: surroundBuffer.frameLength) else {
                throw AudioFileLoaderError.monoBufferAllocationFailed
            }
            try checkCancellation("after channel split allocation \(channelIndex)", fileURL: readURL)

            monoBuffer.frameLength = surroundBuffer.frameLength
            let source = channelData[channelIndex]
            guard let monoChannelData = monoBuffer.floatChannelData else {
                throw AudioFileLoaderError.formatConversionFailed("missing mono float channel data")
            }
            let destination = monoChannelData[0]
            let totalFrames = Int(surroundBuffer.frameLength)
            var offset = 0
            while offset < totalFrames {
                try checkCancellation("channel split copy \(channelIndex)", fileURL: readURL)
                let frameCount = min(splitChunkFrames, totalFrames - offset)
                destination
                    .advanced(by: offset)
                    .update(from: source.advanced(by: offset), count: frameCount)
                offset += frameCount
            }
            return monoBuffer
        }
        try checkCancellation("after channel split", fileURL: readURL)
        timing.log(
            "channel split end",
            fileURL: readURL,
            extra: [
                "channels=\(channelCount)",
                "frames=\(surroundBuffer.frameLength)",
                "splitMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - splitStart) / 1_000_000.0))"
            ]
        )

        guard let monitorFormat = AVAudioFormat(
            standardFormatWithSampleRate: surroundFormat.sampleRate,
            channels: 2
        ) else {
            throw AudioFileLoaderError.monitorBufferAllocationFailed
        }
        guard let monitorBuffer = AVAudioPCMBuffer(
            pcmFormat: monitorFormat,
            frameCapacity: surroundBuffer.frameLength
        ) else {
            throw AudioFileLoaderError.monitorBufferAllocationFailed
        }

        let monitorRenderStart = DispatchTime.now().uptimeNanoseconds
        try checkCancellation("before reference monitor render", fileURL: readURL)
        timing.log("reference monitor render start", fileURL: readURL, extra: ["channels=\(channelCount)", "frames=\(surroundBuffer.frameLength)"])
        try Self.renderReferenceMonitorBuffer(
            inputBuffers: monoBuffers,
            layout: detectedLayout,
            outputBuffer: monitorBuffer
        )
        try checkCancellation("after reference monitor render", fileURL: readURL)
        timing.log(
            "reference monitor render end",
            fileURL: readURL,
            extra: [
                "frames=\(monitorBuffer.frameLength)",
                "renderMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - monitorRenderStart) / 1_000_000.0))"
            ]
        )

        let duration = Double(surroundBuffer.frameLength) / surroundFormat.sampleRate
        let metadata = AudioMetadataBuilder.build(
            for: file,
            layout: detectedLayout,
            duration: duration,
            layoutDescriptor: layoutDescriptor,
            sourceURL: url,
            containerName: matroskaStreamInfo == nil ? nil : "Matroska",
            codecName: matroskaStreamInfo?.codecName ?? codecNameOverride,
            bitDepth: matroskaStreamInfo?.bitDepth,
            tags: tags
        )

        try checkCancellation("before prepared audio result", fileURL: url)
        AppLogger.shared.notice(
            category: "loader",
            "Prepared playback buffers file=\(metadata.fileName) layout=\(metadata.layoutName) codec=\(metadata.codecName) " +
                "channels=\(metadata.channelCount) sampleRate=\(metadata.sampleRateText) bitDepth=\(metadata.bitDepthText) duration=\(metadata.durationText)"
        )

        finalSampleRate = surroundFormat.sampleRate
        finalChannelCount = channelCount
        finalDuration = duration
        finalPreparedBufferBytes = PreparedPCMPolicy.estimatedDecodedPCMBytes(
            frameCount: AVAudioFramePosition(surroundBuffer.frameLength),
            channelCount: Int(channelCount)
        )
        decodeSucceeded = true

        return LoadedAudioFile(
            url: url,
            monoFormat: monoFormat,
            monitorFormat: monitorFormat,
            sampleRate: surroundFormat.sampleRate,
            frameCount: AVAudioFramePosition(surroundBuffer.frameLength),
            layout: detectedLayout,
            metadata: metadata,
            monoBuffers: monoBuffers,
            monitorBuffer: monitorBuffer
        )
    }

    private static func renderReferenceMonitorBuffer(
        inputBuffers: [AVAudioPCMBuffer],
        layout: SurroundLayout,
        outputBuffer: AVAudioPCMBuffer
    ) throws {
        let downmixer = NormalMonitorStereoDownmixer(layout: layout)
        guard inputBuffers.count == downmixer.matrix.sourceChannelCount else {
            throw NormalMonitorStereoDownmixerError.inputChannelCountMismatch(
                expected: downmixer.matrix.sourceChannelCount,
                actual: inputBuffers.count
            )
        }
        guard Int(outputBuffer.format.channelCount) == downmixer.matrix.outputChannelCount else {
            throw NormalMonitorStereoDownmixerError.outputChannelCountMismatch(
                expected: downmixer.matrix.outputChannelCount,
                actual: Int(outputBuffer.format.channelCount)
            )
        }

        let frameCount = Int(inputBuffers.first?.frameLength ?? 0)
        guard Int(outputBuffer.frameCapacity) >= frameCount else {
            throw AudioFileLoaderError.monitorBufferAllocationFailed
        }
        for (index, inputBuffer) in inputBuffers.enumerated() where Int(inputBuffer.frameLength) != frameCount {
            throw NormalMonitorStereoDownmixerError.inputFrameCountMismatch(
                channelIndex: index,
                expected: frameCount,
                actual: Int(inputBuffer.frameLength)
            )
        }
        guard let outputChannels = outputBuffer.floatChannelData else {
            throw AudioFileLoaderError.formatConversionFailed("missing monitor output float channel data")
        }

        outputBuffer.frameLength = AVAudioFrameCount(frameCount)
        for channelIndex in 0..<downmixer.matrix.outputChannelCount {
            outputChannels[channelIndex].initialize(repeating: 0, count: frameCount)
        }
        guard frameCount > 0 else { return }

        for coefficient in downmixer.matrix.coefficients {
            guard let inputChannels = inputBuffers[coefficient.inputIndex].floatChannelData else {
                throw AudioFileLoaderError.formatConversionFailed("missing monitor input float channel data")
            }

            let input = inputChannels[0]
            let left = outputChannels[0]
            let right = outputChannels[1]
            let frames = vDSP_Length(frameCount)
            // vDSP_vsma: dst = input * gain + dst (in place). Skip zero-gain sides
            // (adding input * 0 contributes exactly 0 to the running sum).
            if coefficient.left != 0 {
                var gain = coefficient.left
                vDSP_vsma(input, 1, &gain, left, 1, left, 1, frames)
            }
            if coefficient.right != 0 {
                var gain = coefficient.right
                vDSP_vsma(input, 1, &gain, right, 1, right, 1, frames)
            }
        }
    }

    private static func fileSizeBytes(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.intValue
    }

    private func buildChannelLayout(for inputFormat: AVAudioFormat, fallback: SurroundLayout) throws -> AVAudioChannelLayout {
        if let channelLayout = inputFormat.channelLayout,
           Self.channelDescriptionCount(in: channelLayout, fallbackCount: Int(inputFormat.channelCount)) == Int(inputFormat.channelCount) {
            return channelLayout
        }

        let managedLayout = ManagedAudioChannelLayout(
            channelDescriptions: fallback.channels.map { channel in
                var description = AudioChannelDescription()
                description.mChannelLabel = audioChannelLabel(for: channel.role)
                description.mChannelFlags = AudioChannelFlags(rawValue: 0)
                description.mCoordinates = (0, 0, 0)
                return description
            }
        )

        let channelLayout = managedLayout.withUnsafePointer { pointer in
            AVAudioChannelLayout(layout: pointer)
        }

        return channelLayout
    }

    private static func channelDescriptionCount(in channelLayout: AVAudioChannelLayout, fallbackCount: Int) -> Int {
        let descriptions = AudioChannelLayout.UnsafePointer(channelLayout.layout)
        return descriptions.count == 0 ? fallbackCount : descriptions.count
    }

    private func audioChannelLabel(for role: SurroundChannelRole) -> AudioChannelLabel {
        switch role {
        case .frontLeft:
            AudioChannelLabel(kAudioChannelLabel_Left)
        case .frontRight:
            AudioChannelLabel(kAudioChannelLabel_Right)
        case .center:
            AudioChannelLabel(kAudioChannelLabel_Center)
        case .lfe:
            AudioChannelLabel(kAudioChannelLabel_LFEScreen)
        case .lfe2:
            AudioChannelLabel(kAudioChannelLabel_LFE2)
        case .sideLeft:
            AudioChannelLabel(kAudioChannelLabel_LeftSideSurround)
        case .sideRight:
            AudioChannelLabel(kAudioChannelLabel_RightSideSurround)
        case .rearLeft:
            AudioChannelLabel(kAudioChannelLabel_LeftBackSurround)
        case .rearRight:
            AudioChannelLabel(kAudioChannelLabel_RightBackSurround)
        case .rearCenter:
            AudioChannelLabel(kAudioChannelLabel_CenterSurround)
        case .wideLeft:
            AudioChannelLabel(kAudioChannelLabel_LeftWide)
        case .wideRight:
            AudioChannelLabel(kAudioChannelLabel_RightWide)
        case .frontLeftCenter:
            AudioChannelLabel(kAudioChannelLabel_LeftCenter)
        case .frontRightCenter:
            AudioChannelLabel(kAudioChannelLabel_RightCenter)
        case .topFrontLeft:
            AudioChannelLabel(kAudioChannelLabel_LeftTopFront)
        case .topFrontCenter:
            AudioChannelLabel(kAudioChannelLabel_CenterTopFront)
        case .topFrontRight:
            AudioChannelLabel(kAudioChannelLabel_RightTopFront)
        case .topMiddleLeft:
            AudioChannelLabel(kAudioChannelLabel_LeftTopMiddle)
        case .topMiddleCenter:
            AudioChannelLabel(kAudioChannelLabel_CenterTopMiddle)
        case .topMiddleRight:
            AudioChannelLabel(kAudioChannelLabel_RightTopMiddle)
        case .topRearLeft:
            AudioChannelLabel(kAudioChannelLabel_LeftTopRear)
        case .topRearCenter:
            AudioChannelLabel(kAudioChannelLabel_CenterTopRear)
        case .topRearRight:
            AudioChannelLabel(kAudioChannelLabel_RightTopRear)
        case .discrete(let index):
            AudioChannelLabel(kAudioChannelLabel_Discrete_0 + UInt32(index))
        }
    }
}
