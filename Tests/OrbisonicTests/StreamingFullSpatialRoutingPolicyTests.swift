import AVFoundation
import XCTest
@testable import Orbisonic

final class StreamingFullSpatialRoutingPolicyTests: XCTestCase {
    // A whole-file full-prepare render allocates frameCount * 32ch * 4 bytes in 32-bit
    // unsigned math and aborts (std::overflow_error) past UInt32.max. Such files must be
    // routed to the windowed streaming path so they play full 31-channel spatial.

    func testShortFileDoesNotRequireStreaming() {
        // 10 min @48kHz = 28,800,000 frames; * 32 * 4 = 3.69 GB < 2^32.
        let frames: AVAudioFramePosition = 10 * 60 * 48_000
        XCTAssertFalse(
            StreamingLocalPlaybackPolicy.requiresStreamingForFullSpatialRender(durationFrames: frames)
        )
    }

    func testLongSpatialFileRequiresStreaming() {
        // ~20 min @48kHz VR track = 57,600,000 frames; * 32 * 4 = 7.37 GB > 2^32.
        let frames: AVAudioFramePosition = 20 * 60 * 48_000
        XCTAssertTrue(
            StreamingLocalPlaybackPolicy.requiresStreamingForFullSpatialRender(durationFrames: frames)
        )
    }

    func testNilDurationDoesNotRequireStreaming() {
        XCTAssertFalse(
            StreamingLocalPlaybackPolicy.requiresStreamingForFullSpatialRender(durationFrames: nil)
        )
    }

    func testZeroDurationDoesNotRequireStreaming() {
        XCTAssertFalse(
            StreamingLocalPlaybackPolicy.requiresStreamingForFullSpatialRender(durationFrames: 0)
        )
    }

    func testBoundaryAtUInt32Max() {
        // Largest 32ch frame count whose byte product is <= UInt32.max.
        let maxFrames = AVAudioFramePosition(Int64(UInt32.max) / (32 * 4))
        XCTAssertFalse(
            StreamingLocalPlaybackPolicy.requiresStreamingForFullSpatialRender(durationFrames: maxFrames)
        )
        XCTAssertTrue(
            StreamingLocalPlaybackPolicy.requiresStreamingForFullSpatialRender(durationFrames: maxFrames + 1)
        )
    }
}
