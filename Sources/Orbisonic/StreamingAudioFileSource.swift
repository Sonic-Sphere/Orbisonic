import AVFoundation
import Foundation

struct PCMChunk: @unchecked Sendable {
    let descriptor: AudioAssetDescriptor
    let startFrame: AVAudioFramePosition
    let buffer: AVAudioPCMBuffer
    let recycleHandler: ((AVAudioPCMBuffer) -> Void)?

    init(
        descriptor: AudioAssetDescriptor,
        startFrame: AVAudioFramePosition,
        buffer: AVAudioPCMBuffer,
        recycleHandler: ((AVAudioPCMBuffer) -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.startFrame = startFrame
        self.buffer = buffer
        self.recycleHandler = recycleHandler
    }

    var frameCount: AVAudioFrameCount {
        buffer.frameLength
    }

    var endFrame: AVAudioFramePosition {
        startFrame + AVAudioFramePosition(frameCount)
    }

    var byteCount: Int {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let listedBytes = audioBuffers.reduce(0) { partial, audioBuffer in
            partial + Int(audioBuffer.mDataByteSize)
        }
        if listedBytes > 0 {
            return listedBytes
        }

        let streamDescription = buffer.format.streamDescription.pointee
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)
        let bytesPerSample = max(bitsPerChannel / 8, PreparedPCMPolicy.bytesPerSample)
        let channelCount = max(Int(buffer.format.channelCount), 1)
        let bytesPerFrame = max(Int(streamDescription.mBytesPerFrame), channelCount * bytesPerSample)
        let frames = Int(buffer.frameLength)
        return buffer.format.isInterleaved ? frames * bytesPerFrame : frames * channelCount * bytesPerSample
    }

    var durationSeconds: TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(frameCount) / buffer.format.sampleRate
    }

    func recycleBuffer() {
        recycleHandler?(buffer)
    }
}

struct PCMQueueSnapshot: Equatable, Sendable {
    let queuedChunks: Int
    let queuedFrames: AVAudioFramePosition
    let queuedBytes: Int
    let maxBytes: Int
    let isFinished: Bool

    var fillRatio: Double {
        guard maxBytes > 0 else { return 0 }
        return min(Double(queuedBytes) / Double(maxBytes), 1)
    }
}

enum StreamingLocalPlaybackPolicy {
    static let enableStreamingLocalPlayback = false
    static let initialPrerollFrames: AVAudioFrameCount = 8_192
    static let steadyChunkFrames: AVAudioFrameCount = 16_384
    static let targetBufferAheadSeconds: TimeInterval = 2
    static let hardPCMByteCap = 128 * 1_024 * 1_024

    // The Sphere render path emits 31 logical channels (30 full-range + 1 LFE) into a
    // 32-channel physical buffer. A whole-file full-prepare render allocates one
    // AVAudioPCMBuffer of channels * frameCount * 4 bytes in 32-bit unsigned arithmetic,
    // which throws std::overflow_error (SIGABRT) once the product exceeds UInt32.max
    // (~34.6M frames, ~12 min @48kHz). Such files MUST take the windowed streaming path
    // so they render full 31-channel spatial instead of crashing or falling back to stereo.
    static let sphereRenderOutputChannelCount = 32

    static func requiresStreamingForFullSpatialRender(
        durationFrames: AVAudioFramePosition?,
        outputChannelCount: Int = sphereRenderOutputChannelCount
    ) -> Bool {
        guard let durationFrames, durationFrames > 0, outputChannelCount > 0 else { return false }
        let totalBytes = Int64(durationFrames) * Int64(outputChannelCount) * 4
        return totalBytes > Int64(UInt32.max)
    }
}

enum LocalGaplessPlaybackPolicy {
    static let enableLocalGaplessSchedulerKey = "Orbisonic.localGapless.enableScheduler"
    static let localGaplessEnableCompressedTrimKey = "Orbisonic.localGapless.enableCompressedTrim"
    static let defaultEnableLocalGaplessScheduler = false
    static let defaultLocalGaplessEnableCompressedTrim = false
    static let localGaplessTargetAheadSeconds: TimeInterval = 4
    static let localGaplessChunkFrames: AVAudioFrameCount = 16_384
    static let localGaplessMaxRetainedPCMBytes = 32 * 1_024 * 1_024

    static var enableLocalGaplessScheduler: Bool {
        bool(forKey: enableLocalGaplessSchedulerKey, defaultValue: defaultEnableLocalGaplessScheduler)
    }

    static var localGaplessEnableCompressedTrim: Bool {
        bool(forKey: localGaplessEnableCompressedTrimKey, defaultValue: defaultLocalGaplessEnableCompressedTrim)
    }

    static func setEnableLocalGaplessScheduler(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enableLocalGaplessSchedulerKey)
    }

    static func setLocalGaplessEnableCompressedTrim(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: localGaplessEnableCompressedTrimKey)
    }

    static func bool(forKey key: String, defaultValue: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum LocalGaplessSchedulerLogEvent: String, CaseIterable, Sendable {
    case schedulerEnabled = "gapless scheduler enabled"
    case sourceOpenFailed = "source open failed"
    case decoderUnderrun = "decoder underrun"
    case queueExhausted = "queue exhausted"
    case gaplessMiss = "gapless miss"
    case generationInvalidated = "generation invalidated"
    case compressedTrimApplied = "compressed trim applied"
    case compressedTrimUnavailable = "compressed trim unavailable"
}

enum LocalGaplessSchedulerLog {
    static let category = "gapless"

    static func message(
        _ event: LocalGaplessSchedulerLogEvent,
        fileName: String? = nil,
        reason: String? = nil
    ) -> String {
        var fields = ["event=\"\(event.rawValue)\""]
        if let fileName, !fileName.isEmpty {
            fields.append("file=\"\(fileName)\"")
        }
        if let reason, !reason.isEmpty {
            fields.append("reason=\"\(reason)\"")
        }
        return fields.joined(separator: " ")
    }
}

enum StreamingAudioFileSourceError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case unsupportedFormat(String)
    case sourceClosed
    case chunkExceedsQueueLimit(chunkBytes: Int, maxBytes: Int)
    case queueFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            "Invalid streaming audio configuration: \(message)"
        case .unsupportedFormat(let message):
            "Unsupported streaming audio format: \(message)"
        case .sourceClosed:
            "The streaming audio source is closed."
        case .chunkExceedsQueueLimit(let chunkBytes, let maxBytes):
            "Decoded PCM chunk is \(chunkBytes) bytes, which exceeds the streaming queue cap of \(maxBytes) bytes."
        case .queueFailed(let message):
            "Streaming audio queue failed: \(message)"
        }
    }
}

protocol PCMFrameDecoder: Sendable {
    var descriptor: AudioAssetDescriptor { get }

    func seek(to frame: AVAudioFramePosition) throws
    func readNextChunk(maxFrames: AVAudioFrameCount) throws -> PCMChunk?
    func close()
}

final class PCMBufferPool: @unchecked Sendable {
    private let format: AVAudioFormat
    private let maxRetainedBuffers: Int
    private let maxFrameCapacity: AVAudioFrameCount
    private let lock = NSLock()
    private var availableBuffers: [AVAudioPCMBuffer] = []

    init(
        format: AVAudioFormat,
        maxRetainedBuffers: Int = 4,
        maxFrameCapacity: AVAudioFrameCount = StreamingLocalPlaybackPolicy.steadyChunkFrames
    ) {
        self.format = format
        self.maxRetainedBuffers = max(0, maxRetainedBuffers)
        self.maxFrameCapacity = maxFrameCapacity
    }

    func checkout(frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.lock()
        if let index = availableBuffers.firstIndex(where: { $0.frameCapacity >= frameCapacity }) {
            let buffer = availableBuffers.remove(at: index)
            buffer.frameLength = 0
            lock.unlock()
            return buffer
        }
        lock.unlock()

        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
    }

    func recycle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format == format,
              buffer.frameCapacity <= maxFrameCapacity,
              maxRetainedBuffers > 0
        else { return }

        buffer.frameLength = 0
        lock.lock()
        if availableBuffers.count < maxRetainedBuffers {
            availableBuffers.append(buffer)
        }
        lock.unlock()
    }
}

actor BoundedPCMQueue {
    private let maxBytes: Int
    private var chunks: [PCMChunk] = []
    private var queuedBytes = 0
    private var queuedFrames: AVAudioFramePosition = 0
    private var isFinished = false
    private var failureMessage: String?

    init(maxBytes: Int = StreamingLocalPlaybackPolicy.hardPCMByteCap) {
        self.maxBytes = max(0, maxBytes)
    }

    func enqueue(_ chunk: PCMChunk) async throws {
        let chunkBytes = chunk.byteCount
        guard chunkBytes <= maxBytes else {
            throw StreamingAudioFileSourceError.chunkExceedsQueueLimit(
                chunkBytes: chunkBytes,
                maxBytes: maxBytes
            )
        }

        while true {
            try Task.checkCancellation()
            if let failureMessage {
                throw StreamingAudioFileSourceError.queueFailed(failureMessage)
            }
            guard !isFinished else {
                throw StreamingAudioFileSourceError.sourceClosed
            }

            if queuedBytes + chunkBytes <= maxBytes {
                chunks.append(chunk)
                queuedBytes += chunkBytes
                queuedFrames += AVAudioFramePosition(chunk.frameCount)
                return
            }

            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func dequeue() async throws -> PCMChunk? {
        while true {
            try Task.checkCancellation()
            if let failureMessage {
                throw StreamingAudioFileSourceError.queueFailed(failureMessage)
            }

            if !chunks.isEmpty {
                let chunk = chunks.removeFirst()
                queuedBytes = max(queuedBytes - chunk.byteCount, 0)
                queuedFrames = max(queuedFrames - AVAudioFramePosition(chunk.frameCount), 0)
                return chunk
            }

            if isFinished {
                return nil
            }

            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func finish() {
        isFinished = true
    }

    func fail(_ message: String) {
        failureMessage = message
        isFinished = true
    }

    func removeAll() {
        chunks.removeAll()
        queuedBytes = 0
        queuedFrames = 0
    }

    func snapshot() -> PCMQueueSnapshot {
        PCMQueueSnapshot(
            queuedChunks: chunks.count,
            queuedFrames: queuedFrames,
            queuedBytes: queuedBytes,
            maxBytes: maxBytes,
            isFinished: isFinished
        )
    }
}

final class AVFoundationPCMFrameDecoder: PCMFrameDecoder, @unchecked Sendable {
    let descriptor: AudioAssetDescriptor

    private let url: URL
    private let outputFormat: AVAudioFormat
    private let bufferPool: PCMBufferPool
    private let debugTiming: DebugTimingContext?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var decodedChunkCount = 0

    init(
        url: URL,
        debugTiming: DebugTimingContext? = nil,
        bufferPool: PCMBufferPool? = nil
    ) throws {
        try Task.checkCancellation()
        self.url = url
        self.debugTiming = debugTiming

        let openedFile = try AVAudioFile(forReading: url)
        let sourceFormat = openedFile.processingFormat
        guard sourceFormat.channelCount > 0,
              sourceFormat.sampleRate > 0
        else {
            throw StreamingAudioFileSourceError.unsupportedFormat("missing sample rate or channel count")
        }
        guard OrbisonicAudioLimits.supportsSourceChannelCount(Int(sourceFormat.channelCount)) else {
            throw AudioFileLoaderError.unsupportedChannelCount(
                sourceFormat.channelCount,
                maxSupported: OrbisonicAudioLimits.maxSourceChannelCount
            )
        }

        guard let floatFormat = Self.makeOutputFormat(from: sourceFormat) else {
            throw StreamingAudioFileSourceError.unsupportedFormat("could not create non-interleaved Float32 output format")
        }
        self.outputFormat = floatFormat
        self.bufferPool = bufferPool ?? PCMBufferPool(format: floatFormat)
        self.descriptor = try AudioFileProbe.probeSynchronously(url: url, debugTiming: debugTiming)
        self.file = openedFile

        if !Self.formatsMatchForDirectRead(sourceFormat, floatFormat) {
            guard let converter = AVAudioConverter(from: sourceFormat, to: floatFormat) else {
                throw StreamingAudioFileSourceError.unsupportedFormat("could not create streaming format converter")
            }
            self.converter = converter
        }

        AppLogger.shared.notice(
            category: "streaming",
            "Streaming source opened file=\(url.lastPathComponent) sampleRate=\(String(format: "%.1f", descriptor.sourceSampleRate)) channels=\(descriptor.channelCount) estimatedDecodedBytes=\(descriptor.estimatedDecodedBytes.map(String.init) ?? "unknown")"
        )
        debugTiming?.log(
            "streaming source opened",
            fileURL: url,
            extra: descriptor.logFields
        )
    }

    func seek(to frame: AVAudioFramePosition) throws {
        try Task.checkCancellation()
        guard let file else { throw StreamingAudioFileSourceError.sourceClosed }
        let clampedFrame = max(0, min(frame, file.length))
        file.framePosition = clampedFrame
        converter?.reset()
        debugTiming?.log(
            "streaming source seek",
            fileURL: url,
            extra: ["frame=\(clampedFrame)"]
        )
    }

    func readNextChunk(maxFrames: AVAudioFrameCount) throws -> PCMChunk? {
        try Task.checkCancellation()
        guard maxFrames > 0 else {
            throw StreamingAudioFileSourceError.invalidConfiguration("maxFrames must be greater than zero")
        }
        guard let file else { throw StreamingAudioFileSourceError.sourceClosed }
        guard file.framePosition < file.length else { return nil }

        let startFrame = file.framePosition
        let remainingFrames = file.length - startFrame
        let requestedFrames = min(maxFrames, AVAudioFrameCount(min(Int64(UInt32.max), remainingFrames)))
        let sourceFormat = file.processingFormat
        let isFirstChunk = decodedChunkCount == 0
        if isFirstChunk {
            debugTiming?.log(
                "first chunk decode started",
                fileURL: url,
                extra: [
                    "startFrame=\(startFrame)",
                    "maxFrames=\(requestedFrames)"
                ]
            )
        }
        let chunkDecodeStart = DispatchTime.now().uptimeNanoseconds

        let outputBuffer: AVAudioPCMBuffer
        if let converter {
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: requestedFrames) else {
                throw AudioFileLoaderError.sourceBufferAllocationFailed
            }

            try file.read(into: sourceBuffer, frameCount: requestedFrames)
            try Task.checkCancellation()
            guard sourceBuffer.frameLength > 0 else { return nil }

            guard let convertedBuffer = bufferPool.checkout(frameCapacity: sourceBuffer.frameLength) else {
                throw AudioFileLoaderError.convertedBufferAllocationFailed
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
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

            try Task.checkCancellation()
            if status == .error || conversionError != nil {
                throw AudioFileLoaderError.formatConversionFailed(conversionError?.localizedDescription ?? "unknown converter error")
            }
            guard convertedBuffer.frameLength > 0 else { return nil }
            outputBuffer = convertedBuffer
        } else {
            guard let directBuffer = bufferPool.checkout(frameCapacity: requestedFrames) else {
                throw AudioFileLoaderError.convertedBufferAllocationFailed
            }
            try file.read(into: directBuffer, frameCount: requestedFrames)
            try Task.checkCancellation()
            guard directBuffer.frameLength > 0 else { return nil }
            outputBuffer = directBuffer
        }

        let chunk = PCMChunk(
            descriptor: descriptor,
            startFrame: startFrame,
            buffer: outputBuffer,
            recycleHandler: { [bufferPool] buffer in
                bufferPool.recycle(buffer)
            }
        )
        decodedChunkCount += 1
        if isFirstChunk {
            debugTiming?.log(
                "first chunk decode finished",
                fileURL: url,
                extra: [
                    "startFrame=\(chunk.startFrame)",
                    "frameCount=\(chunk.frameCount)",
                    "chunkBytes=\(chunk.byteCount)",
                    "decodeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - chunkDecodeStart) / 1_000_000.0))"
                ]
            )
        }
        return chunk
    }

    func close() {
        file = nil
        converter = nil
        debugTiming?.log("streaming source closed", fileURL: url)
    }

    private static func makeOutputFormat(from sourceFormat: AVAudioFormat) -> AVAudioFormat? {
        if let channelLayout = sourceFormat.channelLayout {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
                interleaved: false,
                channelLayout: channelLayout
            )
        }

        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        )
    }

    private static func formatsMatchForDirectRead(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
            lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}

final class StreamingAudioFileSource: @unchecked Sendable {
    struct Configuration: Sendable {
        let initialPrerollFrames: AVAudioFrameCount
        let steadyChunkFrames: AVAudioFrameCount
        let targetBufferAheadSeconds: TimeInterval
        let maxBufferedPCMBytes: Int

        init(
            initialPrerollFrames: AVAudioFrameCount = StreamingLocalPlaybackPolicy.initialPrerollFrames,
            steadyChunkFrames: AVAudioFrameCount = StreamingLocalPlaybackPolicy.steadyChunkFrames,
            targetBufferAheadSeconds: TimeInterval = StreamingLocalPlaybackPolicy.targetBufferAheadSeconds,
            maxBufferedPCMBytes: Int = StreamingLocalPlaybackPolicy.hardPCMByteCap
        ) {
            self.initialPrerollFrames = initialPrerollFrames
            self.steadyChunkFrames = steadyChunkFrames
            self.targetBufferAheadSeconds = targetBufferAheadSeconds
            self.maxBufferedPCMBytes = maxBufferedPCMBytes
        }
    }

    private let url: URL
    private let configuration: Configuration
    private let queue: BoundedPCMQueue
    private let debugTiming: DebugTimingContext?
    private let decoderFactory: @Sendable (URL, DebugTimingContext?) throws -> any PCMFrameDecoder
    private let lock = NSLock()
    private var decodeTask: Task<Void, Never>?

    init(
        url: URL,
        configuration: Configuration = Configuration(),
        debugTiming: DebugTimingContext? = nil,
        decoderFactory: @escaping @Sendable (URL, DebugTimingContext?) throws -> any PCMFrameDecoder = { url, debugTiming in
            try AVFoundationPCMFrameDecoder(url: url, debugTiming: debugTiming)
        }
    ) {
        self.url = url
        self.configuration = configuration
        self.queue = BoundedPCMQueue(maxBytes: configuration.maxBufferedPCMBytes)
        self.debugTiming = debugTiming
        self.decoderFactory = decoderFactory
    }

    func start() {
        lock.lock()
        if decodeTask != nil {
            lock.unlock()
            return
        }

        let url = url
        let configuration = configuration
        let queue = queue
        let debugTiming = debugTiming
        let decoderFactory = decoderFactory
        let task = Task.detached(priority: .utility) {
            var enqueuedChunkCount = 0
            do {
                try Self.validate(configuration)
                let openedDecoder = try decoderFactory(url, debugTiming)
                defer {
                    openedDecoder.close()
                }

                while !Task.isCancelled {
                    let snapshot = await queue.snapshot()
                    let targetFrames = Self.targetBufferAheadFrames(
                        descriptor: openedDecoder.descriptor,
                        configuration: configuration
                    )
                    if targetFrames > 0,
                       snapshot.queuedFrames >= targetFrames {
                        try await Task.sleep(nanoseconds: 2_000_000)
                        continue
                    }

                    let chunkSize = snapshot.queuedFrames < AVAudioFramePosition(configuration.initialPrerollFrames)
                        ? configuration.initialPrerollFrames
                        : configuration.steadyChunkFrames
                    guard let chunk = try openedDecoder.readNextChunk(maxFrames: chunkSize) else {
                        await queue.finish()
                        debugTiming?.log("streaming source reached EOF", fileURL: url)
                        return
                    }

                    try await queue.enqueue(chunk)
                    enqueuedChunkCount += 1
                    let afterEnqueue = await queue.snapshot()
                    if enqueuedChunkCount == 1 || enqueuedChunkCount.isMultiple(of: 16) {
                        debugTiming?.log(
                            enqueuedChunkCount == 1 ? "streaming first buffer queued" : "streaming buffer usage",
                            fileURL: url,
                            extra: [
                                "queuedChunks=\(afterEnqueue.queuedChunks)",
                                "queuedFrames=\(afterEnqueue.queuedFrames)",
                                "currentBytes=\(afterEnqueue.queuedBytes)",
                                "capBytes=\(afterEnqueue.maxBytes)",
                                "fillRatio=\(String(format: "%.3f", afterEnqueue.fillRatio))"
                            ]
                        )
                    }
                }

                throw CancellationError()
            } catch is CancellationError {
                AppLogger.shared.info(category: "streaming", "Streaming source canceled file=\(url.lastPathComponent)")
                debugTiming?.log("streaming source canceled", fileURL: url)
                await queue.finish()
            } catch {
                AppLogger.shared.warning(category: "streaming", "Streaming source failed file=\(url.lastPathComponent) error=\(error.localizedDescription)")
                debugTiming?.log(
                    "streaming source failed",
                    fileURL: url,
                    extra: ["error=\"\(error.localizedDescription)\""]
                )
                await queue.fail(error.localizedDescription)
            }
        }

        decodeTask = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = decodeTask
        decodeTask = nil
        lock.unlock()
        task?.cancel()
        Task {
            await queue.finish()
        }
    }

    func nextChunk() async throws -> PCMChunk? {
        try await queue.dequeue()
    }

    func bufferSnapshot() async -> PCMQueueSnapshot {
        await queue.snapshot()
    }

    func clearBufferedChunks() async {
        await queue.removeAll()
    }

    private static func validate(_ configuration: Configuration) throws {
        guard configuration.initialPrerollFrames > 0 else {
            throw StreamingAudioFileSourceError.invalidConfiguration("initialPrerollFrames must be greater than zero")
        }
        guard configuration.steadyChunkFrames > 0 else {
            throw StreamingAudioFileSourceError.invalidConfiguration("steadyChunkFrames must be greater than zero")
        }
        guard configuration.targetBufferAheadSeconds >= 0,
              configuration.targetBufferAheadSeconds.isFinite
        else {
            throw StreamingAudioFileSourceError.invalidConfiguration("targetBufferAheadSeconds must be finite and non-negative")
        }
        guard configuration.maxBufferedPCMBytes > 0 else {
            throw StreamingAudioFileSourceError.invalidConfiguration("maxBufferedPCMBytes must be greater than zero")
        }
    }

    private static func targetBufferAheadFrames(
        descriptor: AudioAssetDescriptor,
        configuration: Configuration
    ) -> AVAudioFramePosition {
        guard descriptor.sourceSampleRate > 0 else { return 0 }
        let frames = descriptor.sourceSampleRate * configuration.targetBufferAheadSeconds
        guard frames.isFinite,
              frames > 0
        else { return 0 }
        return AVAudioFramePosition(frames.rounded(.up))
    }
}
