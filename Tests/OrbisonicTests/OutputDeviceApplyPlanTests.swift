import XCTest
@testable import Orbisonic

final class OutputDeviceApplyPlanTests: XCTestCase {
    func testAppliesNewAvailableDeviceWhenIdle() {
        XCTAssertEqual(
            planOutputDeviceApply(refreshedDeviceID: 7, isAvailable: true, isBusy: false,
                                  currentlyAppliedDeviceID: 3, inFlightDeviceID: nil),
            .apply(7))
    }

    func testSkipsWhenUnavailable() {
        XCTAssertEqual(
            planOutputDeviceApply(refreshedDeviceID: 7, isAvailable: false, isBusy: false,
                                  currentlyAppliedDeviceID: 3, inFlightDeviceID: nil),
            .skipUnavailable)
    }

    func testSkipsWhenBusy() {
        XCTAssertEqual(
            planOutputDeviceApply(refreshedDeviceID: 7, isAvailable: true, isBusy: true,
                                  currentlyAppliedDeviceID: 3, inFlightDeviceID: nil),
            .skipBusy)
    }

    func testSkipsRedundantReapplyOfCurrentDevice() {
        XCTAssertEqual(
            planOutputDeviceApply(refreshedDeviceID: 5, isAvailable: true, isBusy: false,
                                  currentlyAppliedDeviceID: 5, inFlightDeviceID: nil),
            .skipRedundant)
    }

    func testSkipsWhenSameDeviceApplyInFlight() {
        XCTAssertEqual(
            planOutputDeviceApply(refreshedDeviceID: 9, isAvailable: true, isBusy: false,
                                  currentlyAppliedDeviceID: 3, inFlightDeviceID: 9),
            .skipInFlight)
    }

    func testAppliesNewDeviceEvenIfDifferentApplyInFlight() {
        XCTAssertEqual(
            planOutputDeviceApply(refreshedDeviceID: 9, isAvailable: true, isBusy: false,
                                  currentlyAppliedDeviceID: 3, inFlightDeviceID: 4),
            .apply(9))
    }

    func testUnavailablePrecedenceOverRedundant() {
        XCTAssertEqual(
            planOutputDeviceApply(refreshedDeviceID: 5, isAvailable: false, isBusy: false,
                                  currentlyAppliedDeviceID: 5, inFlightDeviceID: nil),
            .skipUnavailable)
    }

    func testShouldApplyAndDeviceIDAccessors() {
        let apply = planOutputDeviceApply(refreshedDeviceID: 7, isAvailable: true, isBusy: false,
                                          currentlyAppliedDeviceID: 3, inFlightDeviceID: nil)
        XCTAssertTrue(apply.shouldApply)
        XCTAssertEqual(apply.deviceID, 7)

        let skip = planOutputDeviceApply(refreshedDeviceID: 5, isAvailable: true, isBusy: false,
                                         currentlyAppliedDeviceID: 5, inFlightDeviceID: nil)
        XCTAssertFalse(skip.shouldApply)
        XCTAssertNil(skip.deviceID)
    }
}
