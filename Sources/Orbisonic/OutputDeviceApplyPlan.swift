import Foundation

/// Pure decision for whether a refreshed output route should be pushed to
/// CoreAudio. Extracted from the route-refresh path so the (expensive) device
/// apply can be gated without re-applying the same device on every route-flap
/// tick or while one apply is already in flight. `deviceID` matches CoreAudio's
/// `AudioDeviceID` (a `UInt32`) but stays framework-free so it is unit-testable.
enum OutputDeviceApplyPlan: Equatable {
    case apply(UInt32)
    case skipUnavailable
    case skipBusy
    case skipRedundant
    case skipInFlight

    var shouldApply: Bool {
        if case .apply = self { return true }
        return false
    }

    var deviceID: UInt32? {
        if case let .apply(id) = self { return id }
        return nil
    }
}

/// Decide whether to apply `refreshedDeviceID` to the engine. Precedence:
/// unavailable → busy → in-flight (same device) → redundant (already applied)
/// → apply.
func planOutputDeviceApply(
    refreshedDeviceID: UInt32,
    isAvailable: Bool,
    isBusy: Bool,
    currentlyAppliedDeviceID: UInt32,
    inFlightDeviceID: UInt32?
) -> OutputDeviceApplyPlan {
    guard isAvailable else { return .skipUnavailable }
    guard !isBusy else { return .skipBusy }
    if inFlightDeviceID == refreshedDeviceID { return .skipInFlight }
    if currentlyAppliedDeviceID == refreshedDeviceID { return .skipRedundant }
    return .apply(refreshedDeviceID)
}
