import CoreAudio
import Foundation

// Coerces a CoreAudio output device's nominal sample rate to a target rate.
// The desktop stereo monitor (e.g. MacBook Air Speakers) must match the Dante
// session rate before the production plan is validated; macOS otherwise leaves
// it at whatever rate a prior app requested (commonly 96 kHz), which the plan
// validator treats as a hard route mismatch and refuses to play. Mirrors the
// CoreAudio handling in BlackHoleRouteRepair.
enum OutputDeviceSampleRate {
    // Returns the device's nominal sample rate after attempting to set it to
    // `targetRate`. Returns nil only when the device is invalid; on a failed or
    // unsupported set it returns the device's current rate so the caller can
    // fall back to normal validation.
    @discardableResult
    static func coerce(deviceID: AudioDeviceID, to targetRate: Double) -> Double? {
        guard deviceID != 0, targetRate > 0 else { return nil }

        let current = currentNominalSampleRate(deviceID: deviceID)
        if let current, abs(current - targetRate) <= 1 {
            return current
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address), isSettable(deviceID: deviceID, address: &address) else {
            AppLogger.shared.warning(
                category: "route",
                "Desktop monitor sample rate not settable device=\(deviceID) requested=\(String(format: "%.0f", targetRate))"
            )
            return current
        }

        var value = Float64(targetRate)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &value
        )
        if status != noErr {
            AppLogger.shared.warning(
                category: "route",
                "Failed to set desktop monitor sample rate device=\(deviceID) requested=\(String(format: "%.0f", targetRate)) status=\(status)"
            )
            return current
        }

        // The set succeeded, so the device accepted `targetRate` (CoreAudio
        // returns an error for unsupported rates). The hardware reconfiguration
        // is asynchronous, so reading the nominal rate back here races the
        // change and can still report the old value -- which would defeat the
        // coercion. Trust the accepted target rate. We must not block the main
        // actor waiting for the device to settle.
        AppLogger.shared.notice(
            category: "route",
            "Coerced desktop monitor sample rate device=\(deviceID) requested=\(String(format: "%.0f", targetRate))"
        )
        return targetRate
    }

    private static func currentNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func isSettable(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }
}
