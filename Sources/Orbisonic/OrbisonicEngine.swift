import AudioToolbox
import AppKit
import AVFoundation

enum TransportState: String {
    case idle
    case ready
    case playing
    case paused
}

enum OutputDeviceSelectionError: LocalizedError {
    case invalidDevice
    case outputAudioUnitUnavailable
    case setDeviceFailed(OSStatus)
    case invalidDiagnosticChannel(Int, Int)
    case diagnosticFormatCreationFailed(channelCount: Int, sampleRate: Double)
    case diagnosticMonitorOutputUnavailable
    case rendererFormatCreationFailed(channelCount: Int, sampleRate: Double)

    var errorDescription: String? {
        switch self {
        case .invalidDevice:
            "No valid output device was selected."
        case .outputAudioUnitUnavailable:
            "The output audio unit is not available yet."
        case .setDeviceFailed(let status):
            "Could not select that output device. Core Audio returned \(status)."
        case .invalidDiagnosticChannel(let index, let count):
            "Diagnostic channel \(index + 1) is outside the available \(count)-channel range."
        case .diagnosticFormatCreationFailed(let channelCount, let sampleRate):
            "Unable to create a \(channelCount)-channel diagnostic output format at \(sampleRate) Hz."
        case .diagnosticMonitorOutputUnavailable:
            "Output 1 Monitor downmix is not configured."
        case .rendererFormatCreationFailed(let channelCount, let sampleRate):
            "Unable to create a \(channelCount)-channel renderer output format at \(sampleRate) Hz."
        }
    }
}

private final class StreamingScheduledChunk {
    let id = UUID()
    let startFrame: AVAudioFramePosition
    let frameCount: AVAudioFrameCount
    let monoBuffers: [AVAudioPCMBuffer]
    let renderedOutputBuffer: AVAudioPCMBuffer?

    init(
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        monoBuffers: [AVAudioPCMBuffer],
        renderedOutputBuffer: AVAudioPCMBuffer? = nil
    ) {
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.monoBuffers = monoBuffers
        self.renderedOutputBuffer = renderedOutputBuffer
    }

    var byteCount: Int {
        let sourceBytes = monoBuffers.reduce(0) { partial, buffer in
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let listedBytes = audioBuffers.reduce(0) { bytePartial, audioBuffer in
                bytePartial + Int(audioBuffer.mDataByteSize)
            }
            if listedBytes > 0 {
                return partial + listedBytes
            }

            let bytes = PreparedPCMPolicy.estimatedDecodedPCMBytes(
                frameCount: AVAudioFramePosition(buffer.frameLength),
                channelCount: 1
            ) ?? 0
            return partial + bytes
        }
        guard let renderedOutputBuffer else { return sourceBytes }

        let renderedBytes = UnsafeMutableAudioBufferListPointer(renderedOutputBuffer.mutableAudioBufferList)
            .reduce(0) { partial, audioBuffer in
                partial + Int(audioBuffer.mDataByteSize)
            }
        return sourceBytes + renderedBytes
    }
}

private final class StreamingPlaybackContext {
    let token = UUID()
    let source: StreamingAudioFileSource
    let descriptor: AudioAssetDescriptor
    let layout: SurroundLayout
    let metadata: AudioSourceMetadata
    let monoFormat: AVAudioFormat
    let monoBufferPool: PCMBufferPool

    var scheduledChunks: [UUID: StreamingScheduledChunk] = [:]
    var scheduledFrames: AVAudioFramePosition = 0
    var scheduledBytes = 0
    var scheduledChunkCount = 0
    var reachedEndOfSource = false
    var scheduleTask: Task<Void, Never>?

    init(
        source: StreamingAudioFileSource,
        descriptor: AudioAssetDescriptor,
        layout: SurroundLayout,
        metadata: AudioSourceMetadata,
        monoFormat: AVAudioFormat
    ) {
        self.source = source
        self.descriptor = descriptor
        self.layout = layout
        self.metadata = metadata
        self.monoFormat = monoFormat
        self.monoBufferPool = PCMBufferPool(
            format: monoFormat,
            maxRetainedBuffers: max(layout.channelCount * 4, 4),
            maxFrameCapacity: StreamingLocalPlaybackPolicy.steadyChunkFrames
        )
    }

    var durationFrames: AVAudioFramePosition {
        descriptor.durationFrames ?? 0
    }

    var durationSeconds: TimeInterval {
        descriptor.durationSeconds ?? 0
    }
}

private final class LocalGaplessMultiNodeSchedulingPlayer: LocalGaplessPlayerScheduling {
    private let players: [AVAudioPlayerNode]
    private let monoFormat: AVAudioFormat
    private let callbackQueue = DispatchQueue(label: "com.orbisonic.local-gapless.player-callback")
    private let retainedLock = NSLock()
    private var retainedBuffers: [UUID: [AVAudioPCMBuffer]] = [:]

    init(players: [AVAudioPlayerNode], monoFormat: AVAudioFormat) {
        self.players = players
        self.monoFormat = monoFormat
    }

    func scheduleGaplessBuffer(
        _ buffer: AVAudioPCMBuffer,
        completion: @escaping (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) {
        guard !players.isEmpty,
              buffer.frameLength > 0
        else { return }

        let id = UUID()
        let monoBuffers = makeMonoBuffers(from: buffer)
        retainedLock.lock()
        retainedBuffers[id] = monoBuffers
        retainedLock.unlock()

        for (index, player) in players.enumerated() {
            let monoBuffer = monoBuffers[index]
            if index == 0 {
                player.scheduleBuffer(monoBuffer, completionCallbackType: .dataPlayedBack) { [weak self] callbackType in
                    guard let self else { return }
                    self.releaseBuffers(id: id)
                    self.callbackQueue.async {
                        completion(callbackType)
                    }
                }
            } else {
                player.scheduleBuffer(monoBuffer, completionCallbackType: .dataPlayedBack)
            }
        }
    }

    func playGapless() {
        let hostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.03)
        let startTime = AVAudioTime(hostTime: hostTime)
        players.forEach { $0.play(at: startTime) }
    }

    func pauseGapless() {
        players.forEach { $0.pause() }
    }

    func stopGapless() {
        players.forEach { $0.stop() }
        retainedLock.lock()
        retainedBuffers.removeAll()
        retainedLock.unlock()
    }

    private func makeMonoBuffers(from buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        let frameCount = buffer.frameLength
        let sourceChannelCount = Int(buffer.format.channelCount)
        let sourceChannels = buffer.floatChannelData

        return players.indices.map { channelIndex in
            let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount)!
            monoBuffer.frameLength = frameCount
            guard let destination = monoBuffer.floatChannelData?[0] else {
                return monoBuffer
            }

            if let sourceChannels,
               channelIndex < sourceChannelCount {
                destination.update(from: sourceChannels[channelIndex], count: Int(frameCount))
            } else {
                destination.initialize(repeating: 0, count: Int(frameCount))
            }
            return monoBuffer
        }
    }

    private func releaseBuffers(id: UUID) {
        retainedLock.lock()
        retainedBuffers.removeValue(forKey: id)
        retainedLock.unlock()
    }
}

struct LocalGaplessEngineQueueSnapshot: Equatable, Sendable {
    let tracks: [LocalGaplessTrackDescriptor]
    let startIndex: Int

    init(
        tracks: [LocalGaplessTrackDescriptor],
        startIndex: Int
    ) {
        self.tracks = tracks
        self.startIndex = startIndex
    }

    var currentTrack: LocalGaplessTrackDescriptor? {
        guard tracks.indices.contains(startIndex) else { return nil }
        return tracks[startIndex]
    }

    var nextTrack: LocalGaplessTrackDescriptor? {
        let nextIndex = startIndex + 1
        guard tracks.indices.contains(nextIndex) else { return nil }
        return tracks[nextIndex]
    }
}

final class OrbisonicEngine {
    var onPlaybackEnded: (() -> Void)?
    var onLocalGaplessLogicalTrackStarted: ((LocalGaplessTrackDescriptor) -> Void)?
    var onLocalGaplessLogicalTrackEnded: ((LocalGaplessTrackDescriptor) -> Void)?
    var onLocalGaplessQueueEnded: (() -> Void)?

    private static let maxStreamingScheduledAheadSeconds: TimeInterval = 2
    private static let maxStreamingScheduledPCMBytes = 64 * 1_024 * 1_024
    private static let isRunningUnitTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
            NSClassFromString("XCTest.XCTestCase") != nil ||
            NSClassFromString("XCTestCase") != nil
    }()

    private let audioGraphEnabled: Bool
    private lazy var engine = AVAudioEngine()
    private lazy var preVolumeMixer = AVAudioMixerNode()
    private lazy var outputGainMixer = AVAudioMixerNode()
    private let loader = AudioFileLoader()
    private lazy var diagnosticMonitorEngine = AVAudioEngine()
    private let meteringService = MeteringService()
    private let fixedLocalGaplessConfig: LocalGaplessSchedulerConfig?
    private var localGaplessConfig: LocalGaplessSchedulerConfig {
        fixedLocalGaplessConfig ?? LocalGaplessSchedulerConfig()
    }

    private(set) var loadedFile: LoadedAudioFile?
    private(set) var state: TransportState = .idle
    private(set) var tuning: SpatialTuning = .default
    private(set) var liveInputSource: LiveInputSource?

    private var playerNodes: [AVAudioPlayerNode] = []
    private var sourceNodes: [AVAudioSourceNode] = []
    private var testToneNodes: [AVAudioSourceNode] = []
    private var diagnosticMonitorToneNodes: [AVAudioSourceNode] = []
    private var diagnosticMonitorOutputDeviceID: AudioDeviceID?
    private var livePipe: LiveAudioPipe?
    private var liveCapture: LiveInputCapture?
    private var liveStartDate: Date?
    private var liveInputMuted = false
    private var rendererMode: RendererRenderMode = .automatic
    private var rendererScene: RendererSceneModel = .empty
    private var streamingPlayback: StreamingPlaybackContext?
    private var localGaplessQueueSnapshot: LocalGaplessEngineQueueSnapshot?
    private var localGaplessScheduler: LocalGaplessScheduler?
    private var localGaplessTrackFrameCounts: [String: AVAudioFramePosition] = [:]
    private var localGaplessCurrentTrack: LocalGaplessTrackDescriptor?
    private var localGaplessCurrentTrackFrameCount: AVAudioFramePosition?
    private var localGaplessTrackStartPlayerSampleTime: AVAudioFramePosition = 0
    private var currentStartFrame: AVAudioFramePosition = 0
    private var completionToken = UUID()
    private var pausedPlaybackNeedsReschedule = false
#if DEBUG
    private(set) var debugPlaybackGraphBuildCount = 0
    private(set) var debugScheduleFromCurrentPositionCount = 0
    var debugPausedPlaybackNeedsReschedule: Bool { pausedPlaybackNeedsReschedule }
#endif

    init(localGaplessConfig: LocalGaplessSchedulerConfig? = nil, audioGraphEnabled: Bool? = nil) {
        let resolvedAudioGraphEnabled = audioGraphEnabled ?? !Self.isRunningUnitTests
        self.audioGraphEnabled = resolvedAudioGraphEnabled
        self.fixedLocalGaplessConfig = localGaplessConfig
        if resolvedAudioGraphEnabled {
            configureGraph()
            applyTuning(.default)
        }
        AppLogger.shared.notice(
            category: "engine",
            "Engine initialized. outputType=normal-monitor-stereo audioGraphEnabled=\(resolvedAudioGraphEnabled) logFile=\(AppLogger.logFilePath)"
        )
    }

    func loadFile(url: URL) throws -> LoadedAudioFile {
        AppLogger.shared.info(category: "engine", "Loading file into engine: \(url.lastPathComponent)")

        stopLiveInput()
        detachSourceNodes()

        let loaded = try loader.load(url: url)
        return loadPreparedFile(loaded)
    }

    func loadPreparedFile(
        _ loaded: LoadedAudioFile,
        debugTiming: DebugTimingContext? = nil,
        localGaplessQueue: LocalGaplessEngineQueueSnapshot? = nil
    ) -> LoadedAudioFile {
        let commitStart = DispatchTime.now().uptimeNanoseconds
        debugTiming?.log("commit start", fileURL: loaded.url)
        AppLogger.shared.info(category: "engine", "Loading prepared file into engine: \(loaded.url.lastPathComponent)")

        cancelLocalGaplessScheduler(reason: "prepared file loaded")
        cancelStreamingPlayback(reason: "prepared file loaded")
        debugTiming?.log(
            "stop old local playback start",
            fileURL: loaded.url,
            extra: ["engineState=\"\(state.rawValue)\"", "hadLoadedFile=\(loadedFile != nil)"]
        )
        stopLiveInput()
        detachSourceNodes()
        debugTiming?.log("stop old local playback end", fileURL: loaded.url)

        debugTiming?.log("replace current source start", fileURL: loaded.url)
        loadedFile = loaded
        localGaplessQueueSnapshot = localGaplessQueue
        localGaplessCurrentTrack = localGaplessQueue?.currentTrack
        localGaplessCurrentTrackFrameCount = loaded.frameCount
        localGaplessTrackStartPlayerSampleTime = 0
        localGaplessTrackFrameCounts = localGaplessFrameCounts(for: localGaplessQueue, loadedFile: loaded)
        liveInputSource = nil
        currentStartFrame = 0
        pausedPlaybackNeedsReschedule = false
        state = .ready
        debugTiming?.log("replace current source end", fileURL: loaded.url)

        if audioGraphEnabled {
            rebuildPlaybackGraph(for: loaded, debugTiming: debugTiming)
            applyTuning(tuning)
        }

        AppLogger.shared.notice(
            category: "engine",
            "Load complete state=\(state.rawValue) layout=\(loaded.layout.name) channels=\(loaded.layout.channelSummary)"
        )
        debugTiming?.log(
            "commit finish",
            fileURL: loaded.url,
            extra: ["commitMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - commitStart) / 1_000_000.0))"]
        )

        return loaded
    }

    @MainActor
    func startStreaming(
        source: StreamingAudioFileSource,
        descriptor: AudioAssetDescriptor,
        debugTiming: DebugTimingContext? = nil
    ) async throws {
        let commitStart = DispatchTime.now().uptimeNanoseconds
        debugTiming?.log(
            "streaming engine commit start",
            fileURL: descriptor.url,
            extra: descriptor.logFields
        )

        guard descriptor.channelCount > 0,
              OrbisonicAudioLimits.supportsSourceChannelCount(descriptor.channelCount)
        else {
            throw AudioFileLoaderError.unsupportedChannelCount(
                UInt32(max(descriptor.channelCount, 0)),
                maxSupported: OrbisonicAudioLimits.maxSourceChannelCount
            )
        }
        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: descriptor.sourceSampleRate,
            channels: 1
        ) else {
            throw AudioFileLoaderError.monoFormatCreationFailed(descriptor.sourceSampleRate)
        }

        stopLiveInput()
        stopTestTone()
        cancelLocalGaplessScheduler(reason: "streaming source started")
        cancelStreamingPlayback(reason: "new streaming source")
        detachSourceNodes()

        let metadata = Self.streamingMetadata(for: descriptor)
        let context = StreamingPlaybackContext(
            source: source,
            descriptor: descriptor,
            layout: descriptor.channelLayout,
            metadata: metadata,
            monoFormat: monoFormat
        )

        loadedFile = nil
        liveInputSource = nil
        streamingPlayback = context
        currentStartFrame = 0
        pausedPlaybackNeedsReschedule = false
        state = .ready
        completionToken = context.token

        if !audioGraphEnabled {
            source.start()
            do {
                try await scheduleStreamingPreroll(for: context, debugTiming: debugTiming)
            } catch {
                cancelStreamingPlayback(reason: "initial preroll failed")
                throw error
            }
            state = .playing
            AppLogger.shared.notice(
                category: "streaming",
                "Started streaming playback without CoreAudio graph file=\(descriptor.url.lastPathComponent) channels=\(descriptor.channelCount)"
            )
            return
        }

        rebuildStreamingPlaybackGraph(for: context, debugTiming: debugTiming)
        applyTuning(tuning)

        source.start()
        do {
            try await scheduleStreamingPreroll(for: context, debugTiming: debugTiming)
        } catch {
            cancelStreamingPlayback(reason: "initial preroll failed")
            throw error
        }

        if !engine.isRunning {
            try engine.start()
            AppLogger.shared.notice(category: "engine", "AVAudioEngine started for streaming local playback.")
        }
        debugTiming?.log(
            "playback scheduled",
            fileURL: descriptor.url,
            extra: [
                "scheduledFrames=\(context.scheduledFrames)",
                "currentBytes=\(context.scheduledBytes)",
                "capBytes=\(Self.maxStreamingScheduledPCMBytes)"
            ]
        )
        startPlayers()
        state = .playing
        startStreamingScheduleTask(for: context, debugTiming: debugTiming)
        debugTiming?.log(
            "playback started",
            fileURL: descriptor.url,
            extra: [
                "scheduledFrames=\(context.scheduledFrames)",
                "currentBytes=\(context.scheduledBytes)",
                "capBytes=\(Self.maxStreamingScheduledPCMBytes)"
            ]
        )

        AppLogger.shared.notice(
            category: "streaming",
            "Started streaming playback file=\(descriptor.url.lastPathComponent) channels=\(descriptor.channelCount) sampleRate=\(String(format: "%.1f", descriptor.sourceSampleRate)) scheduledBytes=\(context.scheduledBytes)"
        )
        debugTiming?.log(
            "streaming engine commit finish",
            fileURL: descriptor.url,
            extra: [
                "commitMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - commitStart) / 1_000_000.0))",
                "scheduledFrames=\(context.scheduledFrames)",
                "scheduledBytes=\(context.scheduledBytes)"
            ]
        )
    }

    func updateRenderer(
        mode: RendererRenderMode,
        scene: RendererSceneModel
    ) {
        rendererMode = mode
        rendererScene = scene

        guard audioGraphEnabled else { return }
        guard let loadedFile, liveInputSource == nil, testToneNodes.isEmpty else { return }
        guard state != .playing, state != .paused else {
            AppLogger.shared.info(category: "renderer", "Deferred renderer graph rebuild until playback stops or resumes.")
            return
        }

        rebuildPlaybackGraph(for: loadedFile)
        applyTuning(tuning)
        AppLogger.shared.notice(
            category: "renderer",
            "Configured renderer mode=\(mode.rawValue) directAudio=false matrix=\(scene.matrix.inputCount)x\(scene.matrix.outputCount)"
        )
    }

    func setOutputVolume(_ volume: Float) {
        guard audioGraphEnabled else { return }
        outputGainMixer.outputVolume = min(max(volume, 0), 1)
        diagnosticMonitorEngine.mainMixerNode.outputVolume = min(max(volume, 0), 1)
    }

    func updateMeterCalibration(_ calibration: VUMeterCalibrationSettings) {
        meteringService.updateCalibration(calibration)
    }

    func setDiagnosticMonitorOutputDevice(_ deviceID: AudioDeviceID?) throws {
        guard let deviceID, deviceID != 0 else {
            diagnosticMonitorOutputDeviceID = nil
            return
        }

        guard audioGraphEnabled else {
            diagnosticMonitorOutputDeviceID = deviceID
            return
        }

        guard let audioUnit = diagnosticMonitorEngine.outputNode.audioUnit else {
            throw OutputDeviceSelectionError.outputAudioUnitUnavailable
        }

        if diagnosticMonitorEngine.isRunning {
            diagnosticMonitorEngine.stop()
        }

        var selectedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw OutputDeviceSelectionError.setDeviceFailed(status)
        }

        diagnosticMonitorOutputDeviceID = deviceID
        AppLogger.shared.notice(category: "engine", "Selected diagnostic monitor output device id=\(deviceID).")
    }

    func startLiveInput(
        activeChannelCount requestedChannelCount: Int,
        inputRoute: InputRouteInfo,
        sourceName: String = "Live Input",
        rendererMode: RendererRenderMode = .automatic,
        rendererPreset: RendererPreset = .sonicSphere30Point1
    ) throws -> LiveInputSource {
        stopTestTone()
        stop()
        cancelLocalGaplessScheduler(reason: "live input started")
        detachPlayerNodes()
        detachSourceNodes()
        cancelStreamingPlayback(reason: "live input started")

        guard inputRoute.isAvailable else {
            throw LiveInputError.inputDeviceUnavailable(inputRoute.deviceName)
        }

        let availableChannels = UInt32(inputRoute.inputChannelCount)
        let sampleRate = inputRoute.nominalSampleRate > 0
            ? inputRoute.nominalSampleRate
            : preferredOutputSampleRate()

        guard availableChannels > 0 else {
            throw LiveInputError.noInputChannels
        }

        guard requestedChannelCount > 0,
              requestedChannelCount <= Int(availableChannels),
              OrbisonicAudioLimits.supportsSourceChannelCount(requestedChannelCount)
        else {
            throw LiveInputError.unsupportedChannelRequest(
                requested: requestedChannelCount,
                available: availableChannels,
                maxSupported: OrbisonicAudioLimits.maxSourceChannelCount
            )
        }

        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw LiveInputError.monoFormatCreationFailed(sampleRate)
        }

        let layout = SurroundLayoutDetector.fallbackLayout(for: requestedChannelCount)
        let liveLayoutSource = "Live Core Audio route channel count; no explicit semantic layout"
        let metadata = AudioSourceMetadata(
            fileName: sourceName,
            containerName: "Live",
            codecName: "CoreAudio Float32",
            layoutName: layout.name,
            channelSummary: layout.channelSummary,
            channelCount: layout.channelCount,
            sampleRate: sampleRate,
            bitDepth: 32,
            duration: 0,
            channelLayoutConfidence: AudioSourceMetadata.fallbackLayoutConfidence(for: layout.channelCount),
            channelLayoutSourceDescription: requestedChannelCount > 2 ? liveLayoutSource : "Live Core Audio route",
            channelLayoutWarnings: AudioSourceMetadata.fallbackLayoutWarnings(
                channelCount: layout.channelCount,
                channelSummary: layout.channelSummary,
                sourceDescription: liveLayoutSource
            )
        )
        let liveSource = LiveInputSource(layout: layout, metadata: metadata)
        let liveRendererScene = RendererMatrixBuilder.sceneModel(
            for: layout,
            preset: rendererPreset,
            renderMode: rendererMode
        )
        let pipe = LiveAudioPipe(
            channelCount: requestedChannelCount,
            sampleRate: sampleRate,
            meteringService: meteringService
        )
        let capture = try LiveInputCapture(
            inputRoute: inputRoute,
            activeChannelCount: requestedChannelCount,
            sampleRate: sampleRate,
            pipe: pipe
        )

        livePipe = pipe
        liveCapture = capture
        liveInputSource = liveSource
        liveInputMuted = false
        loadedFile = nil
        currentStartFrame = 0
        self.rendererMode = liveRendererScene.renderMode
        rendererScene = liveRendererScene

        meteringService.setInactive(signal: .sonicSphere, channelCount: liveRendererScene.matrix.outputCount)
        sourceNodes = layout.channels.enumerated().map { index, _ in
            AVAudioSourceNode { [weak self, weak pipe] _, _, frameCount, audioBufferList in
                let status = pipe?.render(channelIndex: index, audioBufferList: audioBufferList, frameCount: frameCount) ?? noErr
                if self?.liveInputMuted == true {
                    Self.clear(audioBufferList: audioBufferList, frameCount: Int(frameCount))
                }
                return status
            }
        }

        for (channel, sourceNode) in zip(layout.channels, sourceNodes) {
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: preVolumeMixer, format: monoFormat)
            configureNormalMonitorNode(sourceNode, for: channel, sourceChannelCount: layout.channelCount)
        }

        applyTuning(tuning)

        do {
            if !engine.isRunning {
                try engine.start()
                AppLogger.shared.notice(category: "engine", "AVAudioEngine started for live input.")
            }
            try capture.start()
        } catch {
            stopLiveInput()
            throw error
        }

        liveStartDate = Date()
        state = .playing

        AppLogger.shared.notice(
            category: "live-input",
            "Started live input source=\(sourceName) input=\(inputRoute.deviceName) inputUID=\(inputRoute.uid) inputChannels=\(availableChannels) activeChannels=\(requestedChannelCount) sampleRate=\(sampleRate) layout=\(layout.name) rendererMode=\(rendererMode.rawValue) directAudio=false"
        )

        return liveSource
    }

    func play(debugTiming: DebugTimingContext? = nil) throws {
        stopTestTone()

        if let streamingPlayback {
            try playStreaming(streamingPlayback, debugTiming: debugTiming)
            return
        }

        guard let loadedFile else {
            AppLogger.shared.error(category: "engine", "Play requested with no loaded file.")
            return
        }

        guard audioGraphEnabled else {
#if DEBUG
            if pausedPlaybackNeedsReschedule {
                debugScheduleFromCurrentPositionCount += 1
            }
#endif
            pausedPlaybackNeedsReschedule = false
            state = .playing
            AppLogger.shared.notice(category: "transport", "Started playback without CoreAudio graph for tests.")
            return
        }

        if !engine.isRunning {
            try engine.start()
            AppLogger.shared.notice(category: "engine", "AVAudioEngine started successfully.")
        }

        switch state {
        case .paused:
            if localGaplessScheduler != nil {
                localGaplessScheduler?.resume()
                AppLogger.shared.debug(category: LocalGaplessSchedulerLog.category, "Resumed local gapless playback at frame=\(currentStartFrame).")
            } else if pausedPlaybackNeedsReschedule {
                scheduleFromCurrentPosition(debugTiming: debugTiming)
                startPlayers()
                AppLogger.shared.notice(category: "transport", "Rescheduled paused playback at frame=\(currentStartFrame).")
            } else {
                startPlayers()
            }
            pausedPlaybackNeedsReschedule = false
            state = .playing
            AppLogger.shared.notice(category: "transport", "Resumed playback at \(formatTime(currentTime())) / \(loadedFile.metadata.durationText).")
        case .playing:
            AppLogger.shared.debug(category: "transport", "Play requested while already playing.")
        case .idle, .ready:
            if try startLocalGaplessPlaybackIfPossible(for: loadedFile, debugTiming: debugTiming) {
                debugTiming?.log(
                    "gapless playback scheduled",
                    fileURL: loadedFile.url,
                    extra: [
                        "startFrame=\(currentStartFrame)",
                        "queueCount=\(localGaplessQueueSnapshot?.tracks.count ?? 0)"
                    ]
                )
            } else {
                scheduleFromCurrentPosition(debugTiming: debugTiming)
                debugTiming?.log(
                    "playback scheduled",
                    fileURL: loadedFile.url,
                    extra: [
                        "startFrame=\(currentStartFrame)",
                        "preparedBytes=\(loadedFile.preparedPCMByteCount)"
                    ]
                )
                startPlayers()
            }
            state = .playing
            debugTiming?.log(
                "playback started",
                fileURL: loadedFile.url,
                extra: [
                    "startFrame=\(currentStartFrame)",
                    "preparedBytes=\(loadedFile.preparedPCMByteCount)"
                ]
            )
            AppLogger.shared.notice(
                category: "transport",
                "Started playback state=\(state.rawValue) startFrame=\(currentStartFrame) layout=\(loadedFile.layout.name)"
            )
        }
    }

    func pause() {
        guard state == .playing else { return }
        currentStartFrame = playbackFrame()
        pausedPlaybackNeedsReschedule = false
        if localGaplessScheduler != nil {
            localGaplessTrackStartPlayerSampleTime = currentLocalGaplessPlayerSampleTime() ?? localGaplessTrackStartPlayerSampleTime
            localGaplessScheduler?.pause()
        } else if streamingPlayback != nil {
            playerNodes.forEach { $0.pause() }
        } else {
            playerNodes.forEach { $0.pause() }
        }
        state = .paused
        AppLogger.shared.notice(category: "transport", "Paused playback at frame=\(currentStartFrame) time=\(formatTime(currentTime())).")
    }

    func setLiveInputMuted(_ muted: Bool) {
        guard liveInputSource != nil else { return }
        liveInputMuted = muted
        AppLogger.shared.notice(category: "live-input", "Live input mute=\(muted)")
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        guard audioGraphEnabled else { return }
        guard deviceID != 0 else {
            throw OutputDeviceSelectionError.invalidDevice
        }

        guard let audioUnit = engine.outputNode.audioUnit else {
            throw OutputDeviceSelectionError.outputAudioUnitUnavailable
        }

        if engine.isRunning {
            markPausedPlaybackNeedsReschedule(reason: "output device change")
            cancelLocalGaplessScheduler(reason: "output device change")
            engine.stop()
            resetMonitorMeterLevels()
        }

        var selectedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw OutputDeviceSelectionError.setDeviceFailed(status)
        }

        AppLogger.shared.notice(category: "engine", "Selected output device id=\(deviceID).")
    }

    @discardableResult
    func setOutputDevicePreservingPlayback(_ deviceID: AudioDeviceID) throws -> Bool {
        guard audioGraphEnabled else { return false }
        let snapshot = OutputDevicePlaybackSnapshot(
            wasEngineRunning: engine.isRunning,
            transportState: state,
            resumeFrame: playbackFrame(),
            hadLiveInput: liveInputSource != nil || livePipe != nil || liveCapture != nil || !sourceNodes.isEmpty,
            hadTestTone: !testToneNodes.isEmpty
        )

        do {
            try setOutputDevice(deviceID)
        } catch {
            _ = try? restorePlayback(afterOutputDeviceChange: snapshot)
            throw error
        }

        return try restorePlayback(afterOutputDeviceChange: snapshot)
    }

    func stop() {
        let hadStreamingPlayback = streamingPlayback != nil
        if !audioGraphEnabled {
            cancelLocalGaplessScheduler(reason: "transport stop")
            cancelStreamingPlayback(reason: "transport stop")
            completionToken = UUID()
            currentStartFrame = 0
            pausedPlaybackNeedsReschedule = false
            state = (loadedFile == nil && !hadStreamingPlayback) ? .idle : .ready
            AppLogger.shared.notice(category: "transport", "Stopped playback without CoreAudio graph. state=\(state.rawValue)")
            return
        }
        cancelLocalGaplessScheduler(reason: "transport stop")
        playerNodes.forEach { $0.stop() }
        cancelStreamingPlayback(reason: "transport stop")
        if liveInputSource != nil {
            stopLiveInput()
        }
        stopTestTone()
        stopDiagnosticMonitorTone()
        stopEngineIfRunning(reason: "transport stop")
        completionToken = UUID()
        currentStartFrame = 0
        pausedPlaybackNeedsReschedule = false
        state = (loadedFile == nil && !hadStreamingPlayback) ? .idle : .ready
        AppLogger.shared.notice(category: "transport", "Stopped playback. state=\(state.rawValue)")
    }

    func playTestTone(_ point: TestTonePipelinePoint, monitorDownmix: Bool = false) throws {
        cancelLocalGaplessScheduler(reason: "test tone started")
        playerNodes.forEach { $0.stop() }
        if liveInputSource != nil {
            stopLiveInput()
        }
        stopTestTone()

        let sampleRate = preferredOutputSampleRate()
        let node = makeToneNode(
            frequency: point.frequency,
            sampleRate: sampleRate,
            gain: point.gain
        )

        engine.attach(node)

        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw LiveInputError.monoFormatCreationFailed(sampleRate)
        }

        configureStereoMonitorOutputGraph(sampleRate: sampleRate)
        engine.connect(node, to: preVolumeMixer, format: stereoFormat)
        testToneNodes = [node]

        if !engine.isRunning {
            try engine.start()
            AppLogger.shared.notice(category: "engine", "AVAudioEngine started for diagnostic tone.")
        }

        if monitorDownmix {
            try playDiagnosticMonitorTone(
                frequency: point.frequency,
                sampleRate: sampleRate,
                gain: min(point.gain * 1.8, 0.28)
            )
        }

        AppLogger.shared.notice(
            category: "diagnostics",
            "Started test tone point=\(point.rawValue) frequency=\(point.frequency)Hz route=\(point.pipelineDescription) monitorDownmix=\(monitorDownmix)"
        )
    }

    private func currentOutputDeviceConfiguration() -> (channelCount: Int, sampleRate: Double)? {
        guard let audioUnit = engine.outputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != 0 else { return nil }
        let channels = outputDeviceChannelCount(deviceID)
        guard channels > 0 else { return nil }
        let rate = outputDeviceNominalSampleRate(deviceID)
        return (channels, rate > 0 ? rate : preferredOutputSampleRate())
    }

    private func outputDeviceChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let listPtr = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
        return listPtr.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func outputDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return Double(rate)
    }

    func playDiagnosticChannelTone(
        channelIndex: Int,
        channelCount: Int,
        monitorDownmix: Bool = false,
        primaryOutputEnabled: Bool = true
    ) throws {
        guard channelCount > 0, channelIndex >= 0, channelIndex < channelCount else {
            throw OutputDeviceSelectionError.invalidDiagnosticChannel(channelIndex, channelCount)
        }

        cancelLocalGaplessScheduler(reason: "diagnostic channel tone started")
        playerNodes.forEach { $0.stop() }
        if liveInputSource != nil {
            stopLiveInput()
        }
        stopTestTone()

        let deviceConfig = currentOutputDeviceConfiguration()
        let sampleRate = deviceConfig?.sampleRate ?? preferredOutputSampleRate()

        let node: AVAudioSourceNode
        let diagnosticAudioDescription: String
        if let speechClip = DiagnosticSpeechRenderer.clip(for: channelIndex + 1) {
            node = makeChannelVoiceNode(
                clip: speechClip,
                channelIndex: channelIndex,
                outputSampleRate: sampleRate
            )
            diagnosticAudioDescription = "speechSampleRate=\(speechClip.sampleRate) outputSampleRate=\(sampleRate)"
        } else {
            let frequency = 440 + Double(channelIndex % 12) * 18
            node = makeChannelToneNode(
                channelIndex: channelIndex,
                frequency: frequency,
                sampleRate: sampleRate,
                gain: 0.14
            )
            diagnosticAudioDescription = "fallbackToneFrequency=\(frequency)Hz outputSampleRate=\(sampleRate)"
        }

        if primaryOutputEnabled {
            let hardwareChannelCount = deviceConfig?.channelCount ?? Int(engine.outputNode.inputFormat(forBus: 0).channelCount)
            let primaryChannelCount = max(channelCount, hardwareChannelCount)
            let primaryFormat = try diagnosticChannelFormat(
                channelCount: primaryChannelCount,
                sampleRate: sampleRate
            )
            if engine.isRunning {
                engine.stop()
                resetMonitorMeterLevels()
            }
            configureRendererOutputGraph(format: primaryFormat)
            engine.attach(node)
            engine.connect(node, to: outputGainMixer, format: primaryFormat)
            testToneNodes = [node]

            if !engine.isRunning {
                try engine.start()
                AppLogger.shared.notice(category: "engine", "AVAudioEngine started for channel diagnostic tone.")
            }
        } else {
            testToneNodes = []
        }

        if monitorDownmix {
            if let speechClip = DiagnosticSpeechRenderer.clip(for: channelIndex + 1) {
                try playDiagnosticMonitorVoice(clip: speechClip, sampleRate: sampleRate)
            } else {
                let frequency = 440 + Double(channelIndex % 12) * 18
                try playDiagnosticMonitorTone(frequency: frequency, sampleRate: sampleRate, gain: 0.18)
            }
        }

        AppLogger.shared.notice(
            category: "diagnostics",
            "Started channel diagnostic tone channel=\(channelIndex + 1)/\(channelCount) \(diagnosticAudioDescription) monitorDownmix=\(monitorDownmix) primaryOutput=\(primaryOutputEnabled)"
        )
    }

    private func diagnosticChannelFormat(channelCount: Int, sampleRate: Double) throws -> AVAudioFormat {
        guard channelCount > 2 else {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount)
            ) else {
                throw OutputDeviceSelectionError.diagnosticFormatCreationFailed(
                    channelCount: channelCount,
                    sampleRate: sampleRate
                )
            }
            return format
        }

        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            throw OutputDeviceSelectionError.diagnosticFormatCreationFailed(
                channelCount: channelCount,
                sampleRate: sampleRate
            )
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )

        return format
    }

    func stopTestTone() {
        guard audioGraphEnabled else {
            testToneNodes = []
            diagnosticMonitorToneNodes = []
            return
        }
        stopDiagnosticMonitorTone()
        guard !testToneNodes.isEmpty else { return }

        testToneNodes.forEach { node in
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        testToneNodes = []
        AppLogger.shared.notice(category: "diagnostics", "Stopped test tone.")
    }

    private func stopDiagnosticMonitorTone() {
        guard audioGraphEnabled else {
            diagnosticMonitorToneNodes = []
            return
        }
        guard !diagnosticMonitorToneNodes.isEmpty || diagnosticMonitorEngine.isRunning else { return }

        diagnosticMonitorToneNodes.forEach { node in
            diagnosticMonitorEngine.disconnectNodeOutput(node)
            diagnosticMonitorEngine.detach(node)
        }
        diagnosticMonitorToneNodes = []
        if diagnosticMonitorEngine.isRunning {
            diagnosticMonitorEngine.stop()
        }
        AppLogger.shared.notice(category: "diagnostics", "Stopped diagnostic monitor downmix.")
    }

    func seek(toProgress progress: Double) {
        if let streamingPlayback {
            let clampedProgress = progress.clamped(to: 0...1)
            let frameCount = streamingPlayback.durationFrames
            let nextFrame = AVAudioFramePosition(Double(frameCount) * clampedProgress)
            currentStartFrame = min(nextFrame, max(frameCount - 1, 0))
            AppLogger.shared.info(
                category: "streaming",
                "Streaming seek requested progress=\(String(format: "%.3f", clampedProgress)) frame=\(currentStartFrame); canceling current streaming decode."
            )
            playerNodes.forEach { $0.stop() }
            cancelStreamingPlayback(reason: "seek")
            pausedPlaybackNeedsReschedule = false
            state = .ready
            return
        }

        guard let loadedFile else { return }
        let clampedProgress = progress.clamped(to: 0...1)
        let nextFrame = AVAudioFramePosition(Double(loadedFile.frameCount) * clampedProgress)
        currentStartFrame = min(nextFrame, max(loadedFile.frameCount - 1, 0))

        AppLogger.shared.info(
            category: "transport",
            "Seek requested progress=\(String(format: "%.3f", clampedProgress)) frame=\(currentStartFrame)"
        )

        if state == .playing {
            if let localGaplessScheduler {
                do {
                    try rebuildLocalGaplessScheduleAfterSeek(using: localGaplessScheduler)
                } catch {
                    AppLogger.shared.error(category: LocalGaplessSchedulerLog.category, "Local gapless seek failed error=\(error.localizedDescription)")
                    cancelLocalGaplessScheduler(reason: "gapless seek failed")
                    scheduleFromCurrentPosition()
                    startPlayers()
                }
                localGaplessTrackStartPlayerSampleTime = 0
            } else {
                playerNodes.forEach { $0.stop() }
                scheduleFromCurrentPosition()
                startPlayers()
            }
        } else if state == .paused {
            if let localGaplessScheduler {
                do {
                    try rebuildLocalGaplessScheduleAfterSeek(using: localGaplessScheduler)
                } catch {
                    AppLogger.shared.error(category: LocalGaplessSchedulerLog.category, "Paused local gapless seek failed error=\(error.localizedDescription)")
                    cancelLocalGaplessScheduler(reason: "paused gapless seek failed")
                    markPausedPlaybackNeedsReschedule(reason: "seek while paused")
                }
                localGaplessTrackStartPlayerSampleTime = 0
            } else {
                playerNodes.forEach { $0.stop() }
                markPausedPlaybackNeedsReschedule(reason: "seek while paused")
            }
        }
    }

    private func rebuildLocalGaplessScheduleAfterSeek(using scheduler: LocalGaplessScheduler) throws {
        let queue = localGaplessQueueSnapshot?.tracks
            ?? localGaplessCurrentTrack.map { [$0] }
            ?? []
        guard !queue.isEmpty else {
            throw LocalGaplessSchedulerError.invalidQueue("cannot seek without a local gapless queue")
        }

        let preferredIndex = localGaplessCurrentTrack?.queueIndex
        let currentIndex: Int
        if let preferredIndex,
           queue.indices.contains(preferredIndex) {
            currentIndex = preferredIndex
        } else if let currentTrack = localGaplessCurrentTrack,
                  let matchedIndex = queue.firstIndex(where: { $0.id == currentTrack.id }) {
            currentIndex = matchedIndex
        } else if let snapshotIndex = localGaplessQueueSnapshot?.startIndex,
                  queue.indices.contains(snapshotIndex) {
            currentIndex = snapshotIndex
        } else {
            currentIndex = 0
        }

        try scheduler.rebuildQueue(
            queue: queue,
            currentIndex: currentIndex,
            seekFrame: currentStartFrame,
            preserveCurrentTrackStart: true
        )
    }

    func currentTime() -> TimeInterval {
        if liveInputSource != nil {
            return Date().timeIntervalSince(liveStartDate ?? Date())
        }

        if let streamingPlayback {
            guard streamingPlayback.descriptor.sourceSampleRate > 0 else { return 0 }
            return Double(playbackFrame()) / streamingPlayback.descriptor.sourceSampleRate
        }

        guard let loadedFile else { return 0 }
        return Double(playbackFrame()) / loadedFile.sampleRate
    }

    func duration() -> TimeInterval {
        if liveInputSource != nil {
            return 0
        }

        if let streamingPlayback {
            return streamingPlayback.durationSeconds
        }

        if localGaplessScheduler != nil,
           let loadedFile,
           let frameCount = localGaplessCurrentTrackFrameCount {
            guard loadedFile.sampleRate > 0 else { return 0 }
            return Double(frameCount) / loadedFile.sampleRate
        }

        return loadedFile?.duration ?? 0
    }

    func channelMeterLevels() -> [Float] {
        inputMeterLevels().map(\.displayLevel)
    }

    func inputMeterLevels() -> [MeterChannelLevel] {
        if let livePipe {
            return meteringService.levels(signal: .input, channelCount: livePipe.channelCount)
        }

        if let streamingPlayback {
            guard state == .playing || state == .paused else {
                meteringService.setInactive(signal: .input, channelCount: streamingPlayback.layout.channelCount)
                return meteringService.levels(signal: .input, channelCount: streamingPlayback.layout.channelCount)
            }
            ingestStreamingInputMeters(streamingPlayback)
            return meteringService.levels(signal: .input, channelCount: streamingPlayback.layout.channelCount)
        }

        if localGaplessScheduler != nil {
            let channelCount = max(loadedFile?.layout.channelCount ?? 1, 1)
            let sampleRate = loadedFile?.sampleRate ?? 48_000
            let sampleWindow = max(Int(sampleRate * 0.015), 512)
            guard let snapshot = localGaplessMeterSnapshot(sampleWindow: sampleWindow) else {
                meteringService.setInactive(signal: .input, channelCount: channelCount)
                return meteringService.levels(signal: .input, channelCount: channelCount)
            }
            meteringService.ingest(
                signal: .input,
                buffer: snapshot.buffer,
                startFrame: Int(snapshot.bufferFrameOffset),
                frameCount: Int(snapshot.frameCount)
            )
            return meteringService.levels(signal: .input, channelCount: channelCount)
        }

        guard let loadedFile else {
            return []
        }

        guard state == .playing || state == .paused else {
            meteringService.setInactive(signal: .input, channelCount: loadedFile.layout.channelCount)
            return meteringService.levels(signal: .input, channelCount: loadedFile.layout.channelCount)
        }

        let currentFrame = playbackFrame()
        let sampleWindow = max(Int(loadedFile.sampleRate * 0.015), 512)
        meteringService.ingest(
            signal: .input,
            buffers: loadedFile.monoBuffers,
            startFrame: Int(currentFrame),
            frameCount: sampleWindow
        )

        return meteringService.levels(signal: .input, channelCount: loadedFile.layout.channelCount)
    }

    func monitorMeterChannelCount() -> Int {
        guard audioGraphEnabled else { return 2 }
        let mixerCount = Int(preVolumeMixer.outputFormat(forBus: 0).channelCount)
        if mixerCount > 0 {
            return mixerCount
        }

        let outputCount = Int(engine.outputNode.inputFormat(forBus: 0).channelCount)
        return max(outputCount, 2)
    }

    func monitorMeterLevels() -> [Float] {
        monitorMeterChannelLevels().map(\.displayLevel)
    }

    func monitorMeterChannelLevels(channelCount: Int? = nil) -> [MeterChannelLevel] {
        meteringService.levels(signal: .monitor, channelCount: channelCount ?? monitorMeterChannelCount())
    }

    func sonicSphereMeterLevels(channelCount: Int) -> [MeterChannelLevel] {
        refreshSonicSphereMeterSnapshot(channelCount: channelCount)
        return meteringService.levels(signal: .sonicSphere, channelCount: channelCount)
    }

    func sonicSphereMeterIsActive() -> Bool {
        meteringService.isActive(signal: .sonicSphere)
    }

    func liveInputStatus() -> LiveAudioPipeStatus? {
        livePipe?.status()
    }

    func updateTuning(_ tuning: SpatialTuning) {
        self.tuning = tuning
        applyTuning(tuning)
        AppLogger.shared.info(
            category: "tuning",
            "Updated tuning preset=\(tuning.preset.rawValue) frontAngle=\(tuning.frontAngle) rearAngle=\(tuning.rearAngle)"
        )
    }

    private func configureGraph() {
        engine.attach(preVolumeMixer)
        engine.attach(outputGainMixer)
        configureStereoMonitorOutputGraph(sampleRate: preferredOutputSampleRate())
        engine.mainMixerNode.outputVolume = 1
        outputGainMixer.outputVolume = 0.92
        installMonitorMeterTap()
    }

    private func configureStereoMonitorOutputGraph(sampleRate: Double) {
        engine.disconnectNodeOutput(preVolumeMixer)
        engine.disconnectNodeOutput(outputGainMixer)
        let stereoFormat = stereoMonitorFormat(sampleRate: sampleRate)
        engine.connect(preVolumeMixer, to: outputGainMixer, format: stereoFormat)
        engine.connect(outputGainMixer, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    }

    private func configureRendererOutputGraph(format: AVAudioFormat) {
        engine.disconnectNodeOutput(preVolumeMixer)
        engine.disconnectNodeOutput(outputGainMixer)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(outputGainMixer, to: engine.outputNode, format: format)
    }

    private struct OutputDevicePlaybackSnapshot {
        let wasEngineRunning: Bool
        let transportState: TransportState
        let resumeFrame: AVAudioFramePosition
        let hadLiveInput: Bool
        let hadTestTone: Bool
    }

    @discardableResult
    private func restorePlayback(afterOutputDeviceChange snapshot: OutputDevicePlaybackSnapshot) throws -> Bool {
        guard snapshot.wasEngineRunning else { return false }

        if snapshot.transportState == .playing, let loadedFile {
            currentStartFrame = min(snapshot.resumeFrame, loadedFile.frameCount)
            scheduleFromCurrentPosition()
            if !engine.isRunning {
                try engine.start()
            }
            startPlayers()
            state = .playing
            AppLogger.shared.notice(category: "transport", "Resumed playback after output device change at frame=\(currentStartFrame).")
            return true
        }

        if snapshot.transportState == .paused, let loadedFile {
            currentStartFrame = min(snapshot.resumeFrame, loadedFile.frameCount)
            pausedPlaybackNeedsReschedule = true
            if !engine.isRunning {
                try engine.start()
            }
            state = .paused
            AppLogger.shared.notice(category: "transport", "Preserved paused playback after output device change at frame=\(currentStartFrame).")
            return true
        }

        if snapshot.hadLiveInput || snapshot.hadTestTone {
            if !engine.isRunning {
                try engine.start()
            }
            state = snapshot.transportState
            AppLogger.shared.notice(category: "engine", "Restarted AVAudioEngine after output device change.")
            return true
        }

        if !engine.isRunning {
            try engine.start()
        }
        return true
    }

    private func markPausedPlaybackNeedsReschedule(reason: String) {
        guard state == .paused else { return }
        pausedPlaybackNeedsReschedule = true
        AppLogger.shared.debug(category: "transport", "Paused playback will reschedule on resume. reason=\(reason) frame=\(currentStartFrame)")
    }

    private func startLocalGaplessPlaybackIfPossible(
        for loadedFile: LoadedAudioFile,
        debugTiming: DebugTimingContext?
    ) throws -> Bool {
        guard localGaplessConfig.isEnabled else { return false }
        guard let snapshot = localGaplessQueueSnapshot else {
            AppLogger.shared.debug(category: LocalGaplessSchedulerLog.category, "Prepared local fallback reason=\"missing queue snapshot\"")
            return false
        }
        guard let fallbackReason = localGaplessFallbackReason(snapshot: snapshot, loadedFile: loadedFile) else {
            guard let outputFormat = localGaplessOutputFormat(for: loadedFile) else {
                AppLogger.shared.info(
                    category: LocalGaplessSchedulerLog.category,
                    "Prepared local fallback reason=\"could not create gapless output format\" file=\(loadedFile.url.lastPathComponent)"
                )
                return false
            }

            let player = playerNodes[0]
            let token = UUID()
            completionToken = token
            localGaplessCurrentTrack = snapshot.currentTrack
            localGaplessCurrentTrackFrameCount = loadedFile.frameCount
            localGaplessTrackStartPlayerSampleTime = 0

            let expectedSampleRate = loadedFile.sampleRate
            let expectedChannelCount = loadedFile.layout.channelCount
            let schedulingPlayer = LocalGaplessMultiNodeSchedulingPlayer(
                players: playerNodes,
                monoFormat: loadedFile.monoFormat
            )
            let scheduler = LocalGaplessScheduler(
                playerNode: player,
                format: outputFormat,
                config: localGaplessConfig,
                schedulingPlayer: schedulingPlayer,
                sourceFactory: { track, outputFormat, config in
                    guard Self.localGaplessTrackIsCompatible(
                        track,
                        expectedSampleRate: expectedSampleRate,
                        expectedChannelCount: expectedChannelCount
                    ) else {
                        throw LocalGaplessSchedulerError.invalidQueue("incompatible local source for current gapless graph")
                    }
                    return try LocalAudioFileSource(track: track, outputFormat: outputFormat, config: config)
                }
            )
            scheduler.onEvent = { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleLocalGaplessSchedulerEvent(event, token: token)
                }
            }
            localGaplessScheduler = scheduler

            AppLogger.shared.notice(
                category: LocalGaplessSchedulerLog.category,
                LocalGaplessSchedulerLog.message(
                    .schedulerEnabled,
                    fileName: loadedFile.url.lastPathComponent,
                    reason: "queueCount=\(snapshot.tracks.count) startIndex=\(snapshot.startIndex)"
                )
            )
            debugTiming?.log(
                "gapless scheduler enabled",
                fileURL: loadedFile.url,
                extra: ["queueCount=\(snapshot.tracks.count)", "startIndex=\(snapshot.startIndex)"]
            )
            try scheduler.start(queue: snapshot.tracks, startIndex: snapshot.startIndex)
            return true
        }

        AppLogger.shared.info(
            category: LocalGaplessSchedulerLog.category,
            "Prepared local fallback reason=\"\(fallbackReason)\" file=\(loadedFile.url.lastPathComponent)"
        )
        debugTiming?.log("gapless scheduler fallback", fileURL: loadedFile.url, extra: ["reason=\"\(fallbackReason)\""])
        return false
    }

    private func localGaplessFallbackReason(
        snapshot: LocalGaplessEngineQueueSnapshot,
        loadedFile: LoadedAudioFile
    ) -> String? {
        guard snapshot.tracks.indices.contains(snapshot.startIndex) else {
            return "invalid queue start index"
        }
        guard let currentTrack = snapshot.currentTrack else {
            return "missing current queue item"
        }
        guard snapshot.nextTrack != nil else {
            return "missing next queue item"
        }
        guard currentTrack.url.isFileURL,
              snapshot.tracks[snapshot.startIndex + 1].url.isFileURL
        else {
            return "queue contains non-file URL"
        }
        guard currentTrack.url.standardizedFileURL.path == loadedFile.url.standardizedFileURL.path else {
            return "queue current item does not match loaded file"
        }
        guard streamingPlayback == nil,
              liveInputSource == nil,
              sourceNodes.isEmpty,
              testToneNodes.isEmpty
        else {
            return "another audio source is active"
        }
        guard playerNodes.count == loadedFile.layout.channelCount,
              !playerNodes.isEmpty
        else {
            return "normal monitor graph channel count does not match the local source"
        }
        guard localGaplessOutputFormat(for: loadedFile) != nil else {
            return "could not create gapless output format"
        }
        guard Self.localGaplessTrackIsCompatible(
            currentTrack,
            expectedSampleRate: loadedFile.sampleRate,
            expectedChannelCount: loadedFile.layout.channelCount
        ) else {
            return "current source cannot be reopened in the canonical local format"
        }
        guard let nextTrack = snapshot.nextTrack,
              Self.localGaplessTrackIsCompatible(
                nextTrack,
                expectedSampleRate: loadedFile.sampleRate,
                expectedChannelCount: loadedFile.layout.channelCount
              )
        else {
            return "next source is not compatible with the current local graph"
        }
        return nil
    }

    private func localGaplessOutputFormat(for loadedFile: LoadedAudioFile) -> AVAudioFormat? {
        let channelCount = loadedFile.layout.channelCount
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            return nil
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: loadedFile.sampleRate,
            interleaved: false,
            channelLayout: channelLayout
        )
    }

    @discardableResult
    func rebuildLocalGaplessQueue(
        _ snapshot: LocalGaplessEngineQueueSnapshot,
        reason: String
    ) -> Bool {
        guard localGaplessConfig.isEnabled,
              let scheduler = localGaplessScheduler,
              let loadedFile
        else { return false }

        if let rejectionReason = localGaplessQueueRebuildRejectionReason(
            snapshot: snapshot,
            loadedFile: loadedFile
        ) {
            AppLogger.shared.info(
                category: LocalGaplessSchedulerLog.category,
                "Local gapless queue rebuild rejected reason=\"\(reason)\" fallback=\"\(rejectionReason)\""
            )
            return false
        }

        let frame = playbackFrame()
        let currentTrack = snapshot.currentTrack ?? localGaplessCurrentTrack
        let currentFrameCount = currentTrack.flatMap { localGaplessFrameCount(for: $0) }
            ?? localGaplessCurrentTrackFrameCount
            ?? loadedFile.frameCount
        let seekFrame = min(max(frame, 0), max(currentFrameCount - 1, 0))

        do {
            localGaplessQueueSnapshot = snapshot
            localGaplessTrackFrameCounts = localGaplessFrameCounts(for: snapshot, loadedFile: loadedFile)
            localGaplessCurrentTrack = currentTrack
            localGaplessCurrentTrackFrameCount = currentFrameCount
            localGaplessTrackStartPlayerSampleTime = 0
            currentStartFrame = seekFrame
            try scheduler.rebuildQueue(
                queue: snapshot.tracks,
                currentIndex: snapshot.startIndex,
                seekFrame: seekFrame,
                preserveCurrentTrackStart: true
            )
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                "Rebuilt local gapless queue reason=\"\(reason)\" startIndex=\(snapshot.startIndex) frame=\(seekFrame) queueCount=\(snapshot.tracks.count)"
            )
            return true
        } catch {
            AppLogger.shared.error(
                category: LocalGaplessSchedulerLog.category,
                "Local gapless queue rebuild failed reason=\"\(reason)\" error=\(error.localizedDescription)"
            )
            cancelLocalGaplessScheduler(reason: "queue rebuild failed")
            return false
        }
    }

    private func localGaplessQueueRebuildRejectionReason(
        snapshot: LocalGaplessEngineQueueSnapshot,
        loadedFile: LoadedAudioFile
    ) -> String? {
        guard snapshot.tracks.indices.contains(snapshot.startIndex) else {
            return "invalid queue start index"
        }
        guard let currentTrack = localGaplessCurrentTrack else {
            return "missing current gapless track"
        }
        guard snapshot.tracks[snapshot.startIndex].id == currentTrack.id else {
            return "queue start item does not match current logical track"
        }
        guard playerNodes.count == loadedFile.layout.channelCount,
              !playerNodes.isEmpty
        else {
            return "normal monitor graph channel count does not match the local source"
        }
        guard localGaplessOutputFormat(for: loadedFile) != nil else {
            return "could not create gapless output format"
        }

        let tracksToSchedule = snapshot.tracks[snapshot.startIndex...]
        for track in tracksToSchedule {
            guard track.url.isFileURL else {
                return "queue contains non-file URL"
            }
            guard Self.localGaplessTrackIsCompatible(
                track,
                expectedSampleRate: loadedFile.sampleRate,
                expectedChannelCount: loadedFile.layout.channelCount
            ) else {
                return "queue item is not compatible with the current local graph"
            }
        }

        return nil
    }

    @MainActor
    private func handleLocalGaplessSchedulerEvent(
        _ event: LocalGaplessSchedulerEvent,
        token: UUID
    ) {
        guard completionToken == token,
              localGaplessScheduler != nil
        else {
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                LocalGaplessSchedulerLog.message(.generationInvalidated)
            )
            return
        }

        switch event {
        case .logicalTrackStarted(let track):
            localGaplessCurrentTrack = track
            localGaplessCurrentTrackFrameCount = localGaplessFrameCount(for: track)
            localGaplessTrackStartPlayerSampleTime = currentLocalGaplessPlayerSampleTime() ?? 0
            currentStartFrame = 0
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                "Logical local gapless track started file=\(track.url.lastPathComponent) queueIndex=\(track.queueIndex.map(String.init) ?? "-")"
            )
            onLocalGaplessLogicalTrackStarted?(track)
        case .logicalTrackEnded(let track):
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                "Logical local gapless track ended file=\(track.url.lastPathComponent) queueIndex=\(track.queueIndex.map(String.init) ?? "-")"
            )
            onLocalGaplessLogicalTrackEnded?(track)
        case .queueEnded:
            AppLogger.shared.notice(
                category: LocalGaplessSchedulerLog.category,
                LocalGaplessSchedulerLog.message(.queueExhausted, fileName: localGaplessCurrentTrack?.url.lastPathComponent)
            )
            finishLocalGaplessPlaybackNaturally(token: token)
        case .gaplessMiss(let track, let reason):
            AppLogger.shared.notice(
                category: LocalGaplessSchedulerLog.category,
                LocalGaplessSchedulerLog.message(.gaplessMiss, fileName: track?.url.lastPathComponent, reason: reason)
            )
        case .sourceFailed(let track, let message):
            AppLogger.shared.error(
                category: LocalGaplessSchedulerLog.category,
                LocalGaplessSchedulerLog.message(.sourceOpenFailed, fileName: track.url.lastPathComponent, reason: message)
            )
            finishLocalGaplessPlaybackNaturally(token: token)
        case .schedulerStopped(let reason):
            AppLogger.shared.debug(category: LocalGaplessSchedulerLog.category, "Local gapless scheduler stopped reason=\"\(reason)\"")
        }
    }

    private func finishLocalGaplessPlaybackNaturally(token: UUID) {
        guard completionToken == token,
              localGaplessScheduler != nil,
              state == .playing
        else { return }

        AppLogger.shared.debug(category: LocalGaplessSchedulerLog.category, "Local gapless playback finished naturally.")
        onLocalGaplessQueueEnded?()
        stop()
        onPlaybackEnded?()
    }

    private func cancelLocalGaplessScheduler(reason: String, clearQueue: Bool = true) {
        guard let scheduler = localGaplessScheduler else {
            if clearQueue {
                localGaplessQueueSnapshot = nil
                localGaplessTrackFrameCounts = [:]
                localGaplessCurrentTrack = nil
                localGaplessCurrentTrackFrameCount = nil
                localGaplessTrackStartPlayerSampleTime = 0
            }
            return
        }

        scheduler.onEvent = nil
        scheduler.stop(reason: reason)
        localGaplessScheduler = nil
        localGaplessCurrentTrack = nil
        localGaplessCurrentTrackFrameCount = nil
        localGaplessTrackStartPlayerSampleTime = 0
        if clearQueue {
            localGaplessQueueSnapshot = nil
            localGaplessTrackFrameCounts = [:]
        }
        AppLogger.shared.debug(category: LocalGaplessSchedulerLog.category, "Canceled local gapless scheduler reason=\"\(reason)\"")
    }

    private func currentLocalGaplessPlayerSampleTime() -> AVAudioFramePosition? {
        guard let player = playerNodes.first,
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else { return nil }
        return AVAudioFramePosition(playerTime.sampleTime)
    }

    private func localGaplessFrameCounts(
        for snapshot: LocalGaplessEngineQueueSnapshot?,
        loadedFile: LoadedAudioFile
    ) -> [String: AVAudioFramePosition] {
        guard let snapshot else { return [:] }
        var counts: [String: AVAudioFramePosition] = [:]
        let loadedPath = loadedFile.url.standardizedFileURL.path
        for track in snapshot.tracks {
            if track.url.standardizedFileURL.path == loadedPath {
                counts[track.id] = loadedFile.frameCount
            } else if let frameCount = Self.localGaplessFrameCount(for: track) {
                counts[track.id] = frameCount
            }
        }
        return counts
    }

    private func localGaplessFrameCount(for track: LocalGaplessTrackDescriptor) -> AVAudioFramePosition? {
        if let frameCount = localGaplessTrackFrameCounts[track.id] {
            return frameCount
        }
        guard let frameCount = Self.localGaplessFrameCount(for: track) else { return nil }
        localGaplessTrackFrameCounts[track.id] = frameCount
        return frameCount
    }

    private static func localGaplessFrameCount(for track: LocalGaplessTrackDescriptor) -> AVAudioFramePosition? {
        guard track.url.isFileURL,
              let file = try? AVAudioFile(forReading: track.url)
        else { return nil }
        return max(0, file.length)
    }

    private static func localGaplessTrackIsCompatible(
        _ track: LocalGaplessTrackDescriptor,
        expectedSampleRate: Double,
        expectedChannelCount: Int
    ) -> Bool {
        guard track.url.isFileURL,
              expectedSampleRate > 0,
              expectedChannelCount > 0,
              let file = try? AVAudioFile(forReading: track.url)
        else { return false }

        let format = file.processingFormat
        return abs(format.sampleRate - expectedSampleRate) < 0.5 &&
            Int(format.channelCount) == expectedChannelCount
    }

    private func rebuildStreamingPlaybackGraph(
        for context: StreamingPlaybackContext,
        debugTiming: DebugTimingContext? = nil
    ) {
        let graphStart = DispatchTime.now().uptimeNanoseconds
#if DEBUG
        debugPlaybackGraphBuildCount += 1
#endif
        debugTiming?.log("streaming graph rebuild start", fileURL: context.descriptor.url)
        detachPlayerNodes()
        meteringService.setInactive(signal: .sonicSphere, channelCount: rendererScene.matrix.outputCount)

        if let rendererFormat = rendererOutputFormat(
            sourceSampleRate: context.descriptor.sourceSampleRate,
            sourceChannelCount: context.layout.channelCount
        ) {
            configureRendererOutputGraph(format: rendererFormat)
            let player = AVAudioPlayerNode()
            playerNodes = [player]
            engine.attach(player)
            engine.connect(player, to: outputGainMixer, format: rendererFormat)

            AppLogger.shared.info(
                category: "streaming",
                "Rebuilt streaming renderer graph sourceChannels=\(context.layout.channelCount) logicalOutputs=\(rendererScene.matrix.outputCount) physicalOutputs=\(Int(rendererFormat.channelCount))."
            )
            debugTiming?.log(
                "streaming graph rebuild end",
                fileURL: context.descriptor.url,
                extra: [
                    "graphMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - graphStart) / 1_000_000.0))",
                    "path=\"sonic-sphere-renderer\"",
                    "sourceChannels=\(context.layout.channelCount)",
                    "logicalOutputs=\(rendererScene.matrix.outputCount)",
                    "physicalOutputs=\(Int(rendererFormat.channelCount))",
                    "playerNodes=\(playerNodes.count)"
                ]
            )
            return
        }

        configureStereoMonitorOutputGraph(sampleRate: context.descriptor.sourceSampleRate)
        playerNodes = context.layout.channels.map { _ in AVAudioPlayerNode() }
        for (channel, player) in zip(context.layout.channels, playerNodes) {
            engine.attach(player)
            engine.connect(player, to: preVolumeMixer, format: context.monoFormat)
            configureNormalMonitorNode(player, for: channel, sourceChannelCount: context.layout.channelCount)
        }

        AppLogger.shared.info(
            category: "streaming",
            "Rebuilt streaming player graph with \(playerNodes.count) mono sources through Normal Monitor."
        )
        debugTiming?.log(
            "streaming graph rebuild end",
            fileURL: context.descriptor.url,
            extra: [
                "graphMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - graphStart) / 1_000_000.0))",
                "playerNodes=\(playerNodes.count)"
            ]
        )
    }

    private func scheduleStreamingPreroll(
        for context: StreamingPlaybackContext,
        debugTiming: DebugTimingContext?
    ) async throws {
        let targetFrames = AVAudioFramePosition(StreamingLocalPlaybackPolicy.initialPrerollFrames)
        while context.scheduledFrames < targetFrames {
            try Task.checkCancellation()
            guard streamingPlayback?.token == context.token else {
                throw CancellationError()
            }
            guard let chunk = try await context.source.nextChunk() else {
                context.reachedEndOfSource = true
                break
            }
            try scheduleStreamingChunk(chunk, for: context, debugTiming: debugTiming)
        }

        guard context.scheduledFrames > 0 else {
            throw StreamingAudioFileSourceError.sourceClosed
        }
    }

    private func ingestStreamingInputMeters(_ context: StreamingPlaybackContext) {
        let currentFrame = playbackFrame()
        guard let chunk = context.scheduledChunks.values.first(where: { scheduledChunk in
            let start = scheduledChunk.startFrame
            let end = start + AVAudioFramePosition(scheduledChunk.frameCount)
            return currentFrame >= start && currentFrame < end
        }) else {
            return
        }

        let frameOffset = max(0, Int(currentFrame - chunk.startFrame))
        let framesAvailable = max(Int(chunk.frameCount) - frameOffset, 0)
        let sampleWindow = max(Int(context.descriptor.sourceSampleRate * 0.015), 512)
        let frameCount = min(sampleWindow, framesAvailable)
        guard frameCount > 0 else {
            return
        }

        meteringService.ingest(
            signal: .input,
            buffers: chunk.monoBuffers,
            startFrame: frameOffset,
            frameCount: frameCount
        )
    }

    private func refreshSonicSphereMeterSnapshot(channelCount: Int) {
        guard channelCount > 0 else { return }

        let matrix = rendererScene.matrix
        guard matrix.inputCount > 0, matrix.outputCount > 0 else {
            meteringService.setInactive(signal: .sonicSphere, channelCount: channelCount)
            return
        }

        if let livePipe {
            let sampleWindow = max(Int(livePipe.sampleRate * 0.015), 512)
            guard livePipe.renderMeterSnapshot(matrix: matrix, frameCount: sampleWindow) else {
                meteringService.setInactive(signal: .sonicSphere, channelCount: channelCount)
                return
            }
            return
        }

        guard state == .playing || state == .paused else {
            meteringService.setInactive(signal: .sonicSphere, channelCount: channelCount)
            return
        }

        if let streamingPlayback {
            ingestStreamingSonicSphereMeters(streamingPlayback, channelCount: channelCount)
            return
        }

        if localGaplessScheduler != nil {
            let sampleRate = loadedFile?.sampleRate ?? 48_000
            let sampleWindow = max(Int(sampleRate * 0.015), 512)
            guard let snapshot = localGaplessMeterSnapshot(sampleWindow: sampleWindow) else {
                meteringService.setInactive(signal: .sonicSphere, channelCount: channelCount)
                return
            }
            let rendered = RendererMatrixSampleRenderer.renderSampleBuffers(
                matrix: matrix,
                sourceBuffer: snapshot.buffer,
                startFrame: Int(snapshot.bufferFrameOffset),
                frameCount: Int(snapshot.frameCount)
            )
            ingestRenderedSonicSphereMeters(rendered, channelCount: channelCount)
            return
        }

        guard let loadedFile else {
            meteringService.setInactive(signal: .sonicSphere, channelCount: channelCount)
            return
        }

        let sampleWindow = max(Int(loadedFile.sampleRate * 0.015), 512)
        let rendered = RendererMatrixSampleRenderer.renderSampleBuffers(
            matrix: matrix,
            sourceBuffers: loadedFile.monoBuffers,
            startFrame: Int(playbackFrame()),
            frameCount: sampleWindow
        )
        ingestRenderedSonicSphereMeters(rendered, channelCount: channelCount)
    }

    private func localGaplessMeterSnapshot(sampleWindow: Int) -> LocalGaplessMeterSnapshot? {
        guard let localGaplessScheduler else { return nil }
        return localGaplessScheduler.meteringSnapshot(
            trackID: localGaplessCurrentTrack?.id,
            frame: playbackFrame(),
            frameCount: AVAudioFrameCount(max(sampleWindow, 0))
        )
    }

    private func ingestStreamingSonicSphereMeters(_ context: StreamingPlaybackContext, channelCount: Int) {
        let currentFrame = playbackFrame()
        guard let chunk = context.scheduledChunks.values.first(where: { scheduledChunk in
            let start = scheduledChunk.startFrame
            let end = start + AVAudioFramePosition(scheduledChunk.frameCount)
            return currentFrame >= start && currentFrame < end
        }) else {
            return
        }

        let frameOffset = max(0, Int(currentFrame - chunk.startFrame))
        let framesAvailable = max(Int(chunk.frameCount) - frameOffset, 0)
        let sampleWindow = max(Int(context.descriptor.sourceSampleRate * 0.015), 512)
        let frameCount = min(sampleWindow, framesAvailable)
        guard frameCount > 0 else {
            return
        }

        let rendered = RendererMatrixSampleRenderer.renderSampleBuffers(
            matrix: rendererScene.matrix,
            sourceBuffers: chunk.monoBuffers,
            startFrame: frameOffset,
            frameCount: frameCount
        )
        ingestRenderedSonicSphereMeters(rendered, channelCount: channelCount)
    }

    private func ingestRenderedSonicSphereMeters(
        _ rendered: (sampleBuffers: [[Float]], frameCount: Int),
        channelCount: Int
    ) {
        guard rendered.frameCount > 0, !rendered.sampleBuffers.isEmpty else {
            meteringService.setInactive(signal: .sonicSphere, channelCount: channelCount)
            return
        }

        meteringService.ingest(
            signal: .sonicSphere,
            sampleBuffers: rendered.sampleBuffers,
            frameCount: rendered.frameCount
        )
    }

    private func startStreamingScheduleTask(
        for context: StreamingPlaybackContext,
        debugTiming: DebugTimingContext?
    ) {
        context.scheduleTask?.cancel()
        context.scheduleTask = Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            do {
                while !Task.isCancelled {
                    guard self.streamingPlayback?.token == context.token else { return }
                    if context.reachedEndOfSource {
                        if context.scheduledFrames == 0 {
                            self.finishStreamingPlaybackNaturally(token: context.token)
                        }
                        return
                    }

                    if self.streamingScheduleIsFull(context) {
                        try await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }

                    guard let chunk = try await context.source.nextChunk() else {
                        context.reachedEndOfSource = true
                        if context.scheduledFrames == 0 {
                            self.finishStreamingPlaybackNaturally(token: context.token)
                            return
                        }
                        continue
                    }

                    try self.scheduleStreamingChunk(chunk, for: context, debugTiming: debugTiming)
                }
            } catch is CancellationError {
                AppLogger.shared.info(category: "streaming", "Streaming scheduler canceled file=\(context.descriptor.url.lastPathComponent)")
                debugTiming?.log("streaming scheduler canceled", fileURL: context.descriptor.url)
            } catch {
                guard self.streamingPlayback?.token == context.token else { return }
                AppLogger.shared.error(category: "streaming", "Streaming scheduler failed file=\(context.descriptor.url.lastPathComponent) error=\(error.localizedDescription)")
                debugTiming?.log(
                    "streaming scheduler failed",
                    fileURL: context.descriptor.url,
                    extra: ["error=\"\(error.localizedDescription)\""]
                )
                self.stop()
            }
        }
    }

    private func streamingScheduleIsFull(_ context: StreamingPlaybackContext) -> Bool {
        let byteCapReached = context.scheduledBytes >= Self.maxStreamingScheduledPCMBytes
        let frameCap = AVAudioFramePosition(
            max(context.descriptor.sourceSampleRate * Self.maxStreamingScheduledAheadSeconds, 0)
                .rounded(.up)
        )
        let frameCapReached = frameCap > 0 && context.scheduledFrames >= frameCap
        return byteCapReached || frameCapReached
    }

    private func scheduleStreamingChunk(
        _ chunk: PCMChunk,
        for context: StreamingPlaybackContext,
        debugTiming: DebugTimingContext?
    ) throws {
        guard streamingPlayback?.token == context.token else {
            chunk.recycleBuffer()
            throw CancellationError()
        }

        let scheduledChunk = try makeScheduledStreamingChunk(from: chunk, context: context)
        chunk.recycleBuffer()
        guard context.scheduledBytes + scheduledChunk.byteCount <= Self.maxStreamingScheduledPCMBytes else {
            scheduledChunk.monoBuffers.forEach { context.monoBufferPool.recycle($0) }
            throw StreamingAudioFileSourceError.chunkExceedsQueueLimit(
                chunkBytes: scheduledChunk.byteCount,
                maxBytes: Self.maxStreamingScheduledPCMBytes
            )
        }

        context.scheduledChunks[scheduledChunk.id] = scheduledChunk
        context.scheduledFrames += AVAudioFramePosition(scheduledChunk.frameCount)
        context.scheduledBytes += scheduledChunk.byteCount
        context.scheduledChunkCount += 1
#if DEBUG
        debugScheduleFromCurrentPositionCount += 1
#endif

        if let renderedOutputBuffer = scheduledChunk.renderedOutputBuffer,
           let player = playerNodes.first {
            let token = context.token
            let chunkID = scheduledChunk.id
            player.scheduleBuffer(renderedOutputBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.streamingChunkDidFinish(chunkID: chunkID, token: token)
                }
            }
        } else {
            for (index, player) in playerNodes.enumerated() {
                let buffer = scheduledChunk.monoBuffers[index]
                if index == 0 {
                    let token = context.token
                    let chunkID = scheduledChunk.id
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.streamingChunkDidFinish(chunkID: chunkID, token: token)
                        }
                    }
                } else {
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack)
                }
            }
        }

        if context.scheduledChunkCount == 1 || context.scheduledChunkCount.isMultiple(of: 16) {
            AppLogger.shared.debug(
                category: "streaming",
                "Scheduled streaming chunk file=\(context.descriptor.url.lastPathComponent) startFrame=\(scheduledChunk.startFrame) frames=\(scheduledChunk.frameCount) currentBytes=\(context.scheduledBytes) capBytes=\(Self.maxStreamingScheduledPCMBytes)"
            )
            debugTiming?.log(
                context.scheduledChunkCount == 1 ? "first chunk playback scheduled" : "streaming schedule buffer usage",
                fileURL: context.descriptor.url,
                extra: [
                    "startFrame=\(scheduledChunk.startFrame)",
                    "frameCount=\(scheduledChunk.frameCount)",
                    "chunkBytes=\(scheduledChunk.byteCount)",
                    "scheduledFrames=\(context.scheduledFrames)",
                    "currentBytes=\(context.scheduledBytes)",
                    "capBytes=\(Self.maxStreamingScheduledPCMBytes)"
                ]
            )
        }
    }

    private func makeScheduledStreamingChunk(
        from chunk: PCMChunk,
        context: StreamingPlaybackContext
    ) throws -> StreamingScheduledChunk {
        guard let channelData = chunk.buffer.floatChannelData else {
            throw AudioFileLoaderError.formatConversionFailed("missing streaming chunk float channel data")
        }

        let frameCount = chunk.frameCount
        let sourceChannelCount = Int(chunk.buffer.format.channelCount)
        var monoBuffers: [AVAudioPCMBuffer] = []
        monoBuffers.reserveCapacity(context.layout.channelCount)

        for channelIndex in 0..<context.layout.channelCount {
            guard let monoBuffer = context.monoBufferPool.checkout(frameCapacity: frameCount),
                  let monoData = monoBuffer.floatChannelData
            else {
                throw AudioFileLoaderError.monoBufferAllocationFailed
            }

            monoBuffer.frameLength = frameCount
            let destination = monoData[0]
            if channelIndex < sourceChannelCount {
                destination.update(from: channelData[channelIndex], count: Int(frameCount))
            } else {
                destination.initialize(repeating: 0, count: Int(frameCount))
            }
            monoBuffers.append(monoBuffer)
        }

        let renderedBuffer: AVAudioPCMBuffer?
        if playerNodes.count == 1 {
            renderedBuffer = renderedOutputBuffer(
                sourceBuffers: monoBuffers,
                sourceSampleRate: chunk.buffer.format.sampleRate,
                sourceChannelCount: context.layout.channelCount,
                startFrame: 0,
                frameCount: Int(frameCount)
            )
        } else {
            renderedBuffer = nil
        }

        return StreamingScheduledChunk(
            startFrame: chunk.startFrame,
            frameCount: frameCount,
            monoBuffers: monoBuffers,
            renderedOutputBuffer: renderedBuffer
        )
    }

    private func streamingChunkDidFinish(chunkID: UUID, token: UUID) {
        guard let context = streamingPlayback,
              context.token == token,
              let chunk = context.scheduledChunks.removeValue(forKey: chunkID)
        else {
            AppLogger.shared.debug(category: "streaming", "Ignored stale streaming chunk completion.")
            return
        }

        context.scheduledFrames = max(context.scheduledFrames - AVAudioFramePosition(chunk.frameCount), 0)
        context.scheduledBytes = max(context.scheduledBytes - chunk.byteCount, 0)
        chunk.monoBuffers.forEach { context.monoBufferPool.recycle($0) }

        AppLogger.shared.debug(
            category: "streaming",
            "Streaming chunk consumed file=\(context.descriptor.url.lastPathComponent) chunkFrames=\(chunk.frameCount) scheduledBytes=\(context.scheduledBytes)"
        )

        if context.reachedEndOfSource && context.scheduledFrames == 0 {
            finishStreamingPlaybackNaturally(token: token)
        }
    }

    private func finishStreamingPlaybackNaturally(token: UUID) {
        guard let context = streamingPlayback,
              context.token == token,
              state == .playing
        else { return }

        AppLogger.shared.notice(category: "streaming", "Streaming playback finished naturally file=\(context.descriptor.url.lastPathComponent)")
        stop()
        onPlaybackEnded?()
    }

    private func playStreaming(
        _ context: StreamingPlaybackContext,
        debugTiming: DebugTimingContext?
    ) throws {
        guard audioGraphEnabled else {
            switch state {
            case .paused, .idle, .ready:
                state = .playing
                pausedPlaybackNeedsReschedule = false
                AppLogger.shared.notice(category: "streaming", "Started streaming playback without CoreAudio graph.")
            case .playing:
                AppLogger.shared.debug(category: "streaming", "Streaming play requested while already playing.")
            }
            return
        }

        if !engine.isRunning {
            try engine.start()
            AppLogger.shared.notice(category: "engine", "AVAudioEngine started for streaming playback.")
        }

        switch state {
        case .paused:
            startPlayers()
            pausedPlaybackNeedsReschedule = false
            state = .playing
            AppLogger.shared.notice(category: "streaming", "Resumed streaming playback at \(formatTime(currentTime())) / \(context.metadata.durationText).")
        case .playing:
            AppLogger.shared.debug(category: "streaming", "Streaming play requested while already playing.")
        case .idle, .ready:
            startPlayers()
            state = .playing
            startStreamingScheduleTask(for: context, debugTiming: debugTiming)
            AppLogger.shared.notice(category: "streaming", "Started streaming playback from ready state.")
        }
    }

    private func cancelStreamingPlayback(reason: String) {
        guard let context = streamingPlayback else { return }

        context.scheduleTask?.cancel()
        context.scheduleTask = nil
        context.source.cancel()
        Task {
            await context.source.clearBufferedChunks()
        }
        context.scheduledChunks.values.forEach { chunk in
            chunk.monoBuffers.forEach { context.monoBufferPool.recycle($0) }
        }
        context.scheduledChunks.removeAll()
        context.scheduledFrames = 0
        context.scheduledBytes = 0
        streamingPlayback = nil
        AppLogger.shared.info(category: "streaming", "Canceled streaming playback file=\(context.descriptor.url.lastPathComponent) reason=\(reason)")
    }

    private static func streamingMetadata(for descriptor: AudioAssetDescriptor) -> AudioSourceMetadata {
        let layoutSource = "Streaming asset descriptor channel layout"
        return AudioSourceMetadata(
            fileName: descriptor.url.lastPathComponent,
            containerName: descriptor.containerDescription ?? descriptor.url.pathExtension.trimmedNilIfBlank?.uppercased() ?? "Unknown",
            codecName: descriptor.codecDescription ?? "Unknown",
            layoutName: descriptor.channelLayout.name,
            channelSummary: descriptor.channelLayout.channelSummary,
            channelCount: descriptor.channelCount,
            sampleRate: descriptor.sourceSampleRate,
            bitDepth: 32,
            duration: descriptor.durationSeconds ?? 0,
            formatNote: "Streaming local playback; decoded in bounded chunks.",
            channelLayoutConfidence: AudioSourceMetadata.fallbackLayoutConfidence(for: descriptor.channelCount),
            channelLayoutSourceDescription: layoutSource,
            channelLayoutWarnings: AudioSourceMetadata.fallbackLayoutWarnings(
                channelCount: descriptor.channelCount,
                channelSummary: descriptor.channelLayout.channelSummary,
                sourceDescription: layoutSource
            )
        )
    }

    private func rebuildPlaybackGraph(for loadedFile: LoadedAudioFile, debugTiming: DebugTimingContext? = nil) {
        let graphStart = DispatchTime.now().uptimeNanoseconds
#if DEBUG
        debugPlaybackGraphBuildCount += 1
#endif
        debugTiming?.log("replace current source graph rebuild start", fileURL: loadedFile.url)
        detachPlayerNodes()

        meteringService.setInactive(signal: .sonicSphere, channelCount: rendererScene.matrix.outputCount)

        if let rendererFormat = rendererOutputFormat(
            sourceSampleRate: loadedFile.sampleRate,
            sourceChannelCount: loadedFile.layout.channelCount
        ) {
            configureRendererOutputGraph(format: rendererFormat)
            let player = AVAudioPlayerNode()
            playerNodes = [player]
            engine.attach(player)
            engine.connect(player, to: outputGainMixer, format: rendererFormat)

            AppLogger.shared.info(
                category: "engine",
                "Rebuilt player graph with Sonic Sphere renderer output sourceChannels=\(loadedFile.layout.channelCount) logicalOutputs=\(rendererScene.matrix.outputCount) physicalOutputs=\(Int(rendererFormat.channelCount))."
            )
            debugTiming?.log(
                "replace current source graph rebuild end",
                fileURL: loadedFile.url,
                extra: [
                    "graphMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - graphStart) / 1_000_000.0))",
                    "path=\"sonic-sphere-renderer\"",
                    "sourceChannels=\(loadedFile.layout.channelCount)",
                    "logicalOutputs=\(rendererScene.matrix.outputCount)",
                    "physicalOutputs=\(Int(rendererFormat.channelCount))",
                    "playerNodes=\(playerNodes.count)"
                ]
            )
            return
        }

        configureStereoMonitorOutputGraph(sampleRate: loadedFile.sampleRate)
        let player = AVAudioPlayerNode()
        playerNodes = [player]
        engine.attach(player)
        engine.connect(player, to: preVolumeMixer, format: loadedFile.monitorFormat)

        AppLogger.shared.info(
            category: "engine",
            "Rebuilt player graph with one reference stereo monitor source."
        )
        debugTiming?.log(
            "replace current source graph rebuild end",
            fileURL: loadedFile.url,
            extra: [
                "graphMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - graphStart) / 1_000_000.0))",
                "path=\"reference-stereo-monitor\"",
                "playerNodes=\(playerNodes.count)"
            ]
        )
    }

    private func applyTuning(_ tuning: SpatialTuning) {
        if let loadedFile,
           playerNodes.count == loadedFile.layout.channelCount {
            for (channel, player) in zip(loadedFile.layout.channels, playerNodes) {
                configureNormalMonitorNode(player, for: channel, sourceChannelCount: loadedFile.layout.channelCount)
            }
        }

        if let streamingPlayback {
            for (channel, player) in zip(streamingPlayback.layout.channels, playerNodes) {
                configureNormalMonitorNode(player, for: channel, sourceChannelCount: streamingPlayback.layout.channelCount)
            }
        }

        if let liveInputSource {
            for (channel, sourceNode) in zip(liveInputSource.layout.channels, sourceNodes) {
                configureNormalMonitorNode(sourceNode, for: channel, sourceChannelCount: liveInputSource.layout.channelCount)
            }
        }
    }

    private func configureNormalMonitorNode(
        _ node: AVAudioMixing,
        for channel: SurroundChannel,
        sourceChannelCount: Int
    ) {
        node.volume = NormalMonitorDownmixPolicy.gain(for: channel.role, sourceChannelCount: sourceChannelCount)
        node.destination(forMixer: preVolumeMixer, bus: 0)?.pan = NormalMonitorDownmixPolicy.pan(
            for: channel.role,
            sourceChannelCount: sourceChannelCount
        )
    }

    private func scheduleFromCurrentPosition(debugTiming: DebugTimingContext? = nil) {
        guard let loadedFile else { return }
        let scheduleStart = DispatchTime.now().uptimeNanoseconds
#if DEBUG
        debugScheduleFromCurrentPositionCount += 1
#endif
        debugTiming?.log(
            "schedule buffer start",
            fileURL: loadedFile.url,
            extra: ["startFrame=\(currentStartFrame)", "channels=\(playerNodes.count)"]
        )
        completionToken = UUID()

        AppLogger.shared.debug(
            category: "transport",
            "Scheduling reference stereo monitor stream from frame=\(currentStartFrame)"
        )

        guard let player = playerNodes.first else { return }
        player.stop()
        let scheduledBuffer = renderedOutputBuffer(
            sourceBuffers: loadedFile.monoBuffers,
            sourceSampleRate: loadedFile.sampleRate,
            sourceChannelCount: loadedFile.layout.channelCount,
            startFrame: Int(currentStartFrame),
            frameCount: Int(max(loadedFile.frameCount - currentStartFrame, 0))
        ) ?? Self.slice(buffer: loadedFile.monitorBuffer, fromFrame: currentStartFrame)

        let token = completionToken
        player.scheduleBuffer(scheduledBuffer, at: nil, options: []) { [token] in
            Task { @MainActor [weak self] in
                guard let self, self.completionToken == token else { return }
                guard self.state == .playing else {
                    AppLogger.shared.debug(
                        category: "transport",
                        "Ignored playback completion while state=\(self.state.rawValue)."
                    )
                    return
                }
                AppLogger.shared.notice(category: "transport", "Playback finished naturally.")
                self.stop()
                self.onPlaybackEnded?()
            }
        }
        pausedPlaybackNeedsReschedule = false
        debugTiming?.log(
            "schedule buffer end",
            fileURL: loadedFile.url,
            extra: [
                "scheduleMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - scheduleStart) / 1_000_000.0))",
                "channels=\(playerNodes.count)"
            ]
        )
    }

    private func startPlayers() {
        let hostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.03)
        let startTime = AVAudioTime(hostTime: hostTime)
        playerNodes.forEach { $0.play(at: startTime) }
    }

    private func preferredOutputSampleRate() -> Double {
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        if outputFormat.sampleRate > 0 {
            return outputFormat.sampleRate
        }

        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        return mixerFormat.sampleRate > 0 ? mixerFormat.sampleRate : 48_000
    }

    private func stereoMonitorFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 48_000, channels: 2)
    }

    private func rendererOutputFormat(
        sourceSampleRate: Double,
        sourceChannelCount: Int
    ) -> AVAudioFormat? {
        guard rendererScene.matrix.inputCount == sourceChannelCount,
              rendererScene.matrix.outputCount > 2
        else { return nil }

        let logicalOutputCount = rendererScene.matrix.outputCount
        let hardwareChannelCount = Int(engine.outputNode.inputFormat(forBus: 0).channelCount)
        let physicalOutputCount = max(logicalOutputCount, hardwareChannelCount)
        guard physicalOutputCount > 2 else { return nil }

        let sampleRate = sourceSampleRate > 0 ? sourceSampleRate : preferredOutputSampleRate()
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(physicalOutputCount))
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
    }

    private func renderedOutputBuffer(
        sourceBuffers: [AVAudioPCMBuffer],
        sourceSampleRate: Double,
        sourceChannelCount: Int,
        startFrame: Int,
        frameCount: Int
    ) -> AVAudioPCMBuffer? {
        guard let format = rendererOutputFormat(
            sourceSampleRate: sourceSampleRate,
            sourceChannelCount: sourceChannelCount
        ) else { return nil }
        return renderedOutputBuffer(
            sourceBuffers: sourceBuffers,
            startFrame: startFrame,
            frameCount: frameCount,
            format: format
        )
    }

    private func renderedOutputBuffer(
        sourceBuffers: [AVAudioPCMBuffer],
        startFrame: Int,
        frameCount: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let outputData = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channelIndex in 0..<Int(format.channelCount) {
            outputData[channelIndex].initialize(repeating: 0, count: frameCount)
        }

        let rendered = RendererMatrixSampleRenderer.renderSampleBuffers(
            matrix: rendererScene.matrix,
            sourceBuffers: sourceBuffers,
            startFrame: startFrame,
            frameCount: frameCount
        )
        guard rendered.frameCount > 0 else { return nil }

        for channelIndex in 0..<min(rendered.sampleBuffers.count, Int(format.channelCount)) {
            rendered.sampleBuffers[channelIndex].withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                outputData[channelIndex].update(from: base, count: rendered.frameCount)
            }
        }
        buffer.frameLength = AVAudioFrameCount(rendered.frameCount)
        return buffer
    }

    private func makeToneNode(
        frequency: Double,
        sampleRate: Double,
        gain: Float
    ) -> AVAudioSourceNode {
        let tone = SineToneState(frequency: frequency, sampleRate: sampleRate, gain: gain)

        return AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            for frame in 0..<frames {
                let sample = tone.nextSample()

                for buffer in buffers {
                    guard let rawData = buffer.mData else { continue }
                    rawData.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }

            return noErr
        }
    }

    private func playDiagnosticMonitorTone(
        frequency: Double,
        sampleRate: Double,
        gain: Float
    ) throws {
        guard diagnosticMonitorOutputDeviceID != nil else {
            throw OutputDeviceSelectionError.diagnosticMonitorOutputUnavailable
        }
        stopDiagnosticMonitorTone()

        let node = makeToneNode(frequency: frequency, sampleRate: sampleRate, gain: gain)
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw LiveInputError.monoFormatCreationFailed(sampleRate)
        }

        diagnosticMonitorEngine.attach(node)
        diagnosticMonitorEngine.connect(node, to: diagnosticMonitorEngine.mainMixerNode, format: stereoFormat)
        diagnosticMonitorToneNodes = [node]

        if !diagnosticMonitorEngine.isRunning {
            try diagnosticMonitorEngine.start()
            AppLogger.shared.notice(category: "engine", "Diagnostic monitor engine started.")
        }
    }

    private func playDiagnosticMonitorVoice(
        clip: DiagnosticSpeechClip,
        sampleRate: Double
    ) throws {
        guard diagnosticMonitorOutputDeviceID != nil else {
            throw OutputDeviceSelectionError.diagnosticMonitorOutputUnavailable
        }
        stopDiagnosticMonitorTone()

        let node = makeMonitorVoiceNode(clip: clip, outputSampleRate: sampleRate)
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw LiveInputError.monoFormatCreationFailed(sampleRate)
        }

        diagnosticMonitorEngine.attach(node)
        diagnosticMonitorEngine.connect(node, to: diagnosticMonitorEngine.mainMixerNode, format: stereoFormat)
        diagnosticMonitorToneNodes = [node]

        if !diagnosticMonitorEngine.isRunning {
            try diagnosticMonitorEngine.start()
            AppLogger.shared.notice(category: "engine", "Diagnostic monitor speech engine started.")
        }
    }

    private func makeChannelToneNode(
        channelIndex: Int,
        frequency: Double,
        sampleRate: Double,
        gain: Float
    ) -> AVAudioSourceNode {
        let tone = SineToneState(frequency: frequency, sampleRate: sampleRate, gain: gain)

        return AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            for frame in 0..<frames {
                let sample = tone.nextSample()

                for (bufferIndex, buffer) in buffers.enumerated() {
                    guard let rawData = buffer.mData else { continue }
                    rawData.assumingMemoryBound(to: Float.self)[frame] = bufferIndex == channelIndex ? sample : 0
                }
            }

            return noErr
        }
    }

    private func makeMonitorVoiceNode(
        clip: DiagnosticSpeechClip,
        outputSampleRate: Double
    ) -> AVAudioSourceNode {
        let playhead = DiagnosticSpeechPlayhead(
            clip: clip,
            targetSampleRate: outputSampleRate,
            gain: 0.50
        )

        return AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            for frame in 0..<frames {
                let sample = playhead.nextSample()

                for buffer in buffers {
                    guard let rawData = buffer.mData else { continue }
                    rawData.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }

            return noErr
        }
    }

    private func makeChannelVoiceNode(
        clip: DiagnosticSpeechClip,
        channelIndex: Int,
        outputSampleRate: Double
    ) -> AVAudioSourceNode {
        let playhead = DiagnosticSpeechPlayhead(
            clip: clip,
            targetSampleRate: outputSampleRate,
            gain: 0.72
        )

        return AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            for frame in 0..<frames {
                let sample = playhead.nextSample()

                for (bufferIndex, buffer) in buffers.enumerated() {
                    guard let rawData = buffer.mData else { continue }
                    rawData.assumingMemoryBound(to: Float.self)[frame] = bufferIndex == channelIndex ? sample : 0
                }
            }

            return noErr
        }
    }

    private func playbackFrame() -> AVAudioFramePosition {
        if let streamingPlayback {
            if state == .playing,
               let renderTime = playerNodes.first?.lastRenderTime,
               let playerTime = playerNodes.first?.playerTime(forNodeTime: renderTime) {
                let frame = currentStartFrame + AVAudioFramePosition(playerTime.sampleTime)
                if streamingPlayback.durationFrames > 0 {
                    return min(max(frame, 0), streamingPlayback.durationFrames)
                }
                return max(frame, 0)
            }

            if streamingPlayback.durationFrames > 0 {
                return min(currentStartFrame, streamingPlayback.durationFrames)
            }
            return max(currentStartFrame, 0)
        }

        guard let loadedFile else { return 0 }

        if localGaplessScheduler != nil {
            let currentFrameCount = localGaplessCurrentTrackFrameCount ?? loadedFile.frameCount
            if state == .playing,
               let playerSampleTime = currentLocalGaplessPlayerSampleTime() {
                let playedFrames = max(playerSampleTime - localGaplessTrackStartPlayerSampleTime, 0)
                let frame = currentStartFrame + playedFrames
                return min(max(frame, 0), currentFrameCount)
            }
            return min(currentStartFrame, currentFrameCount)
        }

        if state == .playing,
           let renderTime = playerNodes.first?.lastRenderTime,
           let playerTime = playerNodes.first?.playerTime(forNodeTime: renderTime) {
            let frame = currentStartFrame + AVAudioFramePosition(playerTime.sampleTime)
            return min(max(frame, 0), loadedFile.frameCount)
        }

        return min(currentStartFrame, loadedFile.frameCount)
    }

    private func stopLiveInput() {
        let hadLiveInput = liveInputSource != nil || livePipe != nil || liveCapture != nil || !sourceNodes.isEmpty
        guard hadLiveInput else { return }

        liveCapture?.stop()
        liveCapture = nil
        livePipe?.reset()
        livePipe = nil
        liveInputSource = nil
        liveStartDate = nil
        liveInputMuted = false
        detachSourceNodes()
        AppLogger.shared.notice(category: "live-input", "Stopped live input.")
        stopEngineIfRunning(reason: "live input stop")
    }

    private func stopEngineIfRunning(reason: String) {
        guard engine.isRunning else { return }
        engine.stop()
        resetMonitorMeterLevels()
        AppLogger.shared.notice(category: "engine", "AVAudioEngine stopped. reason=\(reason)")
    }

    private func detachPlayerNodes() {
        cancelLocalGaplessScheduler(reason: "player graph detached", clearQueue: false)
        markPausedPlaybackNeedsReschedule(reason: "player graph detached")
        playerNodes.forEach { player in
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        playerNodes = []
    }

    private func detachSourceNodes() {
        sourceNodes.forEach { sourceNode in
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        sourceNodes = []
    }

    private func volume(for role: SurroundChannelRole) -> Float {
        if role.isLFE {
            return 0.94
        }
        return 1
    }

    private func installMonitorMeterTap() {
        preVolumeMixer.removeTap(onBus: 0)
        preVolumeMixer.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.captureMonitorMeters(from: buffer)
        }
    }

    private func captureMonitorMeters(from buffer: AVAudioPCMBuffer) {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else {
            resetMonitorMeterLevels()
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            resetMonitorMeterLevels()
            return
        }

        meteringService.ingest(
            signal: .monitor,
            bufferList: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
            frameCount: frameCount
        )
    }

    private func resetMonitorMeterLevels() {
        meteringService.setInactive(signal: .monitor, channelCount: monitorMeterChannelCount())
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(Int(value.rounded(.down)), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func slice(buffer: AVAudioPCMBuffer, fromFrame startFrame: AVAudioFramePosition) -> AVAudioPCMBuffer {
        let sourceStart = max(startFrame, 0)
        let availableFrames = AVAudioFramePosition(buffer.frameLength)
        let format = buffer.format
        guard availableFrames > 0,
              sourceStart < availableFrames
        else {
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            silence.frameLength = 1
            if let channels = silence.floatChannelData {
                for channelIndex in 0..<Int(format.channelCount) {
                    channels[channelIndex].initialize(repeating: 0, count: 1)
                }
            }
            return silence
        }

        let framesRemaining = availableFrames - sourceStart
        let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesRemaining))!
        slice.frameLength = AVAudioFrameCount(framesRemaining)

        guard let sourceChannels = buffer.floatChannelData,
              let destinationChannels = slice.floatChannelData
        else { return slice }

        let offset = Int(sourceStart)
        for channelIndex in 0..<Int(format.channelCount) {
            destinationChannels[channelIndex].update(
                from: sourceChannels[channelIndex].advanced(by: offset),
                count: Int(framesRemaining)
            )
        }
        return slice
    }

    private static func meterLevel(
        for buffer: AVAudioPCMBuffer,
        atFrame frame: AVAudioFramePosition,
        sampleWindow: Int
    ) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }

        let samples = channelData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return 0
        }

        let startFrame = max(0, min(Int(frame), frameLength - 1))
        let endFrame = min(frameLength, startFrame + sampleWindow)
        let count = max(endFrame - startFrame, 1)

        var energy: Float = 0
        for index in startFrame..<endFrame {
            let sample = samples[index]
            energy += sample * sample
        }

        let rms = sqrtf(energy / Float(count))
        let db = 20 * log10f(max(rms, 0.000_01))
        return min(max((db + 60) / 60, 0), 1)
    }

    private static func meterLevel(samples: UnsafePointer<Float>, frameCount: Int) -> Float {
        guard frameCount > 0 else { return 0 }

        var energy: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            energy += sample * sample
        }

        let rms = sqrtf(energy / Float(frameCount))
        let db = 20 * log10f(max(rms, 0.000_01))
        return min(max((db + 60) / 60, 0), 1)
    }

    private static func clear(audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else { return }

        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let rawData = buffer.mData else { continue }
            let sampleCount = min(
                Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride,
                frameCount
            )
            rawData.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: sampleCount)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
