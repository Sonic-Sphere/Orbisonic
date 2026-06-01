import CoreAudio
import Foundation

struct OutputRouteInfo: Equatable, Identifiable {
    let deviceID: AudioDeviceID
    let uid: String
    let deviceName: String
    let manufacturer: String
    let transportName: String
    let outputChannelCount: Int
    let nominalSampleRate: Double

    static let unavailable = OutputRouteInfo(
        deviceID: 0,
        uid: "",
        deviceName: "No Active Output",
        manufacturer: "",
        transportName: "Unknown",
        outputChannelCount: 0,
        nominalSampleRate: 0
    )

    var id: String {
        uid.isEmpty ? "\(deviceID)" : uid
    }

    func withNominalSampleRate(_ rate: Double) -> OutputRouteInfo {
        OutputRouteInfo(
            deviceID: deviceID,
            uid: uid,
            deviceName: deviceName,
            manufacturer: manufacturer,
            transportName: transportName,
            outputChannelCount: outputChannelCount,
            nominalSampleRate: rate
        )
    }

    func matchesAudioDevice(_ other: OutputRouteInfo) -> Bool {
        guard isAvailable, other.isAvailable else { return false }
        if !uid.isEmpty, uid == other.uid {
            return true
        }
        return deviceID == other.deviceID
    }

    var isAvailable: Bool {
        deviceID != 0 && outputChannelCount > 0
    }

    var isBlackHole: Bool {
        normalized(deviceName).contains("blackhole") || normalized(manufacturer).contains("existential")
    }

    var isDanteVirtualSoundcard: Bool {
        let combined = normalized(deviceName) + " " + normalized(manufacturer)
        return combined.contains("dante virtual soundcard")
            || (combined.contains("dante") && combined.contains("audinate"))
    }

    var isOrbisonicLoopback: Bool {
        OrbisonicLoopbackDevice.allCases.contains { $0.deviceUID == uid }
    }

    var routeRisk: OutputRouteRisk {
        guard isAvailable else { return .unavailable }

        if let loopback = OrbisonicLoopbackDevice.allCases.first(where: { $0.deviceUID == uid }) {
            return .feedbackLoop(loopback.displayName)
        }

        if isBlackHole {
            return .feedbackLoop(deviceName)
        }

        if isDanteVirtualSoundcard {
            return .safe
        }

        if transportName == "Virtual" {
            return .virtualOutput(deviceName)
        }

        return .safe
    }

    var isSelectableOutputTarget: Bool {
        isAvailable && !routeRisk.blocksLiveMonitoring
    }

    var isPreferredRendererOutput: Bool {
        isSelectableOutputTarget && isDanteVirtualSoundcard
    }

    var isRendererCapableOutput: Bool {
        isSelectableOutputTarget && outputChannelCount > 2
    }

    var isHeadphones: Bool {
        let combined = normalized(deviceName) + " " + normalized(manufacturer)
        if combined.contains("airpods") || combined.contains("headphones") || combined.contains("beats") || combined.contains("buds") {
            return true
        }
        return transportName == "Bluetooth" && outputChannelCount > 0 && outputChannelCount <= 2
    }

    var targetName: String {
        if isDanteVirtualSoundcard {
            return "Dante Renderer"
        }
        if isBlackHole {
            return "BlackHole Virtual Route"
        }
        if isOrbisonicLoopback {
            return "Orbisonic Loopback"
        }
        if isRendererCapableOutput {
            return "Multichannel Renderer"
        }
        if isHeadphones {
            return "Headphones"
        }
        if transportName == "AirPlay" {
            return "AirPlay Output"
        }
        if transportName == "Aggregate" {
            return "Aggregate Device"
        }
        if transportName == "Built-In" {
            return deviceName.contains("Speaker") ? "Built-In Speakers" : "Built-In Output"
        }
        if transportName == "Virtual" {
            return "Virtual Output"
        }
        if transportName == "USB" || transportName == "HDMI" || transportName == "DisplayPort" || transportName == "Thunderbolt" {
            return "External Interface"
        }
        return isAvailable ? "System Default Output" : "No Verified Target"
    }

    var routeDetail: String {
        guard isAvailable else {
            return "macOS did not return a default output device."
        }

        if outputChannelCount > 0 {
            let rateText = nominalSampleRate > 0 ? String(format: "%.1f kHz", nominalSampleRate / 1_000) : "unknown rate"
            return "\(transportName) • \(outputChannelCount) ch • \(rateText)"
        }
        return transportName
    }

    var targetDetail: String {
        if isDanteVirtualSoundcard {
            return "Sonic Sphere renderer output."
        }
        if isBlackHole {
            return "Virtual loopback is the active macOS target, so the app is feeding BlackHole right now."
        }
        if isOrbisonicLoopback {
            return "Orbisonic is pointed at one of its input loopbacks. Choose a monitor or renderer output."
        }
        if isRendererCapableOutput {
            return "\(deviceName) is available as a multichannel renderer target."
        }
        if isHeadphones {
            return "Current route is available for the Normal Monitor stereo output."
        }
        if transportName == "AirPlay" {
            return "AirPlay is active. Latency and Apple spatial behavior depend on the receiver."
        }
        if transportName == "Built-In" {
            return "Built-in output is active, so you are not monitoring on headphones."
        }
        if isAvailable {
            return "\(deviceName) is the verified system output."
        }
        return "No active macOS output route was verified."
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct InputRouteInfo: Equatable, Identifiable {
    let deviceID: AudioDeviceID
    let uid: String
    let deviceName: String
    let manufacturer: String
    let transportName: String
    let inputChannelCount: Int
    let nominalSampleRate: Double

    static let unavailable = InputRouteInfo(
        deviceID: 0,
        uid: "",
        deviceName: "No Active Input",
        manufacturer: "",
        transportName: "Unknown",
        inputChannelCount: 0,
        nominalSampleRate: 0
    )

    var id: String {
        uid.isEmpty ? "\(deviceID)" : uid
    }

    var isAvailable: Bool {
        deviceID != 0 && inputChannelCount > 0
    }

    var isBlackHole: Bool {
        role == .legacyBlackHole
    }

    var isRoonLoopback: Bool {
        role == .roonLoopback
    }

    var isAuxLoopback: Bool {
        role == .auxLoopback
    }

    var isSpotifyLoopback: Bool {
        role == .spotifyLoopback
    }

    var isOrbisonicLoopback: Bool {
        isRoonLoopback || isSpotifyLoopback || isAuxLoopback
    }

    var role: InputDeviceRole {
        if !isAvailable {
            return .unavailable
        }

        if let loopback = OrbisonicLoopbackDevice.allCases.first(where: { $0.deviceUID == uid }) {
            return loopback.inputRole
        }

        if normalized(deviceName).contains("blackhole") || normalized(manufacturer).contains("existential") {
            return .legacyBlackHole
        }

        if transportName == "Virtual" {
            return .otherVirtualInput
        }

        return .physicalInput
    }

    var displayName: String {
        isBlackHole ? deviceName : "\(deviceName)"
    }

    var detail: String {
        guard isAvailable else {
            return "No selected input device is available."
        }

        let rateText = nominalSampleRate > 0 ? String(format: "%.1f kHz", nominalSampleRate / 1_000) : "unknown rate"
        return "\(transportName) • \(inputChannelCount) ch • \(rateText)"
    }

    var roonReadiness: String {
        if isRoonLoopback {
            return "Ready for Roon through Orbisonic Roon Input. The system mic can stay selected in macOS."
        }
        if isAvailable {
            return "Selected input is \(deviceName). Choose Orbisonic Roon Input for Roon capture."
        }
        return "No selected input route is available for live capture."
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum OutputRouteMonitor {
    static func currentRoute() -> OutputRouteInfo {
        guard let deviceID = defaultOutputDeviceID() else {
            return .unavailable
        }

        return outputRoute(deviceID: deviceID) ?? .unavailable
    }

    static func availableOutputRoutes() -> [OutputRouteInfo] {
        let routes = deviceIDs()
            .compactMap(outputRoute(deviceID:))
            .filter(\.isAvailable)
        return OutputRouteSelectionPolicy.sortedOutputRoutes(routes)
    }

    static func outputRoute(uid: String) -> OutputRouteInfo? {
        guard !uid.isEmpty else { return nil }
        return availableOutputRoutes().first { $0.uid == uid }
    }

    static func outputRoute(deviceID: AudioDeviceID) -> OutputRouteInfo? {
        guard deviceID != 0 else { return nil }

        return OutputRouteInfo(
            deviceID: deviceID,
            uid: stringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                defaultValue: ""
            ),
            deviceName: stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                defaultValue: "Unknown Output"
            ),
            manufacturer: stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyManufacturer,
                defaultValue: ""
            ),
            transportName: transportName(for: transportType(of: deviceID)),
            outputChannelCount: channelCount(
                of: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            ),
            nominalSampleRate: nominalSampleRate(of: deviceID)
        )
    }

    static func currentInputRoute() -> InputRouteInfo {
        guard let deviceID = defaultInputDeviceID() else {
            return .unavailable
        }

        return inputRoute(deviceID: deviceID) ?? .unavailable
    }

    static func availableInputRoutes() -> [InputRouteInfo] {
        deviceIDs()
            .compactMap(inputRoute(deviceID:))
            .filter(\.isAvailable)
            .sorted { lhs, rhs in
                if lhs.isBlackHole != rhs.isBlackHole {
                    return lhs.isBlackHole
                }
                return lhs.deviceName.localizedStandardCompare(rhs.deviceName) == .orderedAscending
            }
    }

    static func inputRoute(uid: String) -> InputRouteInfo? {
        guard !uid.isEmpty else { return nil }
        return availableInputRoutes().first { $0.uid == uid }
    }

    static func inputRoute(deviceID: AudioDeviceID) -> InputRouteInfo? {
        guard deviceID != 0 else { return nil }

        let route = InputRouteInfo(
            deviceID: deviceID,
            uid: stringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                defaultValue: ""
            ),
            deviceName: stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                defaultValue: "Unknown Input"
            ),
            manufacturer: stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyManufacturer,
                defaultValue: ""
            ),
            transportName: transportName(for: transportType(of: deviceID)),
            inputChannelCount: channelCount(
                of: deviceID,
                scope: kAudioDevicePropertyScopeInput
            ),
            nominalSampleRate: nominalSampleRate(of: deviceID)
        )

        return route.isAvailable ? route : nil
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultInputDevice)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(selector: kAudioHardwarePropertyDevices)
        var propertySize: UInt32 = 0

        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )

        guard sizeStatus == noErr, propertySize > 0 else {
            return []
        }

        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.stride
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        let dataStatus = devices.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return OSStatus(kAudioHardwareBadObjectError)
            }

            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &propertySize,
                baseAddress
            )
        }

        guard dataStatus == noErr else {
            return []
        }

        return devices.filter { $0 != 0 }
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: String
    ) -> String {
        var address = propertyAddress(selector: selector, scope: scope)
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &propertySize,
                valuePointer
            )
        }

        guard status == noErr else {
            return defaultValue
        }

        guard let value else {
            return defaultValue
        }

        return value as String
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = propertyAddress(selector: kAudioDevicePropertyTransportType)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &value
        )

        guard status == noErr else {
            return 0
        }

        return value
    }

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double {
        var address = propertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
        var propertySize = UInt32(MemoryLayout<Float64>.size)
        var value = Float64(0)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &value
        )

        guard status == noErr else {
            return 0
        }

        return Double(value)
    }

    private static func channelCount(
        of deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: scope
        )
        var propertySize: UInt32 = 0

        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &propertySize
        )

        guard sizeStatus == noErr, propertySize > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            rawPointer
        )

        guard dataStatus == noErr else {
            return 0
        }

        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { partialResult, buffer in
            partialResult + Int(buffer.mNumberChannels)
        }
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private static func transportName(for transportType: UInt32) -> String {
        switch transportType {
        case UInt32(kAudioDeviceTransportTypeBuiltIn):
            "Built-In"
        case UInt32(kAudioDeviceTransportTypeBluetooth),
             UInt32(kAudioDeviceTransportTypeBluetoothLE):
            "Bluetooth"
        case UInt32(kAudioDeviceTransportTypeAirPlay):
            "AirPlay"
        case UInt32(kAudioDeviceTransportTypeAggregate):
            "Aggregate"
        case UInt32(kAudioDeviceTransportTypeVirtual):
            "Virtual"
        case UInt32(kAudioDeviceTransportTypeUSB):
            "USB"
        case UInt32(kAudioDeviceTransportTypeHDMI):
            "HDMI"
        case UInt32(kAudioDeviceTransportTypeDisplayPort):
            "DisplayPort"
        case UInt32(kAudioDeviceTransportTypeThunderbolt):
            "Thunderbolt"
        case UInt32(kAudioDeviceTransportTypePCI):
            "PCI"
        default:
            "Unknown"
        }
    }
}
