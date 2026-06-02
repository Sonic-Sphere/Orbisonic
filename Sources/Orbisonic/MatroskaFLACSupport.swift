import Foundation

enum MatroskaFLACSupport {
    static func isMatroska(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mkv", "mka":
            true
        default:
            false
        }
    }
}

enum StandaloneFLACSupport {
    static func isFLAC(_ url: URL) -> Bool {
        url.pathExtension.localizedCaseInsensitiveCompare("flac") == .orderedSame
    }
}

enum FFmpegToolLocator {
    static func ffmpegURL() -> URL? {
        executableURL(toolName: "ffmpeg", environmentKey: "ORBISONIC_FFMPEG_PATH")
    }

    static func ffprobeURL() -> URL? {
        executableURL(toolName: "ffprobe", environmentKey: "ORBISONIC_FFPROBE_PATH")
    }

    private static func executableURL(toolName: String, environmentKey: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[environmentKey]?.trimmedNilIfBlank {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let bundledToolURL = OrbisonicResourceLocator.executableURL(
            named: toolName,
            preferredSubdirectory: "Tools"
        ) {
            return bundledToolURL
        }

        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return nil
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(toolName) }

        let developmentCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin").appendingPathComponent(toolName),
            URL(fileURLWithPath: "/usr/local/bin").appendingPathComponent(toolName),
            URL(fileURLWithPath: "/usr/bin").appendingPathComponent(toolName)
        ] + pathCandidates

        for candidate in developmentCandidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        return nil
    }
}

enum FFmpegAudioDecoderError: LocalizedError, Equatable {
    case missingFFmpeg(String)
    case processFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingFFmpeg(let description):
            "\(description) playback requires ffmpeg. Bundle ffmpeg in Orbisonic.app/Contents/Resources/Tools or set ORBISONIC_FFMPEG_PATH for development."
        case .processFailed(let description, let message):
            "Unable to decode \(description) audio: \(message)"
        }
    }
}

struct FFmpegAudioDecoder {
    func decodeToCAF(url: URL, sourceDescription: String, audioStreamOrdinal: Int = 0) throws -> URL {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL() else {
            throw FFmpegAudioDecoderError.missingFFmpeg(sourceDescription)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Orbisonic-Decoded-Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("caf")

        // audioStreamOrdinal selects which audio stream to decode (0:a:N). Used by
        // the multi-stream presentation selector to decode a non-default stream.
        let result = try MatroskaAudioProbe.runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-v", "error",
                "-y",
                "-i", url.path,
                "-map", "0:a:\(max(0, audioStreamOrdinal))",
                "-vn",
                "-c:a", "pcm_f32le",
                "-f", "caf",
                outputURL.path
            ]
        )

        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw FFmpegAudioDecoderError.processFailed(
                sourceDescription,
                result.errorText.trimmedNilIfBlank ?? "ffmpeg exited \(result.terminationStatus)"
            )
        }

        return outputURL
    }
}

struct MatroskaAudioStreamInfo: Equatable, Sendable {
    let streamIndex: Int
    let codecName: String
    let streamTitle: String?
    let sampleRate: Double
    let channelCount: Int
    let bitDepth: UInt32
    let duration: TimeInterval
    let tags: AudioSourceTags
}

enum MatroskaAudioProbeError: LocalizedError, Equatable {
    case missingFFProbe
    case processFailed(String)
    case invalidOutput(String)
    case noAudioStream
    case unsupportedAudioCodec(String)

    var errorDescription: String? {
        switch self {
        case .missingFFProbe:
            "MKV/MKA playback requires ffprobe. Bundle ffprobe in Orbisonic.app/Contents/Resources/Tools or set ORBISONIC_FFPROBE_PATH for development."
        case .processFailed(let message):
            "Unable to inspect MKV/MKA audio: \(message)"
        case .invalidOutput(let message):
            "Unable to parse MKV/MKA audio metadata: \(message)"
        case .noAudioStream:
            "This Matroska file does not contain an audio stream."
        case .unsupportedAudioCodec(let codec):
            "Orbisonic supports MKV/MKA audio streams that are FLAC, PCM, or Dolby/DTS surround. This file reports \(codec.isEmpty ? "no supported audio codec" : codec)."
        }
    }
}

struct MatroskaAudioProbe {
    func probe(url: URL) throws -> MatroskaAudioStreamInfo {
        guard let ffprobeURL = FFmpegToolLocator.ffprobeURL() else {
            throw MatroskaAudioProbeError.missingFFProbe
        }

        let result = try Self.runProcess(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_streams",
                "-show_format",
                url.path
            ]
        )

        guard result.terminationStatus == 0 else {
            throw MatroskaAudioProbeError.processFailed(result.errorText.trimmedNilIfBlank ?? "ffprobe exited \(result.terminationStatus)")
        }

        return try Self.parse(ffprobeData: result.outputData, sourceURL: url)
    }

    static func parse(ffprobeData data: Data, sourceURL: URL) throws -> MatroskaAudioStreamInfo {
        do {
            let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
            let audioStreams = output.streams.filter { $0.codecType == "audio" }
            guard !audioStreams.isEmpty else {
                throw MatroskaAudioProbeError.noAudioStream
            }

            let supportedStreams = audioStreams.filter(\.isSupportedOrbisonicAudio)
            guard let stream = preferredStream(from: supportedStreams) else {
                let codecSummary = audioStreams
                    .map { $0.codecName ?? "unknown" }
                    .joined(separator: ", ")
                throw MatroskaAudioProbeError.unsupportedAudioCodec(codecSummary)
            }

            let formatTags = output.format?.tags ?? [:]
            let streamTags = stream.tags ?? [:]
            let streamTitle = Self.tagValue("title", in: streamTags)

            return MatroskaAudioStreamInfo(
                streamIndex: stream.index,
                codecName: Self.displayCodecName(for: stream),
                streamTitle: streamTitle,
                sampleRate: Double(stream.sampleRate ?? "") ?? 0,
                channelCount: stream.channels ?? 0,
                bitDepth: stream.bitDepth,
                duration: stream.durationValue ?? output.format?.durationValue ?? 0,
                tags: Self.tags(formatTags: formatTags, streamTags: streamTags)
            )
        } catch let error as MatroskaAudioProbeError {
            throw error
        } catch {
            throw MatroskaAudioProbeError.invalidOutput(error.localizedDescription)
        }
    }

    private static func preferredStream(from streams: [FFProbeStream]) -> FFProbeStream? {
        streams.sorted { lhs, rhs in
            let lhsScore = streamPreferenceScore(lhs)
            let rhsScore = streamPreferenceScore(rhs)
            if lhsScore == rhsScore {
                return lhs.index < rhs.index
            }
            return lhsScore > rhsScore
        }.first
    }

    private static func streamPreferenceScore(_ stream: FFProbeStream) -> Int {
        let title = tagValue("title", in: stream.tags ?? [:])?.lowercased() ?? ""
        let codec = stream.codecName?.lowercased() ?? ""
        var score = 0
        if isAuroStreamTitle(title) {
            score += 10_000
        }
        if codec == "flac" {
            score += 200
        } else if codec.hasPrefix("pcm_") {
            score += 150
        } else if codec == "truehd" || codec == "mlp" {
            score += 100
        } else if codec == "eac3" {
            score += 60
        } else if codec == "ac3" || codec == "dts" || codec == "dca" {
            score += 40
        }
        score += (stream.channels ?? 0) * 10
        score += Int(stream.bitDepth)
        return score
    }

    private static func displayCodecName(for stream: FFProbeStream) -> String {
        let title = tagValue("title", in: stream.tags ?? [:])?.lowercased() ?? ""
        let codec = stream.codecName?.lowercased() ?? ""

        if codec == "flac" {
            return isAuroStreamTitle(title) ? "Auro-3D FLAC" : "FLAC"
        }
        if codec.hasPrefix("pcm_") {
            return isAuroStreamTitle(title) ? "Auro-3D PCM" : "PCM"
        }
        switch codec {
        case "ac3":
            return "Dolby Digital (AC-3)"
        case "eac3":
            return "Dolby Digital Plus (E-AC-3)"
        case "truehd":
            return "Dolby TrueHD"
        case "mlp":
            return "MLP"
        case "dts", "dca":
            return "DTS"
        default:
            return codec.isEmpty ? "Unknown" : codec.uppercased()
        }
    }

    private static func isAuroStreamTitle(_ title: String) -> Bool {
        title.contains("auro-3d") || title.contains("auro 3d") || title.contains("auro_3d")
    }

    private static func tags(formatTags: [String: String], streamTags: [String: String]) -> AudioSourceTags {
        let format = normalizedTags(formatTags)
        let stream = normalizedTags(streamTags)

        return AudioSourceTags(
            title: format["title"]?.trimmedNilIfBlank ?? stream["title"]?.trimmedNilIfBlank,
            album: format["album"]?.trimmedNilIfBlank ?? stream["album"]?.trimmedNilIfBlank,
            artist: format["artist"]?.trimmedNilIfBlank
                ?? format["album_artist"]?.trimmedNilIfBlank
                ?? format["albumartist"]?.trimmedNilIfBlank
                ?? stream["artist"]?.trimmedNilIfBlank
                ?? stream["album_artist"]?.trimmedNilIfBlank
                ?? stream["albumartist"]?.trimmedNilIfBlank
        )
    }

    private static func normalizedTags(_ rawTags: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: rawTags.map { key, value in
            (key.lowercased(), value)
        })
    }

    private static func tagValue(_ key: String, in tags: [String: String]) -> String? {
        tags.first { $0.key.localizedCaseInsensitiveCompare(key) == .orderedSame }?
            .value
            .trimmedNilIfBlank
    }

    static func runProcess(executableURL: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            outputData: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            errorData: errorPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

struct MatroskaFLACDemuxer {
    func demuxToCAF(url: URL, streamInfo: MatroskaAudioStreamInfo) throws -> URL {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL() else {
            throw MatroskaFLACDemuxerError.missingFFmpeg
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Orbisonic-Matroska", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("caf")

        let result = try MatroskaAudioProbe.runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-v", "error",
                "-y",
                "-i", url.path,
                "-map", "0:\(streamInfo.streamIndex)",
                "-vn",
                "-c:a", "pcm_f32le",
                "-f", "caf",
                outputURL.path
            ]
        )

        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw MatroskaFLACDemuxerError.processFailed(result.errorText.trimmedNilIfBlank ?? "ffmpeg exited \(result.terminationStatus)")
        }

        return outputURL
    }
}

struct CompressedAudioStreamInfo: Equatable, Sendable {
    let codecName: String
    let profile: String?
    let channels: Int
    let channelLayout: String?

    var hasDolbyAtmos: Bool {
        let text = [profile, channelLayout, codecName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return text.contains("atmos")
    }
}

struct CompressedAudioProbe {
    func probeIfAvailable(url: URL) -> CompressedAudioStreamInfo? {
        guard let ffprobeURL = FFmpegToolLocator.ffprobeURL() else { return nil }

        let result: ProcessResult
        do {
            result = try MatroskaAudioProbe.runProcess(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-print_format", "json",
                    "-show_streams",
                    "-select_streams", "a:0",
                    url.path
                ]
            )
        } catch {
            return nil
        }

        guard result.terminationStatus == 0,
              let output = try? JSONDecoder().decode(FFProbeOutput.self, from: result.outputData),
              let stream = output.streams.first(where: { $0.codecType == "audio" })
        else {
            return nil
        }

        return CompressedAudioStreamInfo(
            codecName: stream.codecName ?? "",
            profile: stream.profile,
            channels: stream.channels ?? 0,
            channelLayout: stream.channelLayout
        )
    }
}

enum MatroskaFLACDemuxerError: LocalizedError, Equatable {
    case missingFFmpeg
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFFmpeg:
            "MKV/MKA playback requires ffmpeg. Bundle ffmpeg in Orbisonic.app/Contents/Resources/Tools or set ORBISONIC_FFMPEG_PATH for development."
        case .processFailed(let message):
            "Unable to decode Matroska FLAC audio: \(message)"
        }
    }
}

struct ProcessResult {
    let terminationStatus: Int32
    let outputData: Data
    let errorData: Data

    var errorText: String {
        String(decoding: errorData, as: UTF8.self)
    }
}

private struct FFProbeOutput: Decodable {
    let streams: [FFProbeStream]
    let format: FFProbeFormat?
}

private struct FFProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let profile: String?
    let sampleRate: String?
    let channels: Int?
    let channelLayout: String?
    let bitsPerSample: Int?
    let bitsPerRawSample: String?
    let duration: String?
    let tags: [String: String]?

    var isSupportedOrbisonicAudio: Bool {
        let codec = codecName?.lowercased() ?? ""
        return codec == "flac"
            || codec.hasPrefix("pcm_")
            || FFProbeStream.decodableSurroundBedCodecs.contains(codec)
    }

    // Lossy/lossless surround codecs ffmpeg decodes to a PCM channel bed. We do
    // not render Dolby Atmos / DTS:X objects -- the decoder emits the underlying
    // 5.1/7.1 bed, which the sphere matrix then spatializes.
    static let decodableSurroundBedCodecs: Set<String> = [
        "ac3", "eac3", "truehd", "mlp", "dts", "dca"
    ]

    var bitDepth: UInt32 {
        if let raw = bitsPerRawSample.flatMap(UInt32.init), raw > 0 {
            return raw
        }
        if let sample = bitsPerSample, sample > 0 {
            return UInt32(sample)
        }
        return 0
    }

    var durationValue: TimeInterval? {
        duration.flatMap(TimeInterval.init)
    }

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case profile
        case sampleRate = "sample_rate"
        case channels
        case channelLayout = "channel_layout"
        case bitsPerSample = "bits_per_sample"
        case bitsPerRawSample = "bits_per_raw_sample"
        case duration
        case tags
    }
}

private struct FFProbeFormat: Decodable {
    let duration: String?
    let tags: [String: String]?

    var durationValue: TimeInterval? {
        duration.flatMap(TimeInterval.init)
    }
}
