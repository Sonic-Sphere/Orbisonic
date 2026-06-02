import AudioToolbox
import XCTest
@testable import Orbisonic

final class LiveAudioBridgeTests: XCTestCase {
    func testLiveInputRejectsRequestsAboveSourceChannelLimit() {
        let engine = OrbisonicEngine()
        let route = InputRouteInfo(
            deviceID: 1,
            uid: "test-128-channel-input",
            deviceName: "Test 128 Channel Input",
            manufacturer: "Test",
            transportName: "Virtual",
            inputChannelCount: 128,
            nominalSampleRate: 48_000
        )

        XCTAssertThrowsError(
            try engine.startLiveInput(
                activeChannelCount: OrbisonicAudioLimits.maxSourceChannelCount + 1,
                inputRoute: route
            )
        ) { error in
            guard case LiveInputError.unsupportedChannelRequest(let requested, let available, let maxSupported) = error else {
                XCTFail("Expected unsupported channel request, got \(error)")
                return
            }

            XCTAssertEqual(requested, 65)
            XCTAssertEqual(available, 128)
            XCTAssertEqual(maxSupported, 64)
        }
    }

    func testStereoLiveInputOnSpherePresetUsesRendererOutput() {
        // Spotify is a 2-channel live source. On the Sonic Sphere preset its
        // renderer matrix is 2-in / 31-out and the Dante device exposes 32
        // output channels, so the live graph must drive all 31 sphere outputs
        // (physical 32) rather than collapsing to the 2-channel stereo monitor.
        XCTAssertEqual(
            OrbisonicEngine.liveRendererPhysicalOutputCount(
                matrixInputCount: 2,
                matrixOutputCount: 31,
                sourceChannelCount: 2,
                hardwareChannelCount: 32
            ),
            32
        )
    }

    func testStereoLiveInputWithStereoSceneUsesMonitorFallback() {
        // A 2-in / 2-out scene is not a sphere render; the live graph should
        // fall back to the stereo monitor path (nil physical output count).
        XCTAssertNil(
            OrbisonicEngine.liveRendererPhysicalOutputCount(
                matrixInputCount: 2,
                matrixOutputCount: 2,
                sourceChannelCount: 2,
                hardwareChannelCount: 32
            )
        )
    }

    func testLiveRendererRequiresMatrixInputToMatchSource() {
        // If the matrix input count does not match the live source channel
        // count, the renderer cannot be applied and we fall back to monitor.
        XCTAssertNil(
            OrbisonicEngine.liveRendererPhysicalOutputCount(
                matrixInputCount: 2,
                matrixOutputCount: 31,
                sourceChannelCount: 6,
                hardwareChannelCount: 32
            )
        )
    }

    func testLiveRendererWithoutMultichannelHardwareStillRendersSphere() {
        // Even without a 31-channel device attached, a sphere matrix renders
        // its full logical output count (max with hardware channels).
        XCTAssertEqual(
            OrbisonicEngine.liveRendererPhysicalOutputCount(
                matrixInputCount: 2,
                matrixOutputCount: 31,
                sourceChannelCount: 2,
                hardwareChannelCount: 2
            ),
            31
        )
    }

    func testLiveInputCaptureBufferStorageReusesPreparedAudioBufferList() throws {
        let storage = LiveInputCaptureBufferStorage(channelCount: 2, maxFrameCapacity: 8)

        let first = try XCTUnwrap(storage.prepare(frameCount: 4))
        let firstBuffers = UnsafeMutableAudioBufferListPointer(first)
        let firstDataPointers = firstBuffers.map(\.mData)

        XCTAssertEqual(first.pointee.mNumberBuffers, 2)
        XCTAssertEqual(firstBuffers[0].mDataByteSize, 4 * UInt32(MemoryLayout<Float>.size))
        XCTAssertEqual(firstBuffers[1].mDataByteSize, 4 * UInt32(MemoryLayout<Float>.size))
        XCTAssertTrue(firstDataPointers.allSatisfy { $0 != nil })

        let second = try XCTUnwrap(storage.prepare(frameCount: 6))
        let secondBuffers = UnsafeMutableAudioBufferListPointer(second)
        let secondDataPointers = secondBuffers.map(\.mData)

        XCTAssertEqual(first, second)
        XCTAssertEqual(firstDataPointers, secondDataPointers)
        XCTAssertEqual(secondBuffers[0].mDataByteSize, 6 * UInt32(MemoryLayout<Float>.size))
        XCTAssertEqual(secondBuffers[1].mDataByteSize, 6 * UInt32(MemoryLayout<Float>.size))
        XCTAssertEqual(storage.oversizedRenderCount, 0)
    }

    func testLiveInputCaptureBufferStorageRejectsOversizedFrameCountWithoutReallocating() throws {
        let storage = LiveInputCaptureBufferStorage(channelCount: 1, maxFrameCapacity: 8)
        let prepared = try XCTUnwrap(storage.prepare(frameCount: 8))
        let preparedBuffers = UnsafeMutableAudioBufferListPointer(prepared)
        let originalDataPointer = preparedBuffers[0].mData

        XCTAssertNil(storage.prepare(frameCount: 9))
        XCTAssertEqual(storage.oversizedRenderCount, 1)
        XCTAssertEqual(storage.lastOversizedFrameCount, 9)
        XCTAssertEqual(preparedBuffers[0].mData, originalDataPointer)
        XCTAssertEqual(preparedBuffers[0].mDataByteSize, 8 * UInt32(MemoryLayout<Float>.size))
    }

    func testRingBufferPrimesBeforeReading() {
        let ring = LiveChannelRingBuffer(capacity: 16, targetLatencyFrames: 4, highWaterFrames: 8)
        var output = Array(repeating: Float(-1), count: 2)

        let initialRead = read(from: ring, into: &output)

        XCTAssertEqual(initialRead, 0)
        XCTAssertEqual(output, [0, 0])

        write([1, 2, 3], to: ring)
        let underTargetRead = read(from: ring, into: &output)

        XCTAssertEqual(underTargetRead, 0)
        XCTAssertEqual(output, [0, 0])

        write([4], to: ring)
        let primedRead = read(from: ring, into: &output)

        XCTAssertEqual(primedRead, 2)
        XCTAssertEqual(output, [1, 2])
        XCTAssertFalse(ring.status().isPriming)
    }

    func testRingBufferReprimesAfterUnderflow() {
        let ring = LiveChannelRingBuffer(capacity: 16, targetLatencyFrames: 4, highWaterFrames: 8)
        var output = Array(repeating: Float(-1), count: 6)

        write([1, 2, 3, 4], to: ring)
        let underflowRead = read(from: ring, into: &output)

        XCTAssertEqual(underflowRead, 4)
        XCTAssertEqual(output, [1, 2, 3, 4, 0, 0])
        XCTAssertTrue(ring.status().isPriming)
        XCTAssertEqual(ring.status().underflowCount, 1)

        var secondOutput = Array(repeating: Float(-1), count: 2)
        write([10, 11, 12], to: ring)
        let stillPrimingRead = read(from: ring, into: &secondOutput)

        XCTAssertEqual(stillPrimingRead, 0)
        XCTAssertEqual(secondOutput, [0, 0])

        write([13], to: ring)
        let recoveredRead = read(from: ring, into: &secondOutput)

        XCTAssertEqual(recoveredRead, 2)
        XCTAssertEqual(secondOutput, [10, 11])
    }

    func testRingBufferDropsExcessFramesInsteadOfGrowingLatency() {
        let ring = LiveChannelRingBuffer(capacity: 16, targetLatencyFrames: 4, highWaterFrames: 8)
        var output = Array(repeating: Float(-1), count: 4)

        write(Array(0..<10).map(Float.init), to: ring)
        let status = ring.status()

        XCTAssertEqual(status.availableFrames, 4)
        XCTAssertEqual(status.overflowDropFrames, 6)

        let read = read(from: ring, into: &output)

        XCTAssertEqual(read, 4)
        XCTAssertEqual(output, [6, 7, 8, 9])
    }

    func testRingBufferPeekDoesNotConsumePlaybackFrames() {
        let ring = LiveChannelRingBuffer(capacity: 16, targetLatencyFrames: 4, highWaterFrames: 8)
        var peekOutput = Array(repeating: Float(-1), count: 2)
        var readOutput = Array(repeating: Float(-1), count: 4)

        write([1, 2, 3, 4], to: ring)
        let peeked = peek(from: ring, into: &peekOutput)
        let read = read(from: ring, into: &readOutput)

        XCTAssertEqual(peeked, 2)
        XCTAssertEqual(peekOutput, [1, 2])
        XCTAssertEqual(read, 4)
        XCTAssertEqual(readOutput, [1, 2, 3, 4])
    }

    func testLiveAudioBridgeDoesNotUseNSLockInTransferPath() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Orbisonic/LiveAudioBridge.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("NSLock"))
    }

    private func write(_ values: [Float], to ring: LiveChannelRingBuffer) {
        values.withUnsafeBufferPointer { sourcePointer in
            ring.write(sourcePointer.baseAddress!, frameCount: values.count)
        }
    }

    private func read(from ring: LiveChannelRingBuffer, into output: inout [Float]) -> Int {
        let frameCount = output.count
        return output.withUnsafeMutableBufferPointer { outputPointer in
            ring.read(into: outputPointer.baseAddress!, frameCount: frameCount)
        }
    }

    private func peek(from ring: LiveChannelRingBuffer, into output: inout [Float]) -> Int {
        let frameCount = output.count
        return output.withUnsafeMutableBufferPointer { outputPointer in
            ring.peek(into: outputPointer.baseAddress!, frameCount: frameCount)
        }
    }
}
