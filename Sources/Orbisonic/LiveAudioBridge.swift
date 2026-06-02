import AudioToolbox
import AVFoundation
import Darwin
import Foundation

struct LiveInputSource {
    let layout: SurroundLayout
    let metadata: AudioSourceMetadata
}

enum LiveInputError: LocalizedError {
    case inputDeviceUnavailable(String)
    case inputDeviceSelectionFailed(deviceName: String, status: OSStatus)
    case inputAudioUnitUnavailable(String)
    case inputAudioUnitConfigurationFailed(deviceName: String, operation: String, status: OSStatus)
    case inputAudioUnitStartFailed(deviceName: String, status: OSStatus)
    case noInputChannels
    case unsupportedChannelRequest(requested: Int, available: UInt32, maxSupported: Int)
    case monoFormatCreationFailed(Double)

    var errorDescription: String? {
        switch self {
        case .inputDeviceUnavailable(let deviceName):
            "The selected input device is not available: \(deviceName)."
        case .inputDeviceSelectionFailed(let deviceName, let status):
            "Unable to capture \(deviceName) directly. Core Audio returned \(status)."
        case .inputAudioUnitUnavailable(let deviceName):
            "Unable to access the Core Audio input unit for \(deviceName)."
        case .inputAudioUnitConfigurationFailed(let deviceName, let operation, let status):
            "Unable to configure \(deviceName) for live capture while \(operation). Core Audio returned \(status)."
        case .inputAudioUnitStartFailed(let deviceName, let status):
            "Unable to start live capture from \(deviceName). Core Audio returned \(status)."
        case .noInputChannels:
            "The selected input device has no input channels."
        case .unsupportedChannelRequest(let requested, let available, let maxSupported):
            requested > maxSupported
                ? "Orbisonic supports up to \(maxSupported) live input channels in this build. Requested \(requested) channels."
                : "Requested \(requested) live input channels, but the selected input device exposes \(available)."
        case .monoFormatCreationFailed(let sampleRate):
            "Unable to create a live mono render format at \(sampleRate) Hz."
        }
    }
}

final class LiveInputCapture {
    static let maxCallbackFrameCapacity: UInt32 = 8_192

    private let inputRoute: InputRouteInfo
    private let pipe: LiveAudioPipe
    private let activeChannelCount: Int
    private let captureChannelCount: Int
    private let sampleRate: Double
    private let captureStorage: LiveInputCaptureBufferStorage
    private var audioUnit: AudioUnit?
    private var isStarted = false

    init(
        inputRoute: InputRouteInfo,
        activeChannelCount: Int,
        sampleRate: Double,
        pipe: LiveAudioPipe
    ) throws {
        self.inputRoute = inputRoute
        self.activeChannelCount = activeChannelCount
        self.captureChannelCount = min(
            max(inputRoute.inputChannelCount, activeChannelCount, 1),
            OrbisonicAudioLimits.maxSourceChannelCount
        )
        self.sampleRate = sampleRate
        self.pipe = pipe
        self.captureStorage = LiveInputCaptureBufferStorage(
            channelCount: captureChannelCount,
            maxFrameCapacity: Self.maxCallbackFrameCapacity
        )

        do {
            audioUnit = try Self.makeHALInputUnit(deviceName: inputRoute.deviceName)
            try configure()
        } catch {
            dispose()
            throw error
        }
    }

    deinit {
        dispose()
    }

    func start() throws {
        guard let audioUnit else {
            throw LiveInputError.inputAudioUnitUnavailable(inputRoute.deviceName)
        }

        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            throw LiveInputError.inputAudioUnitStartFailed(
                deviceName: inputRoute.deviceName,
                status: status
            )
        }

        isStarted = true
        AppLogger.shared.notice(
            category: "live-input",
            "Started HAL capture device=\(inputRoute.deviceName) uid=\(inputRoute.uid) captureChannels=\(captureChannelCount) activeChannels=\(activeChannelCount) sampleRate=\(sampleRate) maxCallbackFrames=\(captureStorage.maxFrameCapacity)"
        )
    }

    func stop() {
        dispose()
    }

    private static func makeHALInputUnit(deviceName: String) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw LiveInputError.inputAudioUnitUnavailable(deviceName)
        }

        var audioUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit else {
            throw LiveInputError.inputAudioUnitConfigurationFailed(
                deviceName: deviceName,
                operation: "creating the HAL input unit",
                status: status
            )
        }

        return audioUnit
    }

    private func configure() throws {
        guard let audioUnit else {
            throw LiveInputError.inputAudioUnitUnavailable(inputRoute.deviceName)
        }

        var enableInput: UInt32 = 1
        try setProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            scope: kAudioUnitScope_Input,
            element: 1,
            data: &enableInput,
            size: MemoryLayout<UInt32>.size,
            operation: "enabling input"
        )

        var disableOutput: UInt32 = 0
        try setProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            scope: kAudioUnitScope_Output,
            element: 0,
            data: &disableOutput,
            size: MemoryLayout<UInt32>.size,
            operation: "disabling HAL output"
        )

        var deviceID = inputRoute.deviceID
        try setProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &deviceID,
            size: MemoryLayout<AudioDeviceID>.size,
            operation: "selecting the input device"
        )

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagsNativeEndian
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(captureChannelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        try setProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Output,
            element: 1,
            data: &format,
            size: MemoryLayout<AudioStreamBasicDescription>.size,
            operation: "setting the input stream format"
        )

        var callback = AURenderCallbackStruct(
            inputProc: Self.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try setProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &callback,
            size: MemoryLayout<AURenderCallbackStruct>.size,
            operation: "installing the input callback"
        )

        let status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw LiveInputError.inputAudioUnitConfigurationFailed(
                deviceName: inputRoute.deviceName,
                operation: "initializing the HAL input unit",
                status: status
            )
        }

        AppLogger.shared.notice(
            category: "live-input",
            "Configured direct HAL input device=\(inputRoute.deviceName) uid=\(inputRoute.uid) deviceID=\(inputRoute.deviceID) captureChannels=\(captureChannelCount) activeChannels=\(activeChannelCount) sampleRate=\(sampleRate) maxCallbackFrames=\(captureStorage.maxFrameCapacity)"
        )
    }

    private func setProperty(
        _ audioUnit: AudioUnit,
        _ propertyID: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeRawPointer,
        size: Int,
        operation: String
    ) throws {
        let status = AudioUnitSetProperty(
            audioUnit,
            propertyID,
            scope,
            element,
            data,
            UInt32(size)
        )

        guard status == noErr else {
            throw LiveInputError.inputAudioUnitConfigurationFailed(
                deviceName: inputRoute.deviceName,
                operation: operation,
                status: status
            )
        }
    }

    private static let inputCallback: AURenderCallback = { refCon, ioActionFlags, timeStamp, _, frameCount, _ in
        let capture = Unmanaged<LiveInputCapture>.fromOpaque(refCon).takeUnretainedValue()
        return capture.renderInput(
            ioActionFlags: ioActionFlags,
            timeStamp: timeStamp,
            frameCount: frameCount
        )
    }

    private func renderInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let audioUnit else {
            return kAudioUnitErr_Uninitialized
        }

        guard frameCount > 0 else {
            return noErr
        }

        guard let bufferList = captureStorage.prepare(frameCount: frameCount) else {
            return kAudioUnitErr_TooManyFramesToProcess
        }

        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            timeStamp,
            1,
            frameCount,
            bufferList
        )

        guard status == noErr else {
            return status
        }

        pipe.write(bufferList: UnsafeMutableAudioBufferListPointer(bufferList), frameCount: Int(frameCount))
        return noErr
    }

    private func dispose() {
        guard let audioUnit else { return }

        if isStarted {
            AudioOutputUnitStop(audioUnit)
            isStarted = false
        }

        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
    }
}

final class LiveInputCaptureBufferStorage {
    let channelCount: Int
    let maxFrameCapacity: UInt32
    private(set) var oversizedRenderCount = 0
    private(set) var lastOversizedFrameCount: UInt32 = 0

    private let rawBufferList: UnsafeMutableRawPointer
    private let bufferList: UnsafeMutablePointer<AudioBufferList>
    private var channelStorage: [UnsafeMutablePointer<Float>]

    init(channelCount: Int, maxFrameCapacity: UInt32) {
        self.channelCount = max(channelCount, 1)
        self.maxFrameCapacity = max(maxFrameCapacity, 1)

        let byteCount = MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.stride * (self.channelCount - 1)
        rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawBufferList.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        bufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        bufferList.pointee.mNumberBuffers = UInt32(self.channelCount)
        channelStorage = []
        channelStorage.reserveCapacity(self.channelCount)

        let maxFrameCount = Int(self.maxFrameCapacity)
        for _ in 0..<self.channelCount {
            let channelData = UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
            channelData.initialize(repeating: 0, count: maxFrameCount)
            channelStorage.append(channelData)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for index in buffers.indices {
            buffers[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: 0,
                mData: UnsafeMutableRawPointer(channelStorage[index])
            )
        }
    }

    deinit {
        let maxFrameCount = Int(maxFrameCapacity)
        for channelData in channelStorage {
            channelData.deinitialize(count: maxFrameCount)
            channelData.deallocate()
        }
        rawBufferList.deallocate()
    }

    func prepare(frameCount: UInt32) -> UnsafeMutablePointer<AudioBufferList>? {
        guard frameCount <= maxFrameCapacity else {
            oversizedRenderCount &+= 1
            lastOversizedFrameCount = frameCount
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let dataByteCount = frameCount * UInt32(MemoryLayout<Float>.size)
        for index in buffers.indices {
            buffers[index].mDataByteSize = dataByteCount
        }
        return bufferList
    }
}

final class LiveChannelRingBuffer {
    private let targetLatencyFrames: Int
    private let highWaterFrames: Int
    private let storageCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let readCursor = RealtimeAtomicInt()
    private let writeCursor = RealtimeAtomicInt()
    private let isPriming = RealtimeAtomicFlag(initialValue: true)
    private let underflowCount = RealtimeAtomicInt()
    private let underflowFrames = RealtimeAtomicInt()
    private let overflowDropFrames = RealtimeAtomicInt()
    private let transferGate = RealtimeAtomicFlag()

    init(capacity: Int, targetLatencyFrames: Int, highWaterFrames: Int) {
        let clampedCapacity = max(capacity, 1_024)
        storageCapacity = clampedCapacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: clampedCapacity)
        storage.initialize(repeating: 0, count: clampedCapacity)
        self.targetLatencyFrames = min(max(targetLatencyFrames, 1), clampedCapacity)
        self.highWaterFrames = min(max(highWaterFrames, self.targetLatencyFrames), clampedCapacity)
    }

    deinit {
        storage.deinitialize(count: storageCapacity)
        storage.deallocate()
    }

    var capacity: Int {
        storageCapacity
    }

    func write(_ source: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }

        let candidateFrames = min(frameCount, storageCapacity)
        let baseSourceOffset = frameCount - candidateFrames
        var sourceOffset = baseSourceOffset
        var framesToWrite = candidateFrames
        var droppedFrames = baseSourceOffset

        let currentRead = readCursor.load()
        let currentWrite = writeCursor.load()
        let available = clampedAvailableFrames(read: currentRead, write: currentWrite)
        let projectedAvailable = available + candidateFrames
        let capacityDrop = max(projectedAvailable - storageCapacity, 0)
        let highWaterDrop = projectedAvailable > highWaterFrames
            ? max(projectedAvailable - targetLatencyFrames, 0)
            : 0
        let totalDrop = min(max(capacityDrop, highWaterDrop), available + candidateFrames)
        let oldFrameDrop = min(totalDrop, available)
        let incomingFrameDrop = totalDrop - oldFrameDrop

        if oldFrameDrop > 0 {
            if enterTransferGate() {
                let gatedRead = readCursor.load()
                let gatedWrite = writeCursor.load()
                let gatedAvailable = clampedAvailableFrames(read: gatedRead, write: gatedWrite)
                let gatedProjected = gatedAvailable + candidateFrames
                let gatedCapacityDrop = max(gatedProjected - storageCapacity, 0)
                let gatedHighWaterDrop = gatedProjected > highWaterFrames
                    ? max(gatedProjected - targetLatencyFrames, 0)
                    : 0
                let gatedTotalDrop = min(max(gatedCapacityDrop, gatedHighWaterDrop), gatedAvailable + candidateFrames)
                let gatedOldDrop = min(gatedTotalDrop, gatedAvailable)
                let gatedIncomingDrop = gatedTotalDrop - gatedOldDrop

                if gatedOldDrop > 0 {
                    readCursor.store(gatedRead + gatedOldDrop)
                }
                sourceOffset = baseSourceOffset + gatedIncomingDrop
                framesToWrite = max(candidateFrames - gatedIncomingDrop, 0)
                droppedFrames = baseSourceOffset + gatedOldDrop + gatedIncomingDrop
                leaveTransferGate()
            } else {
                let freeFrames = max(storageCapacity - available, 0)
                framesToWrite = min(candidateFrames, freeFrames)
                sourceOffset = frameCount - framesToWrite
                droppedFrames = frameCount - framesToWrite
            }
        } else if incomingFrameDrop > 0 {
            sourceOffset = baseSourceOffset + incomingFrameDrop
            framesToWrite = max(candidateFrames - incomingFrameDrop, 0)
            droppedFrames = baseSourceOffset + incomingFrameDrop
        }

        if droppedFrames > 0 {
            overflowDropFrames.add(droppedFrames)
        }

        guard framesToWrite > 0 else { return }

        let startWrite = writeCursor.load()
        for frame in 0..<framesToWrite {
            storage[(startWrite + frame) % storageCapacity] = source[sourceOffset + frame]
        }
        writeCursor.store(startWrite + framesToWrite)
    }

    func read(into destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }

        guard enterTransferGate() else {
            destination.initialize(repeating: 0, count: frameCount)
            underflowCount.add(1)
            underflowFrames.add(frameCount)
            isPriming.store(true)
            return 0
        }
        defer { leaveTransferGate() }

        var currentRead = readCursor.load()
        let currentWrite = writeCursor.load()
        var available = clampedAvailableFrames(read: currentRead, write: currentWrite)

        if available > storageCapacity {
            let drop = available - storageCapacity
            currentRead += drop
            readCursor.store(currentRead)
            overflowDropFrames.add(drop)
            available = storageCapacity
        }

        if isPriming.load() {
            guard available >= targetLatencyFrames else {
                destination.initialize(repeating: 0, count: frameCount)
                return 0
            }

            isPriming.store(false)
        }

        let framesToRead = min(frameCount, available)
        if framesToRead > 0 {
            for frame in 0..<framesToRead {
                destination[frame] = storage[(currentRead + frame) % storageCapacity]
            }
            currentRead += framesToRead
            readCursor.store(currentRead)
        }

        if framesToRead < frameCount {
            let missingFrames = frameCount - framesToRead
            destination.advanced(by: framesToRead).initialize(repeating: 0, count: missingFrames)
            underflowCount.add(1)
            underflowFrames.add(missingFrames)
            isPriming.store(true)
        }

        return framesToRead
    }

    func peek(into destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }

        guard enterTransferGate() else {
            destination.initialize(repeating: 0, count: frameCount)
            return 0
        }
        defer { leaveTransferGate() }

        let currentRead = readCursor.load()
        let currentWrite = writeCursor.load()
        let available = clampedAvailableFrames(read: currentRead, write: currentWrite)

        if isPriming.load(), available < targetLatencyFrames {
            destination.initialize(repeating: 0, count: frameCount)
            return 0
        }

        let framesToRead = min(frameCount, available)
        if framesToRead > 0 {
            for frame in 0..<framesToRead {
                destination[frame] = storage[(currentRead + frame) % storageCapacity]
            }
        }

        if framesToRead < frameCount {
            for frame in framesToRead..<frameCount {
                destination[frame] = 0
            }
        }

        return framesToRead
    }

    func status() -> LiveChannelRingBufferStatus {
        let currentRead = readCursor.load()
        let currentWrite = writeCursor.load()

        return LiveChannelRingBufferStatus(
            availableFrames: clampedAvailableFrames(read: currentRead, write: currentWrite),
            targetLatencyFrames: targetLatencyFrames,
            highWaterFrames: highWaterFrames,
            capacityFrames: storageCapacity,
            isPriming: isPriming.load(),
            underflowCount: underflowCount.load(),
            underflowFrames: underflowFrames.load(),
            overflowDropFrames: overflowDropFrames.load()
        )
    }

    func reset() {
        readCursor.store(0)
        writeCursor.store(0)
        isPriming.store(true)
        underflowCount.store(0)
        underflowFrames.store(0)
        overflowDropFrames.store(0)
    }

    private func clampedAvailableFrames(read: Int, write: Int) -> Int {
        min(max(write - read, 0), storageCapacity)
    }

    private func enterTransferGate() -> Bool {
        transferGate.tryEnter()
    }

    private func leaveTransferGate() {
        transferGate.store(false)
    }
}

struct LiveChannelRingBufferStatus: Equatable {
    let availableFrames: Int
    let targetLatencyFrames: Int
    let highWaterFrames: Int
    let capacityFrames: Int
    let isPriming: Bool
    let underflowCount: Int
    let underflowFrames: Int
    let overflowDropFrames: Int
}

struct LiveAudioPipeStatus: Equatable {
    let minimumBufferedFrames: Int
    let maximumBufferedFrames: Int
    let targetLatencyFrames: Int
    let highWaterFrames: Int
    let capacityFrames: Int
    let isPriming: Bool
    let underflowCount: Int
    let underflowFrames: Int
    let overflowDropFrames: Int

    func displayText(sampleRate: Double) -> String {
        let minimumMilliseconds = milliseconds(for: minimumBufferedFrames, sampleRate: sampleRate)
        let maximumMilliseconds = milliseconds(for: maximumBufferedFrames, sampleRate: sampleRate)
        let targetMilliseconds = milliseconds(for: targetLatencyFrames, sampleRate: sampleRate)
        let mode = isPriming ? "priming" : "locked"

        return "\(mode) • \(minimumMilliseconds)-\(maximumMilliseconds) ms buffered • target \(targetMilliseconds) ms"
    }

    private func milliseconds(for frames: Int, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Double(frames) / sampleRate * 1_000).rounded())
    }
}

final class LiveAudioPipe {
    let channelCount: Int
    let sampleRate: Double
    let outputSampleRate: Double

    private let rings: [LiveChannelRingBuffer]
    private let meteringService: MeteringService?
    private let meterLevels: RealtimeMeterLevelStorage
    private let callbackSafetyProbe: RealtimeCallbackSafetyProbe?
    private let baseResampleStep: Double
    private let resampleTargetFrames: Int
    private let driftController: LiveDriftController
    private let converter: LiveSampleRateConverter

    init(
        channelCount: Int,
        sampleRate: Double,
        outputSampleRate: Double? = nil,
        latencySeconds: Double = 0.15,
        meteringService: MeteringService? = nil,
        callbackSafetyProbe: RealtimeCallbackSafetyProbe? = nil
    ) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        let candidateOutputRate = outputSampleRate ?? sampleRate
        let resolvedOutputRate = candidateOutputRate > 0 ? candidateOutputRate : sampleRate
        self.outputSampleRate = resolvedOutputRate
        self.meteringService = meteringService
        self.callbackSafetyProbe = callbackSafetyProbe
        let targetLatencyFrames = max(Int(sampleRate * max(latencySeconds, 0.05)), 512)
        let highWaterFrames = max(Int(Double(targetLatencyFrames) * 1.75), targetLatencyFrames + 1_024)
        let capacity = max(Int(sampleRate * max(latencySeconds * 8, 0.75)), highWaterFrames * 2, 4_096)
        rings = (0..<channelCount).map {
            _ in LiveChannelRingBuffer(
                capacity: capacity,
                targetLatencyFrames: targetLatencyFrames,
                highWaterFrames: highWaterFrames
            )
        }
        meterLevels = RealtimeMeterLevelStorage(channelCount: channelCount)
        baseResampleStep = (sampleRate > 0 && resolvedOutputRate > 0) ? sampleRate / resolvedOutputRate : 1.0
        resampleTargetFrames = targetLatencyFrames
        driftController = LiveDriftController()
        converter = LiveSampleRateConverter(channelCount: channelCount)
    }

    func write(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        let frames = Int(buffer.frameLength)
        let sourceChannelCount = Int(buffer.format.channelCount)
        let channelsToWrite = min(channelCount, sourceChannelCount)
        guard frames > 0, channelsToWrite > 0 else { return }

        meterLevels.clear()

        for channel in 0..<channelsToWrite {
            let source = channelData[channel]
            rings[channel].write(source, frameCount: frames)
            meterLevels.store(channel: channel, level: Self.meterLevel(samples: source, frameCount: frames))
        }

        meteringService?.ingest(
            signal: .input,
            bufferList: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
            frameCount: frames
        )
    }

    func write(bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let channelsToWrite = min(channelCount, bufferList.count)
        guard frameCount > 0, channelsToWrite > 0 else { return }

        meterLevels.clear()

        for channel in 0..<channelsToWrite {
            guard let rawData = bufferList[channel].mData else {
                continue
            }

            let source = rawData.assumingMemoryBound(to: Float.self)
            let availableFrames = Int(bufferList[channel].mDataByteSize) / MemoryLayout<Float>.size
            let framesToWrite = min(frameCount, availableFrames)
            guard framesToWrite > 0 else {
                continue
            }

            rings[channel].write(source, frameCount: framesToWrite)
            meterLevels.store(channel: channel, level: Self.meterLevel(samples: source, frameCount: framesToWrite))
        }

        meteringService?.ingest(signal: .input, bufferList: bufferList, frameCount: frameCount)
    }

    func render(channelIndex: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount) -> OSStatus {
        let frames = Int(frameCount)
        let callbackTrace = callbackSafetyProbe?.begin(blockSize: frames)
        defer {
            if let callbackTrace {
                callbackSafetyProbe?.end(callbackTrace)
            }
        }

        guard channelIndex >= 0, channelIndex < rings.count else {
            callbackSafetyProbe?.recordRouteMismatchBlocked()
            return noErr
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

        for bufferIndex in buffers.indices {
            guard let rawData = buffers[bufferIndex].mData else {
                continue
            }

            let output = rawData.assumingMemoryBound(to: Float.self)
            if bufferIndex == 0 {
                _ = rings[channelIndex].read(into: output, frameCount: frames)
            } else {
                output.initialize(repeating: 0, count: frames)
            }
        }

        return noErr
    }

    func render(
        matrix: RendererMatrix,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> OSStatus {
        let frames = Int(frameCount)
        let callbackTrace = callbackSafetyProbe?.begin(blockSize: frames)
        defer {
            if let callbackTrace {
                callbackSafetyProbe?.end(callbackTrace)
            }
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard frames > 0,
              matrix.inputCount == rings.count,
              matrix.outputCount > 0
        else {
            callbackSafetyProbe?.recordRouteMismatchBlocked()
            clear(audioBufferList: audioBufferList, frameCount: frames)
            return noErr
        }

        // Drift-compensating resample from the capture-rate rings to the Dante
        // output rate. The capture and output clocks free-run independently, so a
        // fixed ratio cannot hold the buffer steady; we nudge the resample step
        // from the measured ring fill to keep latency at target, absorbing drift
        // that otherwise drops frames (popping) or underflows (cutouts).
        let fill = rings.map { $0.status().availableFrames }.min() ?? 0
        let correction = driftController.rateCorrection(
            availableFrames: fill,
            targetFrames: resampleTargetFrames
        )
        let step = baseResampleStep * (1 + correction)
        let consumed = converter.framesToConsume(outputFrames: frames, step: step)

        callbackSafetyProbe?.recordCallbackAllocation(count: matrix.inputCount * 2 + 1)
        var inputScratch = Array(
            repeating: Array(repeating: Float(0), count: max(consumed, 1)),
            count: matrix.inputCount
        )
        if consumed > 0 {
            for inputIndex in 0..<matrix.inputCount {
                inputScratch[inputIndex].withUnsafeMutableBufferPointer { destination in
                    guard let baseAddress = destination.baseAddress else { return }
                    _ = rings[inputIndex].read(into: baseAddress, frameCount: consumed)
                }
            }
        }

        var resampled = Array(
            repeating: Array(repeating: Float(0), count: frames),
            count: matrix.inputCount
        )
        converter.process(
            inputs: inputScratch,
            inputFrameCount: consumed,
            step: step,
            outputFrames: frames,
            into: &resampled
        )

        RendererMatrixSampleRenderer.render(
            matrix: matrix,
            inputSamples: resampled,
            frameCount: frames,
            outputBuffers: buffers
        )

        meteringService?.ingest(signal: .sonicSphere, bufferList: buffers, frameCount: frames)
        return noErr
    }

    @discardableResult
    func renderMeterSnapshot(matrix: RendererMatrix, frameCount: Int) -> Bool {
        let frames = max(frameCount, 0)
        guard frames > 0,
              matrix.inputCount == rings.count,
              matrix.outputCount > 0
        else {
            return false
        }

        var inputScratch = Array(
            repeating: Array(repeating: Float(0), count: frames),
            count: matrix.inputCount
        )

        for inputIndex in 0..<matrix.inputCount {
            inputScratch[inputIndex].withUnsafeMutableBufferPointer { destination in
                guard let baseAddress = destination.baseAddress else { return }
                _ = rings[inputIndex].peek(into: baseAddress, frameCount: frames)
            }
        }

        let rendered = RendererMatrixSampleRenderer.renderSampleBuffers(
            matrix: matrix,
            inputSamples: inputScratch,
            frameCount: frames
        )
        guard rendered.frameCount > 0 else { return false }
        meteringService?.ingest(
            signal: .sonicSphere,
            sampleBuffers: rendered.sampleBuffers,
            frameCount: rendered.frameCount
        )
        return true
    }

    func latestMeterLevels() -> [Float] {
        meterLevels.snapshot()
    }

    func status() -> LiveAudioPipeStatus? {
        let statuses = rings.map { $0.status() }
        guard let first = statuses.first else { return nil }

        return LiveAudioPipeStatus(
            minimumBufferedFrames: statuses.map(\.availableFrames).min() ?? 0,
            maximumBufferedFrames: statuses.map(\.availableFrames).max() ?? 0,
            targetLatencyFrames: first.targetLatencyFrames,
            highWaterFrames: first.highWaterFrames,
            capacityFrames: first.capacityFrames,
            isPriming: statuses.contains(where: \.isPriming),
            underflowCount: statuses.map(\.underflowCount).reduce(0, +),
            underflowFrames: statuses.map(\.underflowFrames).reduce(0, +),
            overflowDropFrames: statuses.map(\.overflowDropFrames).reduce(0, +)
        )
    }

    func reset() {
        rings.forEach { $0.reset() }
        meterLevels.clear()
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

    private func clear(audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
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
