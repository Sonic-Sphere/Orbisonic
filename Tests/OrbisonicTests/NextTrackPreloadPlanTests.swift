import XCTest
@testable import Orbisonic

final class NextTrackPreloadPlanTests: XCTestCase {
    func testAllowsWhenEstimateFitsWithinFraction() {
        XCTAssertEqual(
            planNextTrackPreload(estimatedBytes: 200_000_000, availableBytes: 8_000_000_000, fraction: 0.5),
            .allow
        )
    }

    func testAllowsAtExactBoundary() {
        XCTAssertEqual(
            planNextTrackPreload(estimatedBytes: 4_000_000_000, availableBytes: 8_000_000_000, fraction: 0.5),
            .allow
        )
    }

    func testSkipsLowMemoryWhenEstimateExceedsFraction() {
        XCTAssertEqual(
            planNextTrackPreload(estimatedBytes: 5_000_000_000, availableBytes: 8_000_000_000, fraction: 0.5),
            .skipLowMemory
        )
    }

    func testSkipsUnknownSizeWhenEstimateMissingOrZero() {
        XCTAssertEqual(planNextTrackPreload(estimatedBytes: nil, availableBytes: 8_000_000_000, fraction: 0.5), .skipUnknownSize)
        XCTAssertEqual(planNextTrackPreload(estimatedBytes: 0, availableBytes: 8_000_000_000, fraction: 0.5), .skipUnknownSize)
    }

    func testSkipsLowMemoryWhenNoRAMAvailable() {
        XCTAssertEqual(planNextTrackPreload(estimatedBytes: 100, availableBytes: 0, fraction: 0.5), .skipLowMemory)
    }

    func testStatusWebTokensAreStable() {
        XCTAssertEqual(NextTrackPreloadStatus.ready.webToken, "ready")
        XCTAssertEqual(NextTrackPreloadStatus.skippedLowMemory.webToken, "skippedLowMemory")
        XCTAssertTrue(NextTrackPreloadStatus.preparing.isBusy)
    }
}
