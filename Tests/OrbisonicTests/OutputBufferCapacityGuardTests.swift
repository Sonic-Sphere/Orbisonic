import AVFoundation
import XCTest
@testable import Orbisonic

final class OutputBufferCapacityGuardTests: XCTestCase {
    // AudioToolbox allocates an AVAudioPCMBuffer's storage as
    // channels * frameCapacity * bytesPerSample in 32-bit unsigned arithmetic
    // (caulk::numeric::exceptional_mul<unsigned int>) and throws std::overflow_error
    // when the product wraps past UInt32.max. A whole-file 31-channel float render
    // of a file longer than ~12 min @48kHz exceeds 2^32 and aborts the process, so
    // the engine must refuse the allocation and fall back instead of crashing.

    func testNormalLengthRenderFits() {
        // 10 min @48k, 31ch float32 = 28,800,000 * 31 * 4 = 3.57 GB < 2^32.
        let frames = 10 * 60 * 48_000
        XCTAssertTrue(OrbisonicEngine.outputBufferByteCapacityFits(frameCount: frames, channelCount: 31))
    }

    func testWholeFileRenderThatAbortedDoesNotFit() {
        // The 18.7-min mono stem captured at the crash site:
        // 53,736,273 * 31 * 4 = 6.66 GB > 2^32.
        XCTAssertFalse(OrbisonicEngine.outputBufferByteCapacityFits(frameCount: 53_736_273, channelCount: 31))
    }

    func testStereoFallbackOfSameFileStillFits() {
        // The graceful fallback renders the 2-channel monitor buffer:
        // 53,736,273 * 2 * 4 = 430 MB, which must remain allocatable.
        XCTAssertTrue(OrbisonicEngine.outputBufferByteCapacityFits(frameCount: 53_736_273, channelCount: 2))
    }

    func testBoundaryAtUInt32Max() {
        // Largest 31ch frame count whose byte product is <= UInt32.max.
        let maxFrames = Int(UInt32.max) / (31 * 4)
        XCTAssertTrue(OrbisonicEngine.outputBufferByteCapacityFits(frameCount: maxFrames, channelCount: 31))
        XCTAssertFalse(OrbisonicEngine.outputBufferByteCapacityFits(frameCount: maxFrames + 1, channelCount: 31))
    }

    func testZeroOrNegativeDoesNotFit() {
        XCTAssertFalse(OrbisonicEngine.outputBufferByteCapacityFits(frameCount: 0, channelCount: 31))
        XCTAssertFalse(OrbisonicEngine.outputBufferByteCapacityFits(frameCount: 48_000, channelCount: 0))
    }
}
