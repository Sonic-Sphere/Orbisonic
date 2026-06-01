import XCTest
@testable import Orbisonic

final class PlaybackActivityTests: XCTestCase {
    func testIdleIsNotBusyAndHasNoLabel() {
        XCTAssertFalse(PlaybackActivity.idle.isBusy)
        XCTAssertTrue(PlaybackActivity.idle.label.isEmpty)
        XCTAssertEqual(PlaybackActivity.idle.phase, .idle)
    }

    func testDecodingWithKnownProgress() {
        let activity = PlaybackActivity(phase: .decoding, detail: "Aurora.flac", progress: 0.42)
        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(activity.isIndeterminate)
        XCTAssertEqual(activity.clampedProgress, 0.42)
        XCTAssertTrue(activity.label.contains("Aurora.flac"))
        XCTAssertTrue(activity.label.contains("42%"))
        XCTAssertTrue(activity.label.lowercased().contains("decod"))
    }

    func testProgressIsClamped() {
        XCTAssertEqual(PlaybackActivity(phase: .decoding, detail: "x", progress: 1.7).clampedProgress, 1.0)
        XCTAssertEqual(PlaybackActivity(phase: .decoding, detail: "x", progress: -0.5).clampedProgress, 0.0)
    }

    func testIndeterminateActivityOmitsPercent() {
        let activity = PlaybackActivity(phase: .probing, detail: "x.wav", progress: nil)
        XCTAssertTrue(activity.isIndeterminate)
        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(activity.label.contains("%"))
    }

    func testSwitchingOutputLabelMentionsDevice() {
        let activity = PlaybackActivity(phase: .switchingOutput, detail: "TEAC ML-32D", progress: nil)
        XCTAssertTrue(activity.isBusy)
        XCTAssertTrue(activity.label.contains("TEAC ML-32D"))
        XCTAssertTrue(activity.label.lowercased().contains("output") || activity.label.lowercased().contains("switch"))
    }

    func testCodableRoundTripAndStableRawValue() throws {
        let activity = PlaybackActivity(phase: .decoding, detail: "Aurora.flac", progress: 0.42)
        let data = try JSONEncoder().encode(activity)
        let decoded = try JSONDecoder().decode(PlaybackActivity.self, from: data)
        XCTAssertEqual(decoded, activity)
        XCTAssertEqual(PlaybackActivity.Phase.switchingOutput.rawValue, "switchingOutput")
    }
}
