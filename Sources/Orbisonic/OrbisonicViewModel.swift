import AudioContracts
import AudioCore
import AudioImport
import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct ChannelMeter: Identifiable {
    let channel: SurroundChannel
    var level: Float
    var rawRMSDbFS: Float
    var peakDbFS: Float
    var vuDb: Float
    var isMeasured: Bool

    var id: String { channel.id }

    init(
        channel: SurroundChannel,
        level: Float,
        rawRMSDbFS: Float = MeterChannelLevel.silenceDbFS,
        peakDbFS: Float = MeterChannelLevel.silenceDbFS,
        vuDb: Float = MeterChannelLevel.silenceDbFS,
        isMeasured: Bool = true
    ) {
        self.channel = channel
        self.level = level
        self.rawRMSDbFS = rawRMSDbFS
        self.peakDbFS = peakDbFS
        self.vuDb = vuDb
        self.isMeasured = isMeasured
    }

    init(channel: SurroundChannel, meterLevel: MeterChannelLevel, isMeasured: Bool = true) {
        self.init(
            channel: channel,
            level: meterLevel.displayLevel,
            rawRMSDbFS: meterLevel.rawRMSDbFS,
            peakDbFS: meterLevel.peakDbFS,
            vuDb: meterLevel.vuDb,
            isMeasured: isMeasured
        )
    }
}

enum VUMeterActivityModel {
    static let visualDisplayFloor: Float = 0.0005
    static let minimumLevelPublishDelta: Float = 0.001

    static func hasRawSignal(_ levels: [MeterChannelLevel]) -> Bool {
        levels.contains { $0.peakDbFS > MeterChannelLevel.activePeakFloorDbFS }
    }

    static func hasVisualActivity(_ levels: [MeterChannelLevel], rawIsActive: Bool) -> Bool {
        rawIsActive || levels.contains { $0.displayLevel > visualDisplayFloor }
    }

    static func hasVisualActivity(_ levels: [Float]) -> Bool {
        levels.contains { $0 > visualDisplayFloor }
    }
}

enum PlaylistSortMode: String, CaseIterable, Identifiable {
    case name = "Name"
    case artist = "Artist"
    case album = "Album"

    var id: String { rawValue }
}

enum RendererMeterDisplayModel {
    static func channels(for scene: RendererSceneModel) -> [SurroundChannel] {
        var lfeCount = 0

        return scene.outputSpeakers.enumerated().map { offset, speaker in
            let role: SurroundChannelRole
            if speaker.isLFE {
                role = lfeCount == 0 ? .lfe : .lfe2
                lfeCount += 1
            } else {
                role = .discrete(offset)
            }

            return SurroundChannel(index: offset, role: role)
        }
    }

    static func levels(for scene: RendererSceneModel, sourceLevels: [Float]) -> [Float] {
        let channels = channels(for: scene)
        guard !channels.isEmpty else {
            return Array(repeating: 0, count: channels.count)
        }

        let levels = RendererMeterLevelModel.outputLevels(
            sourceLevels: sourceLevels,
            matrix: scene.matrix
        )
        return padded(levels, count: channels.count)
    }

    private static func padded(_ levels: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if levels.count == count { return levels }
        if levels.count > count { return Array(levels.prefix(count)) }
        return levels + Array(repeating: 0, count: count - levels.count)
    }
}

enum MonitorMeterDisplayModel {
    private static let activityFloor: Float = 0.005

    static func levels(tappedLevels: [Float], sourceLevels: [Float], channelCount: Int) -> [Float] {
        let tapped = padded(tappedLevels, count: channelCount)
        let source = padded(sourceLevels, count: channelCount)

        let hasTappedActivity = tapped.contains { $0 >= activityFloor }
        let hasSourceActivity = source.contains { $0 >= activityFloor }

        return hasTappedActivity || !hasSourceActivity ? tapped : source
    }

    private static func padded(_ levels: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if levels.count == count { return levels }
        if levels.count > count { return Array(levels.prefix(count)) }
        return levels + Array(repeating: 0, count: count - levels.count)
    }
}

private struct LocalFileQueueCommit {
    let index: Int
    let trackID: String
    let isNaturalAdvance: Bool
}

private enum LocalFileLoadStartPolicy {
    case immediate
    case debounced
}

private enum LocalFileLoadKind {
    case startingPlayback
    case selectedTrack
    case nextTrack
    case previousTrack
    case naturalAdvance

    func immediateStatus(trackTitle: String?, fileName: String) -> String {
        switch self {
        case .startingPlayback:
            return "Starting playback..."
        case .selectedTrack:
            return "Loading selected track: \(trackTitle ?? fileName)..."
        case .nextTrack:
            return "Loading next track: \(trackTitle ?? fileName)..."
        case .previousTrack:
            return "Loading previous track: \(trackTitle ?? fileName)..."
        case .naturalAdvance:
            return "Loading next track: \(trackTitle ?? fileName)..."
        }
    }

    func subtleStatus(trackTitle: String?, fileName: String) -> String {
        switch self {
        case .startingPlayback:
            return "Preparing local playback..."
        case .selectedTrack:
            return "Loading selected track..."
        case .nextTrack:
            return "Loading next track..."
        case .previousTrack:
            return "Loading previous track..."
        case .naturalAdvance:
            return "Loading next track..."
        }
    }

    func clearStatus(trackTitle: String?, fileName: String) -> String {
        "Loading large audio file: \(trackTitle ?? fileName)..."
    }

    var stillLoadingStatus: String {
        "Still loading."
    }
}

private struct LocalFileLoadRequest {
    let id: UInt64
    let generation: UInt64
    let url: URL
    let autoplay: Bool
    let queueCommit: LocalFileQueueCommit?
    let kind: LocalFileLoadKind
    let startPolicy: LocalFileLoadStartPolicy
    let debugTiming: DebugTimingContext?
    let requestedFromSource: SourceMode
    let isLocalPlayNow: Bool
}

private struct PreparedLocalFileKey: Equatable, Sendable {
    let path: String
    let fileSize: UInt64
    let modificationTime: TimeInterval

    static func make(for url: URL) -> PreparedLocalFileKey? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let fileSize = attributes[.size] as? NSNumber else { return nil }
            let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
            return PreparedLocalFileKey(
                path: url.path,
                fileSize: fileSize.uint64Value,
                modificationTime: modificationDate.timeIntervalSinceReferenceDate
            )
        } catch {
            return nil
        }
    }
}

private struct LocalPreparedFileCache {
    private struct Entry {
        let key: PreparedLocalFileKey
        let loaded: LoadedAudioFile
        let byteCount: Int
        let order: UInt64
    }

    private let capacity: Int
    private var maxBytes: Int
    private var entries: [String: Entry] = [:]
    private var order: UInt64 = 0
    private var totalBytes = 0

    init(capacity: Int, maxBytes: Int) {
        self.capacity = max(0, capacity)
        self.maxBytes = max(0, maxBytes)
    }

    mutating func updateMaxBytes(_ newValue: Int) {
        maxBytes = max(0, newValue)
        evictIfNeeded()
    }

    mutating func takeValid(for url: URL) -> LoadedAudioFile? {
        guard let entry = entries[url.path] else { return nil }
        guard PreparedLocalFileKey.make(for: url) == entry.key else {
            removeEntry(for: url.path)
            return nil
        }

        removeEntry(for: url.path)
        return entry.loaded
    }

    mutating func containsValid(for url: URL) -> Bool {
        guard let entry = entries[url.path] else { return false }
        guard PreparedLocalFileKey.make(for: url) == entry.key else {
            removeEntry(for: url.path)
            return false
        }
        return true
    }

    mutating func store(_ loaded: LoadedAudioFile, for url: URL, expectedKey: PreparedLocalFileKey) -> LocalPreparedFileCacheStoreResult {
        let byteCount = loaded.preparedPCMByteCount
        guard capacity > 0,
              maxBytes > 0
        else {
            logStoreDecision(fileName: url.lastPathComponent, byteCount: byteCount, result: .skipped(reason: "prepared cache disabled"))
            return .skipped(reason: "prepared cache disabled")
        }

        guard expectedKey.path == url.path,
              PreparedLocalFileKey.make(for: url) == expectedKey
        else {
            logStoreDecision(fileName: url.lastPathComponent, byteCount: byteCount, result: .skipped(reason: "file changed"))
            return .skipped(reason: "file changed")
        }

        guard byteCount > 0,
              byteCount <= maxBytes
        else {
            logStoreDecision(fileName: url.lastPathComponent, byteCount: byteCount, result: .skipped(reason: "prepared PCM exceeds cache budget"))
            return .skipped(reason: "prepared PCM exceeds cache budget")
        }

        order &+= 1
        removeEntry(for: url.path)
        entries[url.path] = Entry(key: expectedKey, loaded: loaded, byteCount: byteCount, order: order)
        totalBytes += byteCount
        evictIfNeeded()
        let result = LocalPreparedFileCacheStoreResult.stored
        logStoreDecision(fileName: url.lastPathComponent, byteCount: byteCount, result: result)
        return result
    }

    mutating func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    private mutating func removeEntry(for path: String) {
        guard let removed = entries.removeValue(forKey: path) else { return }
        totalBytes = max(totalBytes - removed.byteCount, 0)
    }

    private mutating func evictIfNeeded() {
        while entries.count > capacity || totalBytes > maxBytes {
            guard let evictedPath = entries.min(by: { $0.value.order < $1.value.order })?.key else { return }
            removeEntry(for: evictedPath)
        }
    }

    private func logStoreDecision(fileName: String, byteCount: Int, result: LocalPreparedFileCacheStoreResult) {
        AppLogger.shared.info(
            category: "local-music",
            "Prepared cache \(result.stored ? "accepted" : "skipped") file=\(fileName) preparedBytes=\(byteCount) totalBytes=\(totalBytes) maxBytes=\(maxBytes) capacity=\(capacity) reason=\"\(result.reason)\""
        )
    }
}

private enum LocalPreparedFileCacheStoreResult {
    case stored
    case skipped(reason: String)

    var stored: Bool {
        if case .stored = self { return true }
        return false
    }

    var reason: String {
        switch self {
        case .stored:
            return "stored"
        case .skipped(let reason):
            return reason
        }
    }
}

private struct LocalAudioDescriptorCache {
    private struct Entry {
        let key: PreparedLocalFileKey
        let descriptor: AudioAssetDescriptor
        let order: UInt64
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var order: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    mutating func descriptor(for url: URL) -> AudioAssetDescriptor? {
        guard let entry = entries[url.path] else { return nil }
        guard PreparedLocalFileKey.make(for: url) == entry.key else {
            removeEntry(for: url.path)
            return nil
        }
        return entry.descriptor
    }

    mutating func containsValid(for url: URL) -> Bool {
        descriptor(for: url) != nil
    }

    mutating func store(
        _ descriptor: AudioAssetDescriptor,
        for url: URL,
        expectedKey: PreparedLocalFileKey
    ) -> LocalPreparedFileCacheStoreResult {
        guard capacity > 0 else { return .skipped(reason: "descriptor cache disabled") }
        guard expectedKey.path == url.path,
              PreparedLocalFileKey.make(for: url) == expectedKey
        else { return .skipped(reason: "file changed") }

        order &+= 1
        entries[url.path] = Entry(key: expectedKey, descriptor: descriptor, order: order)
        evictIfNeeded()
        return .stored
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    private mutating func removeEntry(for path: String) {
        entries.removeValue(forKey: path)
    }

    private mutating func evictIfNeeded() {
        while entries.count > capacity {
            guard let evictedPath = entries.min(by: { $0.value.order < $1.value.order })?.key else { return }
            removeEntry(for: evictedPath)
        }
    }
}

enum LiveChannelCountPolicy {
    static let roonSupportedCounts = [2, 4, 6, 8]

    static func availableCounts(sourceMode: SourceMode, availableInputChannels: Int) -> [Int] {
        if let fixedCount = sourceMode.fixedLiveChannelCount {
            return [fixedCount]
        }

        if sourceMode == .roon {
            let available = min(max(availableInputChannels, 0), roonSupportedCounts.last ?? 8)
            let supported = roonSupportedCounts.filter { $0 <= available }
            return supported.isEmpty ? [2] : supported
        }

        let available = min(max(availableInputChannels, 0), OrbisonicAudioLimits.maxSourceChannelCount)
        guard available > 0 else {
            return [2, 4, 6, 8]
        }

        let supported = RendererRenderMode.supportedInputCounts.filter { $0 <= available }
        if supported.contains(available) {
            return supported
        }

        return supported.isEmpty ? [min(available, 2)] : supported
    }

    static func preferredCount(sourceMode: SourceMode, availableInputChannels: Int, activeCount: Int) -> Int {
        if let fixedCount = sourceMode.fixedLiveChannelCount {
            return fixedCount
        }

        let available = availableCounts(sourceMode: sourceMode, availableInputChannels: availableInputChannels)
        if available.contains(activeCount) {
            return activeCount
        }

        return available.contains(2) ? 2 : (available.first ?? 2)
    }
}

struct SpotifySourceHealthLine: Identifiable, Equatable {
    let title: String
    let value: String

    var id: String { title }
}

private struct DiagnosticReturnContext {
    let sourceMode: SourceMode
    let wasPlaying: Bool
    let progress: Double
    let hadSource: Bool
}

private enum DiagnosticChannelWalkKind {
    case monitor
    case renderer

    var title: String {
        switch self {
        case .monitor:
            "Output 1 Local Speakers Channel Walk"
        case .renderer:
            "Output 2 Renderer Channel Walk"
        }
    }

    var shortTitle: String {
        switch self {
        case .monitor:
            "Output 1 Local speakers"
        case .renderer:
            "Output 2 Renderer"
        }
    }
}

struct DiagnosticEvent: Equatable {
    let message: String
    let timestamp: Date
}

struct DiagnosticToneActivitySummary: Equatable {
    let isActive: Bool
    let headline: String
    let detail: String

    static let idle = DiagnosticToneActivitySummary(
        isActive: false,
        headline: "No diagnostic tone active",
        detail: "Tone meters are muted until a diagnostic tone or channel walk starts."
    )
}

@MainActor
final class ChannelMeterStore: ObservableObject {
    @Published private(set) var channelMeters: [ChannelMeter] = []
    @Published private(set) var isActive = false

    func configure(channels: [SurroundChannel]) {
        isActive = false
        channelMeters = channels.map { ChannelMeter(channel: $0, level: 0) }
    }

    func configureIfNeeded(channels: [SurroundChannel]) {
        let currentIDs = channelMeters.map(\.id)
        let nextIDs = channels.map(\.id)
        guard currentIDs != nextIDs else { return }

        configure(channels: channels)
    }

    func reset() {
        isActive = false
        channelMeters = channelMeters.map { ChannelMeter(channel: $0.channel, level: 0) }
    }

    func update(with nextLevels: [Float]) {
        guard nextLevels.count == channelMeters.count else { return }
        isActive = VUMeterActivityModel.hasVisualActivity(nextLevels)

        let updated = zip(channelMeters, nextLevels).map { current, next in
            ChannelMeter(channel: current.channel, level: next)
        }

        let shouldPublish = zip(channelMeters, updated).contains {
            abs($0.level - $1.level) >= VUMeterActivityModel.minimumLevelPublishDelta
                || ($0.level > VUMeterActivityModel.visualDisplayFloor) != ($1.level > VUMeterActivityModel.visualDisplayFloor)
        }

        if shouldPublish {
            channelMeters = updated
        }
    }

    func update(with meterLevels: [MeterChannelLevel], isActive: Bool) {
        guard meterLevels.count == channelMeters.count else { return }
        let visualIsActive = VUMeterActivityModel.hasVisualActivity(meterLevels, rawIsActive: isActive)
        self.isActive = visualIsActive

        let updated = zip(channelMeters, meterLevels).map { current, next in
            ChannelMeter(channel: current.channel, meterLevel: next, isMeasured: visualIsActive)
        }

        let shouldPublish = zip(channelMeters, updated).contains {
            abs($0.level - $1.level) >= VUMeterActivityModel.minimumLevelPublishDelta
                || ($0.level > VUMeterActivityModel.visualDisplayFloor) != ($1.level > VUMeterActivityModel.visualDisplayFloor)
                || abs($0.rawRMSDbFS - $1.rawRMSDbFS) >= 0.1
                || $0.isMeasured != $1.isMeasured
        }

        if shouldPublish {
            channelMeters = updated
        }
    }
}

enum DiagnosticMonitorDownmixMeterModel {
    static func levels(from rendererLevels: [Float], monitorChannelCount: Int) -> [Float] {
        guard monitorChannelCount > 0 else { return [] }
        let activeLevel = rendererLevels.max() ?? 0
        return Array(repeating: activeLevel, count: monitorChannelCount)
    }
}

struct DiagnosticChannelPlaybackOptions: Equatable {
    let monitorDownmix: Bool
    let primaryOutputEnabled: Bool
}

enum DiagnosticChannelPlaybackPolicy {
    static func options(
        targetsRenderer: Bool,
        rendererMonitorDownmixAvailable: Bool,
        rendererUsesNormalMonitor: Bool
    ) -> DiagnosticChannelPlaybackOptions {
        _ = targetsRenderer
        _ = rendererMonitorDownmixAvailable
        _ = rendererUsesNormalMonitor
        return DiagnosticChannelPlaybackOptions(
            monitorDownmix: false,
            primaryOutputEnabled: true
        )
    }
}

private enum OutputPurpose: Equatable {
    case monitor
    case renderer

    var title: String {
        switch self {
        case .monitor:
            "Output 1 Monitor"
        case .renderer:
            "Output 2 Renderer"
        }
    }

    var lowerTitle: String {
        title.lowercased()
    }
}

@MainActor
final class OrbisonicViewModel: ObservableObject {
    private static let selectedInputDeviceUIDKey = "Orbisonic.selectedInputDeviceUID"
    private static let selectedMonitorOutputModeKey = "Orbisonic.selectedMonitorOutputMode"
    private static let selectedRendererOutputModeKey = "Orbisonic.selectedRendererOutputMode"
    private static let appleSpatialHeadphonesEnabledKey = "Orbisonic.appleSpatialHeadphonesEnabled"
    private static let rendererRenderModeKey = "Orbisonic.rendererRenderMode"
    private static let rendererAlwaysMonoKey = "Orbisonic.rendererAlwaysMono"
    private static let rendererTwoChannelPreferenceKey = "Orbisonic.rendererTwoChannelPreference"
    private static let legacySelectedOutputDeviceUIDKey = "Orbisonic.selectedOutputDeviceUID"
    private static let roonLogRefreshInterval: TimeInterval = 5.0
    private static let roonBridgeRefreshInterval: TimeInterval = 2.0
    private static let spotifyNowPlayingRefreshInterval: TimeInterval = 0.5
    private static let spotifyPlaybackStatusDebounceNanoseconds: UInt64 = 300_000_000
    private static let spotifyConnectRestartDebounce: TimeInterval = 8.0
    private static let roonArtworkRetryCooldown: TimeInterval = 15.0
    private static let localTransportDebounceNanoseconds: UInt64 = 120_000_000
    private static let localLoadSubtleStatusNanoseconds: UInt64 = 150_000_000
    private static let localLoadClearStatusNanoseconds: UInt64 = 700_000_000
    private static let localLoadStillLoadingNanoseconds: UInt64 = 5_000_000_000
    private static let enableAdjacentLocalPCMPreload = false
    private static let enableAdjacentLocalMetadataPreload = true
    private static let enableStreamingLocalPlayback = StreamingLocalPlaybackPolicy.enableStreamingLocalPlayback
    private static let maxAdjacentMetadataPreloadCount = 2
    private static let maxAdjacentMetadataCacheEntries = 16
    private static let maxFullPreparedPCMBytes = PreparedPCMPolicy.maxFullPreparedPCMBytes
    private static let maxAdjacentFullPreloadPCMBytes = PreparedPCMPolicy.maxAdjacentFullPreloadPCMBytes
    private static let nextTrackPreloadAvailableRAMFraction = 0.5
    private static let maxPreparedCacheEntries = PreparedPCMPolicy.maxPreparedCacheEntries
    private static let maxPreparedCacheBytes = PreparedPCMPolicy.maxPreparedCacheBytes
    private static let diagnosticsLogTailMaxBytes = 256 * 1024
    private static let diagnosticsLogMaxLines = 500
    private static let webControlTokenKey = "Orbisonic.webControlToken"
    private static let localMusicSortModeKey = "Orbisonic.localMusicSortMode"
    private static let atmosDRPOutputLayoutKey = "Orbisonic.atmosDRPOutputLayout"
    private static let rendererOptionsKey = "Orbisonic.rendererOptions"
    private static let frontAngleKey = "Orbisonic.frontAngle"
    private static let rearAngleKey = "Orbisonic.rearAngle"
    private static let sphereOutputVolumeKey = "Orbisonic.sphereOutputVolumePercent"
    private static let sphereOutputSafetyLimitKey = "Orbisonic.sphereOutputSafetyLimitPercent"
    private static let preloadNextTrackEnabledKey = "Orbisonic.preloadNextTrackEnabled"
    private static let diagnosticSpeakerChannelCount = 31
    private static let sourceRampDownDuration: TimeInterval = 0.04
    private static let sourcePrimeDuration: TimeInterval = 0.08
    private static let sourceRampUpDuration: TimeInterval = 0.08
    private static let localPlayNowSourceSwitchTimeout: TimeInterval = 2.0
    private static let liveSignalThreshold: Float = 0.005
    private static let liveSignalStartupGraceSeconds = 3
    private static let liveSignalBriefSilenceSeconds = 2
    private static let liveSignalNoSignalSeconds = 15
    private static let isRunningUnitTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
            NSClassFromString("XCTest.XCTestCase") != nil ||
            NSClassFromString("XCTestCase") != nil
    }()

    private struct RouteRefreshSnapshot {
        let systemOutputRoute: OutputRouteInfo
        let availableOutputRoutes: [OutputRouteInfo]
        let availableInputRoutes: [InputRouteInfo]
        let systemInputRoute: InputRouteInfo
    }

    private static var preloadsAdjacentLocalMusicTracksByDefault: Bool {
        enableAdjacentLocalPCMPreload && !isRunningUnitTests
    }

    private static var preloadsAdjacentLocalMetadataByDefault: Bool {
        enableAdjacentLocalMetadataPreload && !isRunningUnitTests
    }

    @Published var preloadNextTrackEnabled: Bool = OrbisonicViewModel.loadBool(
        key: OrbisonicViewModel.preloadNextTrackEnabledKey,
        defaultValue: false
    ) {
        didSet {
            guard preloadNextTrackEnabled != oldValue else { return }
            UserDefaults.standard.set(preloadNextTrackEnabled, forKey: Self.preloadNextTrackEnabledKey)
            if preloadNextTrackEnabled {
                localPreparedFileCache.updateMaxBytes(systemMemoryProvider.snapshot().totalBytes)
                scheduleAdjacentLocalFilePreloads(reason: "next-track preload enabled")
            } else {
                cancelLocalPreparedFilePreload(reason: "next-track preload disabled")
                localPreparedFileCache.removeAll()
                localPreparedFileCache.updateMaxBytes(Self.maxPreparedCacheBytes)
                nextTrackPreloadStatus = .idle
            }
        }
    }
    @Published private(set) var nextTrackPreloadStatus: NextTrackPreloadStatus = .idle
    @Published var preset: SpatialPreset = .defaultPreset {
        didSet {
            applyPreset(preset)
        }
    }

    @Published private(set) var rendererPresets: [RendererPreset] = [.sonicSphere30Point1]
    @Published private(set) var rendererPreset: RendererPreset = .sonicSphere30Point1
    @Published private(set) var rendererRenderMode: RendererRenderMode = OrbisonicViewModel.loadRendererRenderMode()
    @Published var rendererAlwaysMono: Bool = OrbisonicViewModel.loadBool(
        key: OrbisonicViewModel.rendererAlwaysMonoKey,
        defaultValue: false
    ) {
        didSet {
            UserDefaults.standard.set(rendererAlwaysMono, forKey: Self.rendererAlwaysMonoKey)
            applyRendererModePolicyChange(reason: "always mono changed")
        }
    }
    @Published var rendererTwoChannelPreference: RendererTwoChannelPreference = OrbisonicViewModel.loadRendererTwoChannelPreference() {
        didSet {
            UserDefaults.standard.set(rendererTwoChannelPreference.rawValue, forKey: Self.rendererTwoChannelPreferenceKey)
            applyRendererModePolicyChange(reason: "two-channel preference changed")
        }
    }
    @Published var rendererSeamSupportGain = RendererPreset.sonicSphere30Point1.options.seamSupportGain { didSet { publishRendererOptions() } }
    @Published var rendererUpperBiasDbPerUnitZ = RendererPreset.sonicSphere30Point1.options.upperBiasDbPerUnitZ { didSet { publishRendererOptions() } }
    @Published var rendererStereoRearFill = RendererPreset.sonicSphere30Point1.options.stereoRearFill { didSet { publishRendererOptions() } }
    @Published var rendererCenterSideSupportGain = RendererPreset.sonicSphere30Point1.options.centerSideSupportGain { didSet { publishRendererOptions() } }
    @Published var rendererAdjacentBleed = RendererPreset.sonicSphere30Point1.options.adjacentBleed { didSet { publishRendererOptions() } }
    @Published var rendererMaxSingleSpeakerPowerShare = RendererPreset.sonicSphere30Point1.options.maxSingleSpeakerPowerShare { didSet { publishRendererOptions() } }
    @Published var rendererRenderedOutputTrimDb = RendererPreset.sonicSphere30Point1.options.renderedOutputTrimDb { didSet { publishRendererOptions() } }
    @Published var rendererLfeTrimDb = RendererPreset.sonicSphere30Point1.options.lfeTrimDb { didSet { publishRendererOptions() } }
    @Published var rendererAuroLowerUpperBiasDbPerUnitZ = RendererPreset.sonicSphere30Point1.options.defaultUpperBiasDbPerUnitZ { didSet { publishRendererOptions() } }
    @Published var rendererAuroHeightUpperBiasDbPerUnitZ = RendererPreset.sonicSphere30Point1.options.heightUpperBiasDbPerUnitZ { didSet { publishRendererOptions() } }
    @Published var rendererAuroHeightMaxSingleSpeakerPowerShare = RendererPreset.sonicSphere30Point1.options.heightMaxSingleSpeakerPowerShare { didSet { publishRendererOptions() } }
    @Published var rendererAuroTopMaxSingleSpeakerPowerShare = RendererPreset.sonicSphere30Point1.options.topMaxSingleSpeakerPowerShare { didSet { publishRendererOptions() } }
    @Published var rendererFiveOneChannelOrder = RendererPreset.sonicSphere30Point1.options.fiveOneChannelOrder { didSet { publishRendererOptions() } }
    @Published private(set) var rendererScene: RendererSceneModel = .empty
    @Published private(set) var rendererPresetStatus = "Renderer presets have not loaded yet."
    @Published private(set) var rendererPresetDirectoryText = ""
    @Published private(set) var rendererPresetIsDirty = false

    @Published var frontAngle: Double = OrbisonicViewModel.loadDouble(
        key: OrbisonicViewModel.frontAngleKey,
        defaultValue: SpatialTuning.default.frontAngle
    ) {
        didSet {
            guard !suppressTuningPublish else { return }
            persistDouble(frontAngle, key: Self.frontAngleKey, category: "tuning", name: "Front Angle")
            publishTuning()
        }
    }

    @Published var rearAngle: Double = OrbisonicViewModel.loadDouble(
        key: OrbisonicViewModel.rearAngleKey,
        defaultValue: SpatialTuning.default.rearAngle
    ) {
        didSet {
            guard !suppressTuningPublish else { return }
            persistDouble(rearAngle, key: Self.rearAngleKey, category: "tuning", name: "Rear Angle")
            publishTuning()
        }
    }

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var scrubProgress: Double = 0
    @Published var isScrubbing = false
    @Published var sourceMetadata: AudioSourceMetadata?
    @Published private(set) var pendingLocalSourceMetadata: AudioSourceMetadata?
    @Published private(set) var pendingLocalAssetDescriptor: AudioAssetDescriptor?
    @Published var loadedChannels: [SurroundChannel] = []
    @Published var statusMessage = "Load a surround file. The active macOS output route will appear below."
    @Published var loadedFileName = "No file loaded"
    @Published private(set) var currentFileURL: URL?
    @Published private(set) var pureSphericalLosslessState: PureSphericalLosslessState = .none
    @Published var lastError: String? {
        didSet {
            if let lastError {
                controlLastError = lastError
                lastErrorEvent = DiagnosticEvent(message: lastError, timestamp: Date())
            }
        }
    }
    @Published private(set) var lastErrorEvent: DiagnosticEvent?
    @Published private(set) var lastRecoveryEvent: DiagnosticEvent?
    @Published private(set) var controlLastError: String?
    @Published private(set) var outputRoute: OutputRouteInfo = .unavailable
    @Published private(set) var monitorOutputRoute: OutputRouteInfo = .unavailable
    @Published private(set) var rendererOutputRoute: OutputRouteInfo = .unavailable
    @Published private(set) var systemOutputRoute: OutputRouteInfo = .unavailable
    @Published private(set) var availableOutputRoutes: [OutputRouteInfo] = []
    @Published private(set) var appleSpatialHeadphonesEnabled = false
    @Published private(set) var appleSpatialHeadphoneMonitorStatus = DesktopMonitorModeStatus.referenceStereo()
    @Published private(set) var inputRoute: InputRouteInfo = .unavailable
    @Published private(set) var systemInputRoute: InputRouteInfo = .unavailable
    @Published private(set) var availableInputRoutes: [InputRouteInfo] = []
    @Published var sourceMode: SourceMode = .filePlayback
    @Published private(set) var liveMonitorState: LiveMonitorState = .stopped
    @Published private(set) var liveAudioSignalState: LiveAudioSignalState = .unknown
    @Published private(set) var liveAudioSignalSilenceDuration: Int?
    @Published var activeLiveChannelCount = 2
    @Published var liveSignalStatus = "No live input."
    @Published var liveBufferStatus = "No live buffer."
    @Published private(set) var livePipeStatus: LiveAudioPipeStatus?
    @Published private(set) var lastLiveUnderflowAt: Date?
    @Published var selectedTestTonePoint: TestTonePipelinePoint = .directOutput
    @Published var isTestTonePlaying = false
    @Published var testToneStatus = ""
    @Published private(set) var isDiagnosticTransitioning = false
    @Published private(set) var selectedDiagnosticSpeakerChannel = 1
    @Published var diagnosticWalkStatus = "Ready."
    @Published var activeDiagnosticPoint: TestTonePipelinePoint?
    @Published var activeDiagnosticChannelIndex: Int?
    @Published var activeDiagnosticChannelCount = 0
    @Published var activeDiagnosticWalkTitle = ""
    @Published var diagnosticSequencePosition = 0
    @Published var isDiagnosticSequencePlaying = false
    @Published private(set) var lastDiagnosticFailure: DiagnosticEvent?
    @Published private(set) var roonNowPlaying: RoonNowPlaying?
    @Published private(set) var roonNowPlayingStatus = "Roon metadata not requested yet."
    @Published private(set) var roonSignalPath: RoonSignalPath?
    @Published private(set) var roonBridgeSnapshot: RoonBridgeSnapshot = .unavailable
    @Published private(set) var roonArtworkURL: URL?
    @Published private(set) var spotifyReceiverStatus: SpotifyReceiverStatus = .notStarted
    @Published private(set) var spotifyNowPlaying: SpotifyNowPlaying?
    @Published private(set) var spotifyVisibleNowPlaying: SpotifyNowPlaying?
    @Published private(set) var dolbyReferencePlayerSnapshot: DolbyReferencePlayerControllerSnapshot = .idle
    @Published private(set) var currentAtmosDRPTrack: LocalMusicTrack?
    @Published private(set) var localMusicSettings = LocalMusicSettings()
    @Published private(set) var localMusicTracks: [LocalMusicTrack] = [] {
        didSet { invalidateSortedLocalMusicTracksCache() }
    }
    @Published private(set) var localMusicPlaylists: [LocalMusicPlaylist] = []
    @Published var selectedLibraryTrackID: String?
    @Published var selectedLocalMusicPlaylistID: String?
    @Published var localMusicSearchText = ""
    @Published var localMusicSortMode: PlaylistSortMode = OrbisonicViewModel.loadLocalMusicSortMode() {
        didSet {
            invalidateSortedLocalMusicTracksCache()
            UserDefaults.standard.set(localMusicSortMode.rawValue, forKey: Self.localMusicSortModeKey)
            AppLogger.shared.notice(category: "local-music", "Sort mode set to \(localMusicSortMode.rawValue)")
        }
    }
    @Published var localMusicChannelFilter: Int = 0 {
        didSet {
            guard oldValue != localMusicChannelFilter else { return }
            AppLogger.shared.notice(category: "local-music", "Channel filter set to \(localMusicChannelFilter)")
        }
    }
    @Published var atmosDRPOutputLayout: DolbyReferencePlayerOutputLayout = OrbisonicViewModel.loadAtmosDRPOutputLayout() {
        didSet {
            UserDefaults.standard.set(atmosDRPOutputLayout.rawValue, forKey: Self.atmosDRPOutputLayoutKey)
            AppLogger.shared.notice(category: "atmos-drp", "Atmos DRP output layout set to \(atmosDRPOutputLayout.rawValue)")
        }
    }
    @Published var isLocalGaplessSchedulerEnabled: Bool = LocalGaplessPlaybackPolicy.enableLocalGaplessScheduler {
        didSet {
            guard oldValue != isLocalGaplessSchedulerEnabled else { return }
            LocalGaplessPlaybackPolicy.setEnableLocalGaplessScheduler(isLocalGaplessSchedulerEnabled)
            AppLogger.shared.notice(
                category: LocalGaplessSchedulerLog.category,
                "Local gapless scheduler preference set to \(isLocalGaplessSchedulerEnabled ? "enabled" : "disabled")"
            )
            if !isLocalGaplessSchedulerEnabled, isLocalGaplessEngineQueueActive {
                stop()
                statusMessage = "Local gapless playback is off. Restart the local queue to use the fallback path."
            } else {
                statusMessage = isLocalGaplessSchedulerEnabled
                    ? "Local gapless playback is on for compatible local queues."
                    : "Local gapless playback is off. Local files use the fallback path."
            }
        }
    }
    @Published var isLocalGaplessCompressedTrimEnabled: Bool = LocalGaplessPlaybackPolicy.localGaplessEnableCompressedTrim {
        didSet {
            guard oldValue != isLocalGaplessCompressedTrimEnabled else { return }
            LocalGaplessPlaybackPolicy.setLocalGaplessEnableCompressedTrim(isLocalGaplessCompressedTrimEnabled)
            AppLogger.shared.notice(
                category: LocalGaplessSchedulerLog.category,
                "Local gapless compressed trim preference set to \(isLocalGaplessCompressedTrimEnabled ? "enabled" : "disabled")"
            )
            statusMessage = isLocalGaplessCompressedTrimEnabled
                ? "Compressed gapless trim is on for future local gapless playback."
                : "Compressed gapless trim is off for future local gapless playback."
        }
    }
    @Published private(set) var sessionQueue: [LocalMusicTrack] = []
    @Published private(set) var sessionQueueIndex: Int?
    @Published private(set) var selectedSessionQueueIndex: Int?
    @Published private(set) var pendingSessionQueueIndex: Int?
    @Published var isShuffleEnabled = false
    @Published private(set) var webServerStatus = "Web server starting."
    @Published private(set) var webPublicPageURL = ""
    @Published private(set) var webControlPageURL = ""
    @Published private(set) var lastDiagnosticExportResult: String?
    @Published private(set) var recentWarningAndErrorLogSnippets: [String] = []
    @Published private(set) var isLoadingRecentLogSnippets = false
    @Published private(set) var recentLogSnippetStatus = "Open Logs / Support to load recent warning and error lines."
    @Published var sphereOutputVolumePercent: Double = OrbisonicViewModel.loadDouble(
        key: OrbisonicViewModel.sphereOutputVolumeKey,
        defaultValue: 100
    ) {
        didSet { updateSphereOutputVolume(settingName: "Sphere Volume", key: Self.sphereOutputVolumeKey) }
    }
    @Published var sphereOutputSafetyLimitPercent: Double = OrbisonicViewModel.loadDouble(
        key: OrbisonicViewModel.sphereOutputSafetyLimitKey,
        defaultValue: 100
    ) {
        didSet { updateSphereOutputVolume(settingName: "Max Output Safety Limit", key: Self.sphereOutputSafetyLimitKey) }
    }
    @Published private(set) var isRoonTransportCommandInFlight = false
    @Published private(set) var isLiveMonitorTransitioning = false
    @Published private(set) var sourceSwitchTargetMode: SourceMode?
    @Published private(set) var isLocalFileLoading = false {
        didSet {
            if !isLocalFileLoading { endLoadActivityIfLoading() }
        }
    }
    @Published private(set) var activity: PlaybackActivity = .idle

    /// Output device currently being pushed to CoreAudio by an in-flight
    /// async apply, if any. Guards against overlapping device switches.
    private var outputDeviceApplyInFlightID: AudioDeviceID?
    /// Last output device id successfully applied via the async refresh path.
    private var lastAppliedOutputDeviceID: AudioDeviceID = 0

    let meterStore = ChannelMeterStore()
    let monitorMeterStore = ChannelMeterStore()
    let rendererMeterStore = ChannelMeterStore()
    @Published private(set) var sonicSphereMeterActive = false

    private let engine: OrbisonicEngine
    private let localAudioLoader: @Sendable (URL, DebugTimingContext?) throws -> LoadedAudioFile
    private let localMusicLibrary: LocalMusicLibrary
    private var localMusicBaseTracks: [LocalMusicTrack] = []
    private var localMusicMetadataOverlays: [String: LocalMusicMetadataOverlay] = [:]
    private var localMusicMetadataScannedTrackIDs: Set<String> = []
    private var localMusicMetadataEnricher: LocalMusicMetadataEnriching?
    private let preloadsFirstLocalMusicTrack: Bool
    private let preloadsAdjacentLocalMusicTracks: Bool
    private let preloadsAdjacentLocalMetadata: Bool
    private let adjacentFullPreloadPCMByteLimit: Int
    private let systemMemoryProvider: SystemMemoryProviding
    private let rendererPresetStore = RendererPresetStore()
    private let roonNowPlayingReader = RoonNowPlayingReader()
    private let roonBridgeClient = RoonBridgeClient()
    private let roonArtworkCache = RoonArtworkCache()
    private let spotifyReceiverClient = SpotifyReceiverClient()
    private let dolbyReferencePlayerController = DolbyReferencePlayerController()
    private let diagnosticsLogStore = DiagnosticsLogStore()
    private let appleSpatialHeadphoneMonitor = AppleSpatialHeadphoneMonitor()
    private let pureSphericalLosslessValidator = PureSphericalLosslessValidator()
    private var webServer: OrbisonicWebServer?
    private var webControlToken = OrbisonicViewModel.loadOrCreateWebControlToken()
    private var refreshTimer: Timer?
    private var lastHeartbeatSecond: Int = -1
    private var lastLiveMeterLogSecond: Int = -1
    private var lastLiveBufferLogSecond: Int = -1
    private var lastLiveUnderflowCount = 0
    private var lastLiveSilenceWarningSecond: Int = -1
    private var lastLiveSignalPresent: Bool?
    private var lastLiveSignalDetectedSecond: Int?
    private var testToneStopTask: Task<Void, Never>?
    private var diagnosticSequenceTask: Task<Void, Never>?
    private var diagnosticsLogRefreshTask: Task<Void, Never>?
    private var hasLoadedRecentLogSnippets = false
    private var sourceSwitchTask: Task<Void, Never>?
    private var sourceSwitchRequests = SourceSwitchRequestState()
    private var transitionOutputGain: Float = 1
    private var diagnosticReturnContext: DiagnosticReturnContext?
    private var rendererDiagnosticsUsingNormalMonitor = false
    private var rendererDiagnosticsMonitorDownmixAvailable = false
    private var localMusicScanTask: Task<Void, Never>?
    private var localMusicMetadataEnrichmentTask: Task<Void, Never>?
    private var localMusicMatroskaRepairTask: Task<Void, Never>?
    private var localPlayNowTask: Task<Void, Never>?
    private var localPlayNowSequence: UInt64 = 0
    private var localFileLoadTask: Task<Void, Never>?
    private var localFileDecodeTask: Task<LoadedAudioFile, Error>?
    private var localFileDecodeRequestID: UInt64?
    private var localFileLoadDebounceTask: Task<Void, Never>?
    private var localFileLoadStatusTask: Task<Void, Never>?
    private var localPreparedFilePreloadTask: Task<Void, Never>?
    private var localPreparedFilePreloadDecodeTask: Task<LoadedAudioFile, Error>?
    private var localMetadataPreloadTask: Task<Void, Never>?
    private var localPreparedFilePreloadDecodeSequence: UInt64 = 0
    private var localPreparedFilePreloadDecodeID: UInt64?
    private var spotifyPlaybackStatusDebounceTask: Task<Void, Never>?
    private var localPreparedFileCache: LocalPreparedFileCache
    private var localAudioDescriptorCache: LocalAudioDescriptorCache
    private var didLogAdjacentLocalPCMPreloadDisabled = false
    private var localFileLoadSequence: UInt64 = 0
    private var currentLocalFileLoadGeneration: UInt64 = 0
    private var pendingLocalPresentationGeneration: UInt64?
    private var isLocalGaplessEngineQueueActive = false
    private var localGaplessQueueEndAwaitingPlaybackEnded = false
    private var finalizedLocalGaplessQueueIndices: Set<Int> = []
    private var activeLocalFileLoadRequest: LocalFileLoadRequest?
    private var queuedLocalFileLoadRequest: LocalFileLoadRequest?
    private var readyQueuedLocalFileLoadGeneration: UInt64?
    private var pendingSourceSwitchTiming: DebugTimingContext?
    private var pendingSourceSwitchReason: String?
    private var pendingSourceSwitchRequestedBy: String?
    private var mainActorHeartbeatTask: Task<Void, Never>?
    private var lastRouteRefreshTime = Date.distantPast
    private var routeRefreshTask: Task<Void, Never>?
    private var isRouteRefreshInFlight = false
    private var hasPendingForcedRouteRefresh = false
    private var lastRoonNowPlayingRefreshTime = Date.distantPast
    private var lastRoonBridgeRefreshTime = Date.distantPast
    private var lastSpotifyNowPlayingRefreshTime = Date.distantPast
    private var lastSpotifyConnectRefreshTime = Date.distantPast
    private var lastLegacyLoopbackSampleRateRepairTime = Date.distantPast
    private var isRoonLogRefreshInFlight = false
    private var isRoonBridgeRefreshInFlight = false
    private var lastLoggedRoonBridgeStatus: String?
    private var roonArtworkFetchTask: Task<Void, Never>?
    private var roonArtworkRequestedKey: String?
    private var roonArtworkFailedKeys: Set<String> = []
    private var roonArtworkRetryAfter: [String: Date] = [:]
    private var lastLoggedRoonArtworkMissingSignature: String?
    private var lastLoggedRoonArtworkCapabilitySignature: String?
    private var lastLoggedSpotifyStatusSignature: String?
    var lastLoggedInputSourceStatusSignature: String?
    private var selectedInputDeviceUID = UserDefaults.standard.string(forKey: OrbisonicViewModel.selectedInputDeviceUIDKey)
    private var monitorOutputSelection = OrbisonicViewModel.loadMonitorOutputSelection()
    private var rendererOutputSelection = OrbisonicViewModel.loadRendererOutputSelection()
    private var shouldNormalizeStartupMonitorOutputSelection = true
    private var suppressTuningPublish = false
    private var suppressRendererPublish = false

    init() {
        self.engine = OrbisonicEngine(audioGraphEnabled: !Self.isRunningUnitTests)
        self.localAudioLoader = { url, debugTiming in
            try AudioFileLoader().load(url: url, debugTiming: debugTiming)
        }
        self.localMusicLibrary = LocalMusicLibrary()
        self.preloadsFirstLocalMusicTrack = !Self.isRunningUnitTests
        self.preloadsAdjacentLocalMusicTracks = Self.preloadsAdjacentLocalMusicTracksByDefault
        self.preloadsAdjacentLocalMetadata = Self.preloadsAdjacentLocalMetadataByDefault
        self.adjacentFullPreloadPCMByteLimit = Self.maxAdjacentFullPreloadPCMBytes
        self.systemMemoryProvider = HostSystemMemoryProvider()
        self.localPreparedFileCache = LocalPreparedFileCache(
            capacity: Self.maxPreparedCacheEntries,
            maxBytes: Self.maxPreparedCacheBytes
        )
        self.localAudioDescriptorCache = LocalAudioDescriptorCache(capacity: Self.maxAdjacentMetadataCacheEntries)
        self.localMusicMetadataEnricher = Self.isRunningUnitTests ? nil : LocalMusicMetadataEnricher(library: localMusicLibrary)
        finishInitialization()
    }

    init(
        localAudioLoader: @escaping @Sendable (URL) throws -> LoadedAudioFile,
        localMusicLibrary: LocalMusicLibrary = LocalMusicLibrary(),
        localMusicMetadataEnricher: LocalMusicMetadataEnriching? = nil,
        preloadFirstLocalMusicTrack: Bool? = nil,
        preloadAdjacentLocalMusicTracks: Bool? = nil,
        preloadAdjacentLocalMetadata: Bool? = nil,
        adjacentFullPreloadPCMByteLimit: Int? = nil,
        preparedCacheByteLimit: Int? = nil,
        systemMemoryProvider: SystemMemoryProviding? = nil
    ) {
        self.engine = OrbisonicEngine(audioGraphEnabled: !Self.isRunningUnitTests)
        self.localAudioLoader = { url, _ in
            try localAudioLoader(url)
        }
        self.localMusicLibrary = localMusicLibrary
        self.preloadsFirstLocalMusicTrack = preloadFirstLocalMusicTrack ?? !Self.isRunningUnitTests
        self.preloadsAdjacentLocalMusicTracks = preloadAdjacentLocalMusicTracks ?? Self.preloadsAdjacentLocalMusicTracksByDefault
        self.preloadsAdjacentLocalMetadata = preloadAdjacentLocalMetadata
            ?? preloadAdjacentLocalMusicTracks
            ?? Self.preloadsAdjacentLocalMetadataByDefault
        self.adjacentFullPreloadPCMByteLimit = adjacentFullPreloadPCMByteLimit ?? Self.maxAdjacentFullPreloadPCMBytes
        self.systemMemoryProvider = systemMemoryProvider ?? HostSystemMemoryProvider()
        self.localPreparedFileCache = LocalPreparedFileCache(
            capacity: Self.maxPreparedCacheEntries,
            maxBytes: preparedCacheByteLimit ?? Self.maxPreparedCacheBytes
        )
        self.localAudioDescriptorCache = LocalAudioDescriptorCache(capacity: Self.maxAdjacentMetadataCacheEntries)
        self.localMusicMetadataEnricher = localMusicMetadataEnricher ?? (Self.isRunningUnitTests ? nil : LocalMusicMetadataEnricher(library: localMusicLibrary))
        finishInitialization()
    }

    private func finishInitialization() {
        AppLogger.shared.notice(category: "view-model", "View model initialized.")

        engine.onPlaybackEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
        engine.onLocalGaplessLogicalTrackStarted = { [weak self] track in
            self?.handleLocalGaplessLogicalTrackStarted(track)
        }
        engine.onLocalGaplessLogicalTrackEnded = { [weak self] track in
            self?.handleLocalGaplessLogicalTrackEnded(track)
        }
        engine.onLocalGaplessQueueEnded = { [weak self] in
            self?.handleLocalGaplessQueueEnded()
        }
        dolbyReferencePlayerController.onSnapshotChanged = { [weak self] snapshot in
            self?.dolbyReferencePlayerSnapshot = snapshot
            if let error = snapshot.lastError {
                self?.lastError = error
            }
        }
        applyEffectiveOutputVolume(log: false)

        applyPreset(.defaultPreset, pushToEngine: false)
        loadRendererPresets()
        restorePersistedRendererOptions()
        loadLocalMusicDatabase()
        UserDefaults.standard.set(false, forKey: Self.appleSpatialHeadphonesEnabledKey)
        refreshRoutesIfNeeded(force: true)
        refreshAppleSpatialHeadphoneMonitorStatus(updateStatusMessage: false)
        configureMonitorMeters()
        configureRendererMeters()
        refreshWebPageURLs()

        if Self.isRunningUnitTests {
            webServerStatus = "Web server disabled during tests."
            return
        }

        webServer = OrbisonicWebServer(model: self, controlToken: webControlToken) { [weak self] status in
            self?.webServerStatus = status
        }
        webServer?.start()
        startPersistentHelperServices(reason: "app launch", force: true)

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshTransport()
            }
        }
        timer.tolerance = 1.0 / 120.0
        refreshTimer = timer
        startMainActorResponsivenessHeartbeat()
    }

    private static func loadMonitorOutputSelection() -> OutputSelectionMode {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: selectedMonitorOutputModeKey) {
            return OutputSelectionMode(storedValue: stored, defaultMode: .systemDefault)
        }

        if let legacyUID = defaults.string(forKey: legacySelectedOutputDeviceUIDKey), !legacyUID.isEmpty {
            return .device(legacyUID)
        }

        return .systemDefault
    }

    private static func loadRendererOutputSelection() -> OutputSelectionMode {
        let storedSelection = OutputSelectionMode(
            storedValue: UserDefaults.standard.string(forKey: selectedRendererOutputModeKey),
            defaultMode: .none
        )

        if case .device = storedSelection {
            return storedSelection
        }

        return .none
    }

    private static func loadRendererRenderMode() -> RendererRenderMode {
        UserDefaults.standard.set(RendererRenderMode.automatic.rawValue, forKey: rendererRenderModeKey)
        return .automatic
    }

    private static func loadRendererTwoChannelPreference() -> RendererTwoChannelPreference {
        guard let storedValue = UserDefaults.standard.string(forKey: rendererTwoChannelPreferenceKey),
              let preference = RendererTwoChannelPreference(rawValue: storedValue)
        else {
            return .stereo
        }

        return preference
    }

    private static func loadLocalMusicSortMode() -> PlaylistSortMode {
        guard let storedValue = UserDefaults.standard.string(forKey: localMusicSortModeKey),
              let mode = PlaylistSortMode(rawValue: storedValue)
        else {
            return .album
        }

        return mode
    }

    private static func loadAtmosDRPOutputLayout() -> DolbyReferencePlayerOutputLayout {
        guard let storedValue = UserDefaults.standard.string(forKey: atmosDRPOutputLayoutKey),
              let layout = DolbyReferencePlayerOutputLayout(rawValue: storedValue)
        else {
            return .defaultLayout
        }

        return layout
    }

    private static func loadDouble(key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }

        return UserDefaults.standard.double(forKey: key)
    }

    private static func loadBool(key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }

        return UserDefaults.standard.bool(forKey: key)
    }

    private static func loadOrCreateWebControlToken() -> String {
        if let existing = UserDefaults.standard.string(forKey: webControlTokenKey),
           existing.count >= 32 {
            return existing
        }

        let token = generateWebControlToken()
        UserDefaults.standard.set(token, forKey: webControlTokenKey)
        return token
    }

    private static func generateWebControlToken() -> String {
        (0..<3).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
    }

    private func persistMonitorOutputSelection() {
        UserDefaults.standard.set(monitorOutputSelection.storedValue, forKey: Self.selectedMonitorOutputModeKey)
        UserDefaults.standard.removeObject(forKey: Self.legacySelectedOutputDeviceUIDKey)
    }

    private func persistRendererOutputSelection() {
        UserDefaults.standard.set(rendererOutputSelection.storedValue, forKey: Self.selectedRendererOutputModeKey)
    }

    private func persistRendererRenderMode() {
        UserDefaults.standard.set(rendererRenderMode.rawValue, forKey: Self.rendererRenderModeKey)
    }

    private func persistDouble(_ value: Double, key: String, category: String, name: String) {
        UserDefaults.standard.set(value, forKey: key)
        AppLogger.shared.info(category: category, "\(name) set to \(String(format: "%.3f", value))")
    }

    deinit {
        testToneStopTask?.cancel()
        diagnosticSequenceTask?.cancel()
        diagnosticsLogRefreshTask?.cancel()
        localMusicScanTask?.cancel()
        localMusicMetadataEnrichmentTask?.cancel()
        localPlayNowTask?.cancel()
        localFileLoadTask?.cancel()
        localFileDecodeTask?.cancel()
        localFileLoadDebounceTask?.cancel()
        localFileLoadStatusTask?.cancel()
        localPreparedFilePreloadTask?.cancel()
        localPreparedFilePreloadDecodeTask?.cancel()
        localMetadataPreloadTask?.cancel()
        roonArtworkFetchTask?.cancel()
        spotifyPlaybackStatusDebounceTask?.cancel()
        sourceSwitchTask?.cancel()
        mainActorHeartbeatTask?.cancel()
        routeRefreshTask?.cancel()
        webServer?.stop()
        roonBridgeClient.stop()
        spotifyReceiverClient.stop()
        refreshTimer?.invalidate()
    }

    private func startMainActorResponsivenessHeartbeat() {
        #if DEBUG
        mainActorHeartbeatTask?.cancel()
        mainActorHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }

                guard self != nil else { return }
                let scheduled = DispatchTime.now().uptimeNanoseconds
                await MainActor.run { [weak self] in
                    guard self != nil else { return }
                    let delayMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - scheduled) / 1_000_000.0
                    if delayMilliseconds > 100 {
                        let context = DebugTimingLog.makeCommand(prefix: "main-actor", sourceMode: self?.sourceMode)
                        context.log(
                            "Main actor delayed by \(String(format: "%.1f", delayMilliseconds)) ms",
                            sourceMode: self?.sourceMode,
                            sessionQueueIndex: self?.sessionQueueIndex,
                            selectedSessionQueueIndex: self?.selectedSessionQueueIndex,
                            pendingSessionQueueIndex: self?.pendingSessionQueueIndex,
                            extra: ["delayMs=\(String(format: "%.1f", delayMilliseconds))"]
                        )
                    }
                }
            }
        }
        #endif
    }

    func refreshWebPageURLs() {
        let urls = OrbisonicWebServer.urlSet(controlToken: webControlToken)
        webPublicPageURL = urls.publicURL
        webControlPageURL = urls.controlURL
    }

    var webControlTokenForLocalServer: String {
        webControlToken
    }

    func copyWebURLToPasteboard(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        statusMessage = "Copied web URL to clipboard."
    }

    var effectiveSphereOutputVolumePercent: Double {
        min(Self.clampedPercent(sphereOutputVolumePercent), Self.clampedPercent(sphereOutputSafetyLimitPercent))
    }

    var sphereOutputVolumeText: String {
        sphereRequestedOutputVolumeText
    }

    var sphereRequestedOutputVolumeText: String {
        "\(Int(Self.clampedPercent(sphereOutputVolumePercent).rounded()))"
    }

    var sphereMaxOutputVolumeText: String {
        "\(Int(Self.clampedPercent(sphereOutputSafetyLimitPercent).rounded()))"
    }

    var sphereEffectiveOutputVolumeText: String {
        "\(Int(effectiveSphereOutputVolumePercent.rounded()))"
    }

    var sphereOutputVolumeValue: Int { Int(Self.clampedPercent(sphereOutputVolumePercent).rounded()) }
    var sphereMaxOutputVolumeValue: Int { Int(Self.clampedPercent(sphereOutputSafetyLimitPercent).rounded()) }
    var sphereEffectiveOutputVolumeValue: Int { Int(effectiveSphereOutputVolumePercent.rounded()) }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private func updateSphereOutputVolume(settingName: String, key: String) {
        let currentValue = key == Self.sphereOutputVolumeKey ? sphereOutputVolumePercent : sphereOutputSafetyLimitPercent
        let clamped = Self.clampedPercent(currentValue)
        if currentValue != clamped {
            if key == Self.sphereOutputVolumeKey {
                sphereOutputVolumePercent = clamped
            } else {
                sphereOutputSafetyLimitPercent = clamped
            }
            return
        }

        persistDouble(clamped, key: key, category: "renderer", name: settingName)
        applyEffectiveOutputVolume(log: true)
    }

    func setSphereOutputVolume(_ value: Double) {
        sphereOutputVolumePercent = Self.clampedPercent(value)
    }

    func updateVUMeterCalibration(_ calibration: VUMeterCalibrationSettings) {
        engine.updateMeterCalibration(calibration)
    }

    private func applyEffectiveOutputVolume(log: Bool) {
        let effective = Float(effectiveSphereOutputVolumePercent / 100.0) * transitionOutputGain
        engine.setOutputVolume(effective)
        if log {
            AppLogger.shared.notice(
                category: "renderer",
                "Effective sphere output volume=\(Int(effectiveSphereOutputVolumePercent.rounded()))% requested=\(Int(sphereOutputVolumePercent.rounded()))% safetyLimit=\(Int(sphereOutputSafetyLimitPercent.rounded()))%"
            )
        }
    }

    func resetWebControlToken() {
        let token = Self.generateWebControlToken()
        webControlToken = token
        UserDefaults.standard.set(token, forKey: Self.webControlTokenKey)
        refreshWebPageURLs()
        webServer?.updateControlToken(token)
        statusMessage = "Updated local web access."
    }

    func saveDiagnosticBundle() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "Orbisonic-Log-\(formatter.string(from: Date())).txt"

        let panel = NSSavePanel()
        panel.title = "Export Orbisonic Log"
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = desktopURL
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            statusMessage = "Diagnostic export canceled."
            lastDiagnosticExportResult = "Canceled."
            return
        }

        do {
            try diagnosticReportText().write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported log to \(url.lastPathComponent)."
            lastDiagnosticExportResult = "Exported \(url.lastPathComponent)."
            AppLogger.shared.notice(category: "diagnostics", "Exported diagnostic bundle path=\(redactedPath(url.path))")
        } catch {
            let message = "Could not save diagnostics: \(error.localizedDescription)"
            statusMessage = message
            lastError = message
            lastDiagnosticExportResult = message
            AppLogger.shared.error(category: "diagnostics", message)
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio] + ["mkv", "mka"].compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK, let url = panel.url else {
            AppLogger.shared.debug(category: "ui", "Open file panel dismissed.")
            return
        }

        AppLogger.shared.info(category: "ui", "Selected file: \(url.path)")

        loadFile(url: url, autoplay: false)
    }

    private func diagnosticReportText() -> String {
        let logText = (try? String(contentsOf: AppLogger.logFileURL, encoding: .utf8)) ?? "Log file unavailable."
        let redactedLog = redactSensitiveText(logText)

        let rows: [String] = [
            "Orbisonic Diagnostics",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "",
            "Build",
            "Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")",
            "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")",
            "Executable: \(redactedPath(Bundle.main.executableURL?.path ?? "unknown"))",
            "",
            "Machine And Web",
            "Host: \(Host.current().localizedName ?? "unknown")",
            "Web Host: \(webHostText)",
            "Public URL: \(redactedPath(webPublicPageURL))",
            "Web Status: \(webServerStatus)",
            "",
            "Player",
            "Source: \(sourceMode.rawValue)",
            "Status: \(statusMessage)",
            "Loaded: \(redactedPath(loadedFileName))",
            "Playing: \(isPlaying)",
            "Time: \(formattedCurrentTime()) / \(formattedDuration())",
            "",
            "Routes",
            "Input: \(inputNowText)",
            "System Input: \(systemInputNowText)",
            "Output 1 Monitor: \(monitorOutputSelectionText) | \(monitorOutputNowText) | \(monitorOutputStatusText)",
            "Output 2 Renderer: \(rendererOutputSelectionText) | \(rendererOutputNowText) | \(rendererOutputStatusText)",
            "System Output: \(systemOutputNowText)",
            "",
            "Renderer",
            "Mode: \(rendererRenderMode.displayName)",
            "Scene: \(rendererSceneOutputText)",
            "Sphere Volume: \(sphereRequestedOutputVolumeText)",
            "Safety Limit: \(sphereMaxOutputVolumeText)",
            "Effective Volume: \(sphereEffectiveOutputVolumeText)",
            "Tuning: seam=\(rendererSeamSupportGain), upperBias=\(rendererUpperBiasDbPerUnitZ), rearFill=\(rendererStereoRearFill), centerSide=\(rendererCenterSideSupportGain), adjacentBleed=\(rendererAdjacentBleed), maxShare=\(rendererMaxSingleSpeakerPowerShare), trim=\(rendererRenderedOutputTrimDb), lfe=\(rendererLfeTrimDb)",
            "",
            "Local Music",
            "Sort: \(localMusicSortMode.rawValue)",
            "Tracks: \(localMusicTracks.count)",
            "Playlists: \(localMusicPlaylists.count)",
            "Watch Folders: \(localMusicSettings.watchFolderPaths.map(redactedPath).joined(separator: ", "))",
            "M3U Playlists: \(localMusicSettings.m3uPlaylistPaths.map(redactedPath).joined(separator: ", "))",
            "",
            "Diagnostics",
            "Tone: \(testToneStatus.isEmpty ? "None" : testToneStatus)",
            "Walk: \(diagnosticWalkStatus)",
            "Active: \(activeDiagnosticText)",
            "Selected Speaker Channel: \(selectedDiagnosticSpeakerChannel)",
            "",
            "Log",
            redactedLog
        ]

        return rows.joined(separator: "\n")
    }

    private var webHostText: String {
        if let host = URLComponents(string: webPublicPageURL).flatMap(\.host), !host.isEmpty {
            return host
        }
        return "unknown"
    }

    private func redactSensitiveText(_ value: String) -> String {
        let tokenPattern = #"(#token=)[A-Za-z0-9_-]+"#
        var redacted = value.replacingOccurrences(
            of: tokenPattern,
            with: "$1REDACTED",
            options: .regularExpression
        )
        let credentialPatterns = [
            (#"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1REDACTED"),
            (#"(?i)\b(token|secret|password|credential|api[_-]?key)(["'=:\s]+)[^"\s,;]+"#, "$1$2REDACTED")
        ]
        for (pattern, replacement) in credentialPatterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return redactedPath(redacted)
    }

    private func redactedPath(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return value }
        return value.replacingOccurrences(of: home, with: "~")
    }

    private func debugTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func debugQuote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " "))\""
    }

    private func liveMonitorDebugState() -> String {
        switch liveMonitorState {
        case .stopped:
            return "stopped"
        case .monitoring:
            return "monitoring"
        case .muted:
            return "muted"
        case .silent:
            return "silent"
        case .unavailable(let message):
            return "unavailable:\(message)"
        case .error(let message):
            return "error:\(message)"
        }
    }

    func debugPlaybackStateSnapshot() -> String {
        [
            "source=\(sourceMode.rawValue)",
            "playing=\(isPlaying)",
            "localLoading=\(isLocalFileLoading)",
            "liveMonitor=\(liveMonitorDebugState())",
            "file=\(currentFileURL.map { redactedPath($0.path) } ?? "-")",
            "queueIndex=\(sessionQueueIndex.map(String.init) ?? "-")",
            "pendingQueueIndex=\(pendingSessionQueueIndex.map(String.init) ?? "-")",
            "roonPlaying=\(isRoonTransportPlaying)",
            "spotifyPlaying=\(spotifyNowPlaying?.isPlaying.description ?? "-")",
            "spotifyVisiblePlaying=\(spotifyVisibleNowPlaying?.isPlaying.description ?? "-")"
        ].joined(separator: ",")
    }

    func logTransportDebug(
        source: SourceMode? = nil,
        command: String,
        allowed: Bool,
        handler: String,
        stateBefore: String,
        stateAfter: String? = nil,
        error: String? = nil
    ) {
        let activeSource = source ?? sourceMode
        let fields = [
            "source=\(debugQuote(activeSource.rawValue))",
            "command=\(debugQuote(command))",
            "allowed=\(allowed)",
            "handler=\(debugQuote(handler))",
            "stateBefore=\(debugQuote(stateBefore))",
            "stateAfter=\(debugQuote(stateAfter ?? debugPlaybackStateSnapshot()))",
            "error=\(debugQuote(error ?? ""))"
        ]
        AppLogger.shared.debug(category: "transport", "[transport] \(fields.joined(separator: " "))")
    }

    private func logSourceSwitchDebug(
        _ event: String,
        context: DebugTimingContext?,
        from previousSource: SourceMode,
        to nextSource: SourceMode,
        reason: String,
        requestedBy: String,
        completedAt: Date? = nil,
        success: Bool? = nil,
        error: String? = nil
    ) {
        let startedAt = context?.enabled == true ? context?.startedAt ?? Date() : Date()
        let fields = [
            "event=\(debugQuote(event))",
            "id=\(debugQuote(context?.enabled == true ? context?.id ?? "" : ""))",
            "from=\(debugQuote(previousSource.rawValue))",
            "to=\(debugQuote(nextSource.rawValue))",
            "reason=\(debugQuote(reason))",
            "requestedBy=\(debugQuote(requestedBy))",
            "startedAt=\(debugQuote(debugTimestamp(startedAt)))",
            "completedAt=\(debugQuote(completedAt.map(debugTimestamp) ?? ""))",
            "success=\(success.map { $0 ? "true" : "false" } ?? "pending")",
            "error=\(debugQuote(error ?? ""))"
        ]
        AppLogger.shared.debug(category: "source", "[source-switch] \(fields.joined(separator: " "))")
    }

    private func logLocalPlayNowDebug(
        _ event: String,
        selectedTrack: LocalMusicTrack?,
        previousSource: SourceMode,
        sourceSwitchRequired: Bool,
        sourceSwitchStarted: Bool = false,
        sourceSwitchSuccess: Bool = false,
        loadStarted: Bool = false,
        loadCompleted: Bool = false,
        playStarted: Bool = false,
        finalState: String? = nil,
        error: String? = nil
    ) {
        let fields = [
            "event=\(debugQuote(event))",
            "selectedTrack=\(debugQuote(selectedTrack?.displayTitle ?? ""))",
            "previousSource=\(debugQuote(previousSource.rawValue))",
            "sourceSwitchRequired=\(sourceSwitchRequired)",
            "sourceSwitchStarted=\(sourceSwitchStarted)",
            "sourceSwitchSuccess=\(sourceSwitchSuccess)",
            "loadStarted=\(loadStarted)",
            "loadCompleted=\(loadCompleted)",
            "playStarted=\(playStarted)",
            "finalState=\(debugQuote(finalState ?? debugPlaybackStateSnapshot()))",
            "error=\(debugQuote(error ?? ""))"
        ]
        AppLogger.shared.debug(category: "local-music", "[local-play-now] \(fields.joined(separator: " "))")
    }

    private func logLocalPlayNowDebug(
        _ event: String,
        request: LocalFileLoadRequest,
        loadStarted: Bool = false,
        loadCompleted: Bool = false,
        playStarted: Bool = false,
        finalState: String? = nil,
        error: String? = nil
    ) {
        guard request.isLocalPlayNow else { return }
        logLocalPlayNowDebug(
            event,
            selectedTrack: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            previousSource: request.requestedFromSource,
            sourceSwitchRequired: request.requestedFromSource != .filePlayback,
            loadStarted: loadStarted,
            loadCompleted: loadCompleted,
            playStarted: playStarted,
            finalState: finalState,
            error: error
        )
    }

    private func spotifyDebugStateText(_ state: SpotifyNowPlaying?) -> String {
        guard let state else { return "nil" }
        return [
            "playing=\(state.isPlaying)",
            "position=\(state.positionMs.map(String.init) ?? "-")",
            "duration=\(state.durationMs.map(String.init) ?? "-")",
            "updatedAt=\(state.updatedAt ?? "-")"
        ].joined(separator: ",")
    }

    private func logSpotifyStatusDebug(
        rawState: SpotifyNowPlaying?,
        debouncedState: SpotifyNowPlaying?,
        reasonForUpdate: String
    ) {
        let rawStateText = spotifyDebugStateText(rawState)
        let debouncedStateText = spotifyDebugStateText(debouncedState)

        let trackText = rawState.map { "\($0.displayTitle) - \($0.artistText)" } ?? ""
        let signature = [
            rawStateText,
            debouncedStateText,
            trackText,
            sourceMode.rawValue,
            reasonForUpdate
        ].joined(separator: "|")
        guard signature != lastLoggedSpotifyStatusSignature else { return }
        lastLoggedSpotifyStatusSignature = signature

        let fields = [
            "rawState=\(debugQuote(rawStateText))",
            "debouncedState=\(debugQuote(debouncedStateText))",
            "track=\(debugQuote(trackText))",
            "timestamp=\(debugQuote(debugTimestamp(Date())))",
            "activeSource=\(debugQuote(sourceMode.rawValue))",
            "reasonForUpdate=\(debugQuote(reasonForUpdate))"
        ]
        AppLogger.shared.debug(category: "spotify-status", "[spotify-status] \(fields.joined(separator: " "))")
    }

    private func logOutputRoutingDebug(
        output: String,
        previousDevice: String,
        newDevice: String,
        playbackStateBefore: String,
        graphRebuild: Bool,
        playbackStateAfter: String? = nil,
        error: String? = nil
    ) {
        let fields = [
            "output=\(debugQuote(output))",
            "previousDevice=\(debugQuote(previousDevice))",
            "newDevice=\(debugQuote(newDevice))",
            "activeSource=\(debugQuote(sourceMode.rawValue))",
            "playbackStateBefore=\(debugQuote(playbackStateBefore))",
            "graphRebuild=\(graphRebuild)",
            "playbackStateAfter=\(debugQuote(playbackStateAfter ?? debugPlaybackStateSnapshot()))",
            "error=\(debugQuote(error ?? ""))"
        ]
        AppLogger.shared.debug(category: "route", "[output-routing] \(fields.joined(separator: " "))")
    }

    private func logLocalTransportTiming(
        _ context: DebugTimingContext?,
        _ event: String,
        targetQueueIndex: Int? = nil,
        track: LocalMusicTrack? = nil,
        fileURL: URL? = nil,
        extra: [String] = []
    ) {
        context?.log(
            event,
            sourceMode: sourceMode,
            sessionQueueIndex: sessionQueueIndex,
            selectedSessionQueueIndex: selectedSessionQueueIndex,
            pendingSessionQueueIndex: pendingSessionQueueIndex,
            targetQueueIndex: targetQueueIndex,
            trackTitle: track?.displayTitle,
            fileURL: fileURL ?? track?.url,
            extra: extra
        )
    }

    private func logSourceSwitchTiming(
        _ context: DebugTimingContext?,
        _ event: String,
        previousSource: SourceMode? = nil,
        nextSource: SourceMode? = nil,
        extra: [String] = []
    ) {
        var fields = extra
        if let previousSource {
            fields.append("previousSource=\"\(previousSource.rawValue)\"")
        }
        if let nextSource {
            fields.append("nextSource=\"\(nextSource.rawValue)\"")
        }
        context?.log(
            event,
            sourceMode: sourceMode,
            sessionQueueIndex: sessionQueueIndex,
            selectedSessionQueueIndex: selectedSessionQueueIndex,
            pendingSessionQueueIndex: pendingSessionQueueIndex,
            extra: fields
        )
    }

    var sourceSwitchStatusText: String? {
        sourceSwitchTargetMode.map(sourceSwitchDisplayText(for:))
    }

    private func sourceSwitchDisplayText(for mode: SourceMode) -> String {
        mode == .off ? "Stopping audio..." : "Switching to \(mode.rawValue)..."
    }

    func selectSourceMode(
        _ mode: SourceMode,
        reason: String = "source selected",
        requestedBy: String = "desktop"
    ) {
        let debugTiming = DebugTimingLog.makeCommand(prefix: "source-switch", sourceMode: sourceMode)
        let previousSource = sourceMode
        logSourceSwitchDebug(
            "requested",
            context: debugTiming,
            from: previousSource,
            to: mode,
            reason: reason,
            requestedBy: requestedBy
        )
        logSourceSwitchTiming(
            debugTiming,
            "source switch command received",
            previousSource: previousSource,
            nextSource: mode
        )

        if mode == sourceMode,
           !isLiveMonitorTransitioning,
           !sourceSwitchRequests.isProcessing {
            if mode.startsLiveListeningOnSelection, !isPlaying {
                requestSourceTransition(to: mode, debugTiming: debugTiming, reason: reason, requestedBy: requestedBy)
                return
            }
            logSourceSwitchDebug(
                "completed",
                context: debugTiming,
                from: previousSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: true,
                error: "already selected"
            )
            return
        }

        requestSourceTransition(to: mode, debugTiming: debugTiming, reason: reason, requestedBy: requestedBy)
    }

    private func requestSourceTransition(
        to mode: SourceMode,
        debugTiming: DebugTimingContext?,
        reason: String,
        requestedBy: String
    ) {
        let shouldStart = sourceSwitchRequests.request(mode)
        pendingSourceSwitchTiming = debugTiming
        pendingSourceSwitchReason = reason
        pendingSourceSwitchRequestedBy = requestedBy
        sourceSwitchTargetMode = mode
        isLiveMonitorTransitioning = true
        statusMessage = sourceSwitchDisplayText(for: mode)
        logSourceSwitchTiming(
            debugTiming,
            "pending target set",
            previousSource: sourceMode,
            nextSource: mode,
            extra: ["shouldStart=\(shouldStart)"]
        )
        logSourceSwitchTiming(
            debugTiming,
            "UI switching state published",
            previousSource: sourceMode,
            nextSource: mode,
            extra: ["status=\"\(statusMessage)\""]
        )
        guard shouldStart else { return }

        sourceSwitchTask = Task { @MainActor [weak self] in
            await self?.processPendingSourceTransitions()
        }
    }

    private func processPendingSourceTransitions() async {
        isLiveMonitorTransitioning = true
        logSourceSwitchTiming(
            pendingSourceSwitchTiming,
            "UI switching state published",
            nextSource: sourceSwitchRequests.pendingMode
        )
        await Task.yield()
        defer {
            sourceSwitchRequests.reset()
            sourceSwitchTask = nil
            isLiveMonitorTransitioning = false
            sourceSwitchTargetMode = nil
            transitionOutputGain = 1
            applyEffectiveOutputVolume(log: false)
            logInputSourceStatusIfNeeded(reason: "source switch UI settled", force: true)
        }

        while !Task.isCancelled, let requestedMode = sourceSwitchRequests.takeNext() {
            let debugTiming = pendingSourceSwitchTiming
            let reason = pendingSourceSwitchReason ?? "source selected"
            let requestedBy = pendingSourceSwitchRequestedBy ?? "unknown"
            pendingSourceSwitchTiming = nil
            pendingSourceSwitchReason = nil
            pendingSourceSwitchRequestedBy = nil
            await performSourceTransition(
                to: requestedMode,
                debugTiming: debugTiming,
                reason: reason,
                requestedBy: requestedBy
            )
        }
    }

    private func performSourceTransition(
        to requestedMode: SourceMode,
        debugTiming: DebugTimingContext?,
        reason: String,
        requestedBy: String
    ) async {
        var mode = requestedMode
        sourceSwitchTargetMode = mode
        statusMessage = sourceSwitchDisplayText(for: mode)
        let originalSource = sourceMode
        logSourceSwitchDebug(
            "started",
            context: debugTiming,
            from: originalSource,
            to: mode,
            reason: reason,
            requestedBy: requestedBy
        )
        logSourceSwitchTiming(
            debugTiming,
            "source switch command type",
            previousSource: originalSource,
            nextSource: mode,
            extra: ["command=\"source-switch\""]
        )
        AppLogger.shared.notice(category: "source", "Switching source from \(sourceMode.rawValue) to \(mode.rawValue)")

        logSourceSwitchTiming(debugTiming, "output ramp down start", previousSource: sourceMode, nextSource: mode)
        await rampTransitionOutput(to: 0, duration: Self.sourceRampDownDuration)
        logSourceSwitchTiming(debugTiming, "output ramp down end", previousSource: sourceMode, nextSource: mode)
        guard !Task.isCancelled else {
            logSourceSwitchDebug(
                "completed",
                context: debugTiming,
                from: originalSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: false,
                error: "task canceled"
            )
            return
        }

        mode = sourceSwitchRequests.coalescePending(over: mode)
        if let nextDebugTiming = pendingSourceSwitchTiming {
            logSourceSwitchTiming(
                debugTiming,
                "stale source switch discarded",
                previousSource: sourceMode,
                nextSource: mode,
                extra: ["reason=\"coalesced source switch superseded by \(nextDebugTiming.id)\""]
            )
        }
        let activeDebugTiming = pendingSourceSwitchTiming ?? debugTiming
        pendingSourceSwitchTiming = nil
        sourceSwitchTargetMode = mode
        statusMessage = sourceSwitchDisplayText(for: mode)

        if mode == sourceMode, !(mode.startsLiveListeningOnSelection && !isPlaying) {
            logSourceSwitchTiming(activeDebugTiming, "output ramp up start", previousSource: sourceMode, nextSource: mode)
            let didRampUp = await rampTransitionOutput(to: 1, duration: Self.sourceRampUpDuration, abortIfNewSourceSwitchPending: true)
            guard didRampUp else {
                logSourceSwitchTiming(
                    activeDebugTiming,
                    "stale source switch discarded",
                    previousSource: sourceMode,
                    nextSource: mode,
                    extra: ["reason=\"newer source requested during ramp up\""]
                )
                logSourceSwitchDebug(
                    "completed",
                    context: activeDebugTiming,
                    from: originalSource,
                    to: mode,
                    reason: reason,
                    requestedBy: requestedBy,
                    completedAt: Date(),
                    success: false,
                    error: "newer source requested during ramp up"
                )
                return
            }
            logSourceSwitchTiming(activeDebugTiming, "output ramp up end", previousSource: sourceMode, nextSource: mode)
            logSourceSwitchTiming(activeDebugTiming, "source switch complete", previousSource: sourceMode, nextSource: mode)
            logSourceSwitchDebug(
                "completed",
                context: activeDebugTiming,
                from: originalSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: true
            )
            return
        }

        logSourceSwitchTiming(activeDebugTiming, "old source detach/stop start", previousSource: sourceMode, nextSource: mode)
        if sourceMode.stopsLiveCaptureWhenSwitching(to: mode) {
            stopLiveMonitorForSourceSwitch(to: mode)
        } else if isPlaying || isTestTonePlaying || isDiagnosticSequencePlaying {
            stop()
        }
        if mode != .filePlayback {
            cancelPendingLocalFileLoad()
            clearLocalPreparedFilePreloads(reason: "source changed to \(mode.rawValue)")
        }
        logSourceSwitchTiming(activeDebugTiming, "old source detach/stop end", previousSource: sourceMode, nextSource: mode)

        logSourceSwitchTiming(activeDebugTiming, "new source prepare/select start", previousSource: sourceMode, nextSource: mode)
        applySourceModeState(mode)
        logSourceSwitchTiming(activeDebugTiming, "new source prepare/select end", previousSource: originalSource, nextSource: mode)

        if mode.startsLiveListeningOnSelection {
            logSourceSwitchTiming(activeDebugTiming, "new source start/listen/render start", previousSource: originalSource, nextSource: mode)
            startSelectedLiveMonitorNow()
            await sleepForSourceTransition(Self.sourcePrimeDuration)
            logSourceSwitchTiming(activeDebugTiming, "new source start/listen/render end", previousSource: originalSource, nextSource: mode)
        }

        if let pendingMode = sourceSwitchRequests.pendingMode {
            logSourceSwitchTiming(
                activeDebugTiming,
                "stale source switch discarded",
                previousSource: originalSource,
                nextSource: mode,
                extra: ["pendingSource=\"\(pendingMode.rawValue)\""]
            )
            logSourceSwitchDebug(
                "completed",
                context: activeDebugTiming,
                from: originalSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: false,
                error: "pending source \(pendingMode.rawValue)"
            )
            return
        }

        logSourceSwitchTiming(activeDebugTiming, "output ramp up start", previousSource: originalSource, nextSource: mode)
        let didRampUp = await rampTransitionOutput(to: 1, duration: Self.sourceRampUpDuration, abortIfNewSourceSwitchPending: true)
        guard didRampUp else {
            logSourceSwitchTiming(
                activeDebugTiming,
                "stale source switch discarded",
                previousSource: originalSource,
                nextSource: mode,
                extra: ["reason=\"newer source requested during ramp up\""]
            )
            logSourceSwitchDebug(
                "completed",
                context: activeDebugTiming,
                from: originalSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: false,
                error: "newer source requested during ramp up"
            )
            return
        }
        logSourceSwitchTiming(activeDebugTiming, "output ramp up end", previousSource: originalSource, nextSource: mode)
        if case .error = liveMonitorState {
            logSourceSwitchTiming(activeDebugTiming, "source switch failed", previousSource: originalSource, nextSource: mode)
            logSourceSwitchDebug(
                "completed",
                context: activeDebugTiming,
                from: originalSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: false,
                error: liveMonitorDebugState()
            )
        } else if case .unavailable = liveMonitorState, mode.isLiveInput {
            logSourceSwitchTiming(activeDebugTiming, "source switch failed", previousSource: originalSource, nextSource: mode)
            logSourceSwitchDebug(
                "completed",
                context: activeDebugTiming,
                from: originalSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: false,
                error: liveMonitorDebugState()
            )
        } else {
            logSourceSwitchTiming(activeDebugTiming, "source switch complete", previousSource: originalSource, nextSource: mode)
            logSourceSwitchDebug(
                "completed",
                context: activeDebugTiming,
                from: originalSource,
                to: mode,
                reason: reason,
                requestedBy: requestedBy,
                completedAt: Date(),
                success: true
            )
        }
        AppLogger.shared.notice(category: "source", "Finished source switch to \(mode.rawValue)")
    }

    private func applySourceModeState(_ mode: SourceMode) {
        sourceMode = mode
        lastLiveSignalPresent = nil
        lastLiveSignalDetectedSecond = nil
        liveAudioSignalState = .unknown
        liveAudioSignalSilenceDuration = nil

        switch mode {
        case .off:
            updateSpotifyNowPlaying(nil, reason: "source changed", forceVisible: true)
            currentFileURL = nil
            clearLoadedSourceSnapshot()
            roonNowPlaying = nil
            liveSignalStatus = "No audio yet."
            liveBufferStatus = "No live buffer."
            liveMonitorState = .stopped
            roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
            roonSignalPath = nil
            statusMessage = "Orbisonic is idle. Select a source to begin listening or playback."
        case .filePlayback:
            updateSpotifyNowPlaying(nil, reason: "source changed", forceVisible: true)
            currentAtmosDRPTrack = nil
            liveSignalStatus = "No live input."
            liveBufferStatus = "No live buffer."
            liveMonitorState = .stopped
            roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
            roonSignalPath = nil
            statusMessage = "Use the Local Music tab to play music."
            preloadFirstLocalMusicTrackIfNeeded(reason: "Local Music selected")
        case .atmosDRP:
            updateSpotifyNowPlaying(nil, reason: "source changed", forceVisible: true)
            roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
            roonSignalPath = nil
            roonNowPlaying = nil
            if selectExpectedLoopbackInputIfAvailable(for: .atmosDRP) {
                liveMonitorState = .stopped
                statusMessage = "Choose a DRP-compatible Atmos file, then press play."
            } else {
                let message = missingLoopbackMessage(for: .atmosDRP)
                liveMonitorState = .unavailable(message)
                statusMessage = message
            }
        case .roon:
            updateSpotifyNowPlaying(nil, reason: "source changed", forceVisible: true)
            currentFileURL = nil
            currentAtmosDRPTrack = nil
            clearLoadedSourceSnapshot()
            roonNowPlayingStatus = "Roon metadata not requested yet."
            roonSignalPath = nil
            refreshRoonBridgeIfNeeded(force: true)
            if selectExpectedLoopbackInputIfAvailable(for: .roon) {
                liveMonitorState = .stopped
                statusMessage = "Open Roon and make sure Orbisonic is authorized."
            } else {
                let message = missingLoopbackMessage(for: .roon)
                liveMonitorState = .unavailable(message)
                statusMessage = message
            }
        case .spotify:
            currentFileURL = nil
            currentAtmosDRPTrack = nil
            clearLoadedSourceSnapshot()
            roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
            roonSignalPath = nil
            roonNowPlaying = nil
            activeLiveChannelCount = SourceMode.spotify.fixedLiveChannelCount ?? 2
            refreshSpotifyConnectServerIfNeeded(reason: "source selected", force: true)
            refreshSpotifyNowPlayingIfNeeded(force: true, reason: "source selected")
            if selectExpectedLoopbackInputIfAvailable(for: .spotify) {
                liveMonitorState = .stopped
                statusMessage = "Open Spotify and choose Orbisonic from the devices menu."
            } else {
                let message = missingLoopbackMessage(for: .spotify)
                liveMonitorState = .unavailable(message)
                statusMessage = message
            }
        case .testTone:
            updateSpotifyNowPlaying(nil, reason: "source changed", forceVisible: true)
            currentFileURL = nil
            currentAtmosDRPTrack = nil
            clearLoadedSourceSnapshot()
            roonNowPlaying = nil
            liveSignalStatus = "No live input."
            liveBufferStatus = "No live buffer."
            liveMonitorState = .stopped
            roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
            roonSignalPath = nil
            statusMessage = "Test tone source is ready. Use Diagnostics to play the selected tone."
        case .aux:
            updateSpotifyNowPlaying(nil, reason: "source changed", forceVisible: true)
            currentFileURL = nil
            currentAtmosDRPTrack = nil
            clearLoadedSourceSnapshot()
            roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
            roonSignalPath = nil
            roonNowPlaying = nil
            if selectExpectedLoopbackInputIfAvailable(for: .aux) {
                liveMonitorState = .stopped
                statusMessage = "Select Orbisonic Aux Cable as the output device in the source app."
            } else {
                let message = missingLoopbackMessage(for: .aux)
                liveMonitorState = .unavailable(message)
                statusMessage = message
            }
        }

        resetRendererRequestToAutomatic(reason: "source changed to \(mode.rawValue)")
        logInputSourceStatusIfNeeded(reason: "source changed to \(mode.rawValue)", force: true)
    }

    func selectInputRoute(_ route: InputRouteInfo) {
        guard route.isAvailable else { return }

        if sourceMode.isLiveInput, !sourceMode.acceptsInputRoute(route) {
            if isPlaying {
                stop()
            }
            statusMessage = inputSelectionBlockedMessage(for: route)
            return
        }

        let previousRoute = inputRoute
        selectedInputDeviceUID = route.uid
        if route.uid.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.selectedInputDeviceUIDKey)
        } else {
            UserDefaults.standard.set(route.uid, forKey: Self.selectedInputDeviceUIDKey)
        }

        inputRoute = route
        applyLiveChannelDefaults(for: route)

        AppLogger.shared.notice(
            category: "route",
            "Selected Orbisonic input device=\(route.deviceName) uid=\(route.uid) transport=\(route.transportName) channels=\(route.inputChannelCount) sampleRate=\(formatSampleRate(route.nominalSampleRate)) blackHole=\(route.isBlackHole)"
        )

        if sourceMode.isLiveInput, isPlaying, previousRoute.deviceID != route.deviceID {
            startLiveInputForCurrentRoute(reason: "selected input changed")
        } else if sourceMode.isLiveInput {
            statusMessage = "Orbisonic input set to \(route.deviceName). macOS system input is still \(systemInputRoute.displayName)."
            logInputSourceStatusIfNeeded(reason: "selected input changed", force: true)
        }
    }

    func selectNoMonitorOutput() {
        let stateBefore = debugPlaybackStateSnapshot()
        let previousDevice = monitorOutputRoute.deviceName
        let previousRoute = monitorOutputRoute
        monitorOutputSelection = .none
        persistMonitorOutputSelection()
        refreshRoutesIfNeeded(force: true)
        let graphRebuild = activateRendererOutputIfMonitorWasActive(previousMonitorRoute: previousRoute)
        statusMessage = "Output 1 Monitor not set."
        logOutputRoutingDebug(
            output: "Output 1 Monitor",
            previousDevice: previousDevice,
            newDevice: "not set",
            playbackStateBefore: stateBefore,
            graphRebuild: graphRebuild
        )
    }

    func selectSystemMonitorOutput() {
        let previousDevice = monitorOutputRoute.deviceName
        monitorOutputSelection = .systemDefault
        persistMonitorOutputSelection()
        refreshRoutesIfNeeded(force: true)
        applyMonitorOutputRouteIfAvailable(monitorOutputRoute, previousDevice: previousDevice, label: "System Default")
    }

    func selectMonitorOutputRoute(_ route: OutputRouteInfo) {
        let stateBefore = debugPlaybackStateSnapshot()
        let previousDevice = monitorOutputRoute.deviceName
        guard route.isAvailable else {
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: "route unavailable"
            )
            return
        }
        guard route.isSelectableOutputTarget else {
            let message = outputFeedbackMessage(for: route, purpose: .monitor)
            AppLogger.shared.error(category: "route", message)
            statusMessage = message
            lastError = message
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: message
            )
            return
        }

        monitorOutputSelection = .device(route.uid)
        persistMonitorOutputSelection()
        refreshRoutesIfNeeded(force: true)
        applyMonitorOutputRouteIfAvailable(route, previousDevice: previousDevice, label: route.deviceName)
    }

    func selectNoRendererOutput() {
        let stateBefore = debugPlaybackStateSnapshot()
        let previousDevice = rendererOutputRoute.deviceName
        rendererOutputSelection = .none
        persistRendererOutputSelection()
        refreshRoutesIfNeeded(force: true)
        configureMonitorMeters()
        configureRendererMeters()
        syncRendererAudioRouting()
        reevaluatePureSphericalLosslessStateForCurrentFile()
        if isDiagnosticSequencePlaying {
            stop()
        }
        statusMessage = "Output 2 Renderer not set."
        logOutputRoutingDebug(
            output: "Output 2 Renderer",
            previousDevice: previousDevice,
            newDevice: "not set",
            playbackStateBefore: stateBefore,
            graphRebuild: true
        )
    }

    func selectRendererOutputRoute(_ route: OutputRouteInfo) {
        let stateBefore = debugPlaybackStateSnapshot()
        let previousDevice = rendererOutputRoute.deviceName
        guard route.isAvailable else {
            logOutputRoutingDebug(
                output: "Output 2 Renderer",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: "route unavailable"
            )
            return
        }
        guard route.isSelectableOutputTarget else {
            let message = outputFeedbackMessage(for: route, purpose: .renderer)
            AppLogger.shared.error(category: "route", message)
            statusMessage = message
            lastError = message
            logOutputRoutingDebug(
                output: "Output 2 Renderer",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: message
            )
            return
        }

        rendererOutputSelection = .device(route.uid)
        persistRendererOutputSelection()
        refreshRoutesIfNeeded(force: true)
        applyOutputRouteIfAvailable(route, purpose: .renderer, label: route.deviceName, applyAsynchronously: true)
        reevaluatePureSphericalLosslessStateForCurrentFile()
        logOutputRoutingDebug(
            output: "Output 2 Renderer",
            previousDevice: previousDevice,
            newDevice: route.deviceName,
            playbackStateBefore: stateBefore,
            graphRebuild: true
        )
    }

    func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK else {
            AppLogger.shared.debug(category: "ui", "Watch folder panel dismissed.")
            return
        }

        var nextSettings = localMusicSettings
        for url in panel.urls where !nextSettings.watchFolderPaths.contains(url.path) {
            nextSettings.watchFolderPaths.append(url.path)
        }
        nextSettings.watchFolderPaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        updateLocalMusicSettings(nextSettings, rescan: true)
    }

    func removeWatchFolder(path: String) {
        var nextSettings = localMusicSettings
        nextSettings.watchFolderPaths.removeAll { $0 == path }
        updateLocalMusicSettings(nextSettings, rescan: true)
    }

    func chooseM3UPlaylist() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "m3u"),
            UTType(filenameExtension: "m3u8")
        ].compactMap { $0 }

        guard panel.runModal() == .OK else {
            AppLogger.shared.debug(category: "ui", "M3U playlist panel dismissed.")
            return
        }

        var nextSettings = localMusicSettings
        for url in panel.urls where !nextSettings.m3uPlaylistPaths.contains(url.path) {
            nextSettings.m3uPlaylistPaths.append(url.path)
        }
        updateLocalMusicSettings(nextSettings, rescan: true)
    }

    func removeM3UPlaylist(path: String) {
        var nextSettings = localMusicSettings
        nextSettings.m3uPlaylistPaths.removeAll { $0 == path }
        updateLocalMusicSettings(nextSettings, rescan: true)
    }

    func setLocalMusicScansSubfolders(_ scansSubfolders: Bool) {
        var nextSettings = localMusicSettings
        nextSettings.scansSubfolders = scansSubfolders
        updateLocalMusicSettings(nextSettings, rescan: true)
    }

    func setLocalMusicImportsM3UPlaylists(_: Bool) {
        var nextSettings = localMusicSettings
        nextSettings.importsM3UPlaylists = true
        updateLocalMusicSettings(nextSettings, rescan: true)
    }

    func setLocalMusicExtractsAlbumArt(_: Bool) {
        var nextSettings = localMusicSettings
        nextSettings.extractsAlbumArt = true
        updateLocalMusicSettings(nextSettings, rescan: true)
    }

    func setLocalMusicEnhancesMetadata(_ enhancesMetadata: Bool) {
        var nextSettings = localMusicSettings
        nextSettings.enhancesMetadata = enhancesMetadata
        updateLocalMusicSettings(nextSettings, rescan: false)
        statusMessage = enhancesMetadata
            ? "Local music metadata enhancement enabled."
            : "Local music metadata enhancement disabled."
        if enhancesMetadata {
            scheduleLocalMusicMetadataEnhancement(reason: "setting enabled", force: true)
        } else {
            localMusicMetadataEnrichmentTask?.cancel()
            localMusicMetadataEnrichmentTask = nil
        }
    }

    func rescanLocalMusicLibrary() {
        localMusicScanTask?.cancel()
        let settings = localMusicSettings
        statusMessage = "Scanning local music library..."

        localMusicScanTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LocalMusicLibrary().scan(settings: settings)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.applyLocalMusicScanResult(result)
        }
    }

    private func applyLocalMusicScanResult(_ result: LocalMusicScanResult) {
        clearLocalPreparedFilePreloads(reason: "local music scan result applied")
        localMusicBaseTracks = result.tracks
        localMusicMetadataOverlays = localMusicMetadataOverlays.filter { overlay in
            result.tracks.contains { $0.id == overlay.key }
        }
        localMusicMetadataScannedTrackIDs = localMusicMetadataScannedTrackIDs.filter { id in
            result.tracks.contains { $0.id == id }
        }
        refreshEffectiveLocalMusicTracks()
        localMusicPlaylists = orderedLocalMusicPlaylistsAfterScan(result.playlists)

        if let selectedLibraryTrackID,
           !localMusicTracks.contains(where: { $0.id == selectedLibraryTrackID }) {
            self.selectedLibraryTrackID = nil
        }
        if let selectedLocalMusicPlaylistID,
           !localMusicPlaylists.contains(where: { $0.id == selectedLocalMusicPlaylistID }) {
            self.selectedLocalMusicPlaylistID = nil
        }
        sessionQueue = sessionQueue.filter { track in localMusicTracks.contains(where: { $0.id == track.id }) }
        if let sessionQueueIndex, sessionQueue.indices.contains(sessionQueueIndex) == false {
            refreshSessionQueueIndexForCurrentFile()
        }
        if let selectedSessionQueueIndex, sessionQueue.indices.contains(selectedSessionQueueIndex) == false {
            self.selectedSessionQueueIndex = nil
        }
        if let pendingSessionQueueIndex, sessionQueue.indices.contains(pendingSessionQueueIndex) == false {
            self.pendingSessionQueueIndex = nil
        }
        rebuildLocalGaplessQueueAfterSessionMutation(reason: "local music scan result applied")

        persistLocalMusicDatabase()
        if result.skippedMissingFiles > 0 {
            statusMessage = "Scanned \(localMusicTracks.count) playable tracks; skipped \(result.skippedMissingFiles) missing files."
        } else {
            statusMessage = "Local music library scanned: \(localMusicTracks.count) tracks, \(localMusicPlaylists.count) playlists."
        }
        AppLogger.shared.notice(
            category: "local-music",
            "Scanned watchFolders=\(localMusicSettings.watchFolderPaths.count) explicitPlaylists=\(localMusicSettings.m3uPlaylistPaths.count) tracks=\(localMusicTracks.count) playlists=\(localMusicPlaylists.count) skippedMissing=\(result.skippedMissingFiles)"
        )
        preloadFirstLocalMusicTrackIfNeeded(reason: "local music scan completed")
        scheduleLocalMusicMetadataEnhancement(reason: "local music scan completed", force: true)
    }

    func loadSelectedLocalMusicTrack() {
        guard let track = selectedLocalMusicTrack ?? visibleLocalMusicTracks.first else {
            statusMessage = "Add a watch folder in Settings, then scan local music."
            return
        }

        startSessionQueue(from: visibleLocalMusicTracks, startTrackID: track.id, shuffle: false, autoplay: false)
    }

    func toggleLocalMusicPlayback() {
        if isPlaying {
            pauseLocalTransport()
            return
        }

        playLocalTransport()
    }

    func playLocalTransport() {
        let stateBefore = debugPlaybackStateSnapshot()
        var commandAllowed = true
        var commandError: String?
        defer {
            logTransportDebug(
                command: "play",
                allowed: commandAllowed,
                handler: "playLocalTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }
        let debugTiming = DebugTimingLog.makeCommand(prefix: "local-play", sourceMode: sourceMode)
        logLocalTransportTiming(
            debugTiming,
            "command received",
            extra: ["command=\"play\""]
        )
        if isLocalFileLoading {
            statusMessage = "Loading local track..."
            commandAllowed = false
            commandError = "local file load already in progress"
            logLocalTransportTiming(
                debugTiming,
                "UI state updated",
                extra: ["status=\"Loading local track...\""]
            )
            return
        }

        if sourceMode == .filePlayback, currentFileURL != nil, duration > 0 {
            guard !isPlaying else {
                commandAllowed = false
                commandError = "local playback already playing"
                return
            }
            togglePlayback()
            return
        }

        let selectedQueueTrack = selectedSessionQueueIndex.flatMap { index in
            sessionQueue.indices.contains(index) ? sessionQueue[index] : nil
        }
        guard let track = selectedQueueTrack ?? selectedLocalMusicTrack ?? currentLocalMusicTrack ?? visibleLocalMusicTracks.first else {
            statusMessage = "Add a watch folder in Settings, then scan local music."
            commandAllowed = false
            commandError = statusMessage
            return
        }

        guard currentFileURL?.path == track.id, sourceMode == .filePlayback else {
            if let queueIndex = sessionQueue.firstIndex(where: { $0.id == track.id }) {
                playQueueIndex(queueIndex, debugTiming: debugTiming)
                return
            }
            startSessionQueue(
                from: visibleLocalMusicTracks,
                startTrackID: track.id,
                shuffle: isShuffleEnabled,
                autoplay: true,
                debugTiming: debugTiming
            )
            return
        }

        togglePlayback()
    }

    func playAtmosDRPTransport() {
        let stateBefore = debugPlaybackStateSnapshot()
        var commandAllowed = true
        var commandError: String?
        defer {
            logTransportDebug(
                command: "play",
                allowed: commandAllowed,
                handler: "playAtmosDRPTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }

        if dolbyReferencePlayerSnapshot.state == .paused {
            do {
                try dolbyReferencePlayerController.resume()
                isPlaying = true
                liveMonitorState = .monitoring
                statusMessage = "Atmos DRP playback resumed."
            } catch {
                commandAllowed = false
                commandError = error.localizedDescription
                statusMessage = error.localizedDescription
                lastError = error.localizedDescription
            }
            return
        }

        guard let track = selectedAtmosDRPTrack() else {
            statusMessage = "Select a DRP-compatible Atmos file in Local Music."
            commandAllowed = false
            commandError = statusMessage
            return
        }

        if let queueIndex = sessionQueue.firstIndex(where: { $0.id == track.id }) {
            selectedSessionQueueIndex = queueIndex
            sessionQueueIndex = queueIndex
        }
        startAtmosDRPPipe(track: track)
    }

    private func selectedAtmosDRPTrack() -> LocalMusicTrack? {
        let selectedQueueTrack = selectedSessionQueueIndex.flatMap { index in
            sessionQueue.indices.contains(index) ? sessionQueue[index] : nil
        }
        let candidates = [
            selectedQueueTrack,
            selectedLocalMusicTrack,
            currentAtmosDRPTrack,
            currentLocalMusicTrack,
            visibleLocalMusicTracks.first
        ]
        return candidates.compactMap { $0 }.first { DolbyReferencePlayerController.supportsFile($0.url) }
    }

    func pauseLocalTransport() {
        let stateBefore = debugPlaybackStateSnapshot()
        var commandAllowed = sourceMode == .filePlayback || isLocalFileLoading
        var commandError: String?
        defer {
            logTransportDebug(
                command: "pause",
                allowed: commandAllowed,
                handler: "pauseLocalTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }
        let debugTiming = DebugTimingLog.makeCommand(prefix: "local-pause", sourceMode: sourceMode)
        logLocalTransportTiming(
            debugTiming,
            "command received",
            extra: ["command=\"pause\""]
        )
        logLocalTransportTiming(debugTiming, "pause cancellation started")
        cancelPendingLocalFileLoad(debugTiming: debugTiming)
        logLocalTransportTiming(debugTiming, "pause cancellation finished")
        guard sourceMode == .filePlayback else {
            commandAllowed = false
            commandError = "source is \(sourceMode.rawValue)"
            return
        }

        if isPlaying {
            engine.pause()
            isPlaying = false
            reevaluateAutomaticRendererMode(reason: "pause")
            statusMessage = "Local playback paused"
        } else {
            statusMessage = "Local playback paused"
        }
    }

    func pauseAtmosDRPTransport() {
        let stateBefore = debugPlaybackStateSnapshot()
        var commandAllowed = sourceMode == .atmosDRP
        var commandError: String?
        defer {
            logTransportDebug(
                command: "pause",
                allowed: commandAllowed,
                handler: "pauseAtmosDRPTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }
        guard sourceMode == .atmosDRP else {
            commandAllowed = false
            commandError = "source is \(sourceMode.rawValue)"
            return
        }

        do {
            try dolbyReferencePlayerController.pause()
            isPlaying = false
            liveMonitorState = .muted
            statusMessage = "Atmos DRP playback paused. Pause uses DRP process suspension."
        } catch {
            commandAllowed = false
            commandError = error.localizedDescription
            statusMessage = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    func stopLocalTransport() {
        let stateBefore = debugPlaybackStateSnapshot()
        let commandAllowed = sourceMode == .filePlayback || isLocalFileLoading
        var commandError: String?
        defer {
            logTransportDebug(
                command: "stop",
                allowed: commandAllowed,
                handler: "stopLocalTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }
        let debugTiming = DebugTimingLog.makeCommand(prefix: "local-stop", sourceMode: sourceMode)
        logLocalTransportTiming(
            debugTiming,
            "command received",
            extra: ["command=\"stop\""]
        )
        logLocalTransportTiming(debugTiming, "stop cancellation started")
        cancelPendingLocalFileLoad(debugTiming: debugTiming)
        logLocalTransportTiming(debugTiming, "stop cancellation finished")
        stop()
        if sourceMode == .filePlayback {
            statusMessage = "Local ready"
        } else if !commandAllowed {
            commandError = "source is \(sourceMode.rawValue)"
        }
    }

    func stopAtmosDRPTransport() {
        let stateBefore = debugPlaybackStateSnapshot()
        var commandError: String?
        defer {
            logTransportDebug(
                command: "stop",
                allowed: sourceMode == .atmosDRP,
                handler: "stopAtmosDRPTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }
        do {
            try dolbyReferencePlayerController.stop()
        } catch {
            commandError = error.localizedDescription
            lastError = error.localizedDescription
        }
        let stoppedSource = sourceMode
        engine.stop()
        markLiveMonitorStopped(sourceMode: stoppedSource)
        currentAtmosDRPTrack = nil
        currentFileURL = nil
        statusMessage = "Atmos DRP stopped."
    }

    func playLocalMusicTrackNow(_ track: LocalMusicTrack) {
        let previousSource = sourceMode
        let debugTiming = DebugTimingLog.makeCommand(prefix: "local-play-now", sourceMode: sourceMode)
        let sourceSwitchRequired = previousSource != .filePlayback ||
            isLiveMonitorTransitioning ||
            sourceSwitchRequests.isProcessing ||
            sourceSwitchTargetMode != nil
        logLocalPlayNowDebug(
            "requested",
            selectedTrack: track,
            previousSource: previousSource,
            sourceSwitchRequired: sourceSwitchRequired,
            finalState: debugPlaybackStateSnapshot()
        )
        logLocalTransportTiming(
            debugTiming,
            "command received",
            track: track,
            extra: ["command=\"row-play\""]
        )
        selectedSessionQueueIndex = nil
        let tracks = visibleLocalMusicTracks.contains(where: { $0.id == track.id })
            ? visibleLocalMusicTracks
            : [track]
        localPlayNowTask?.cancel()
        localPlayNowSequence &+= 1
        let sequence = localPlayNowSequence

        guard sourceSwitchRequired else {
            startSessionQueue(from: tracks, startTrackID: track.id, shuffle: false, autoplay: true, debugTiming: debugTiming)
            return
        }

        statusMessage = "Switching to Local Music..."
        logLocalPlayNowDebug(
            "source switch started",
            selectedTrack: track,
            previousSource: previousSource,
            sourceSwitchRequired: true,
            sourceSwitchStarted: true,
            finalState: debugPlaybackStateSnapshot()
        )

        localPlayNowTask = Task { @MainActor [weak self] in
            await self?.continueLocalPlayNowAfterSourceSwitch(
                sequence: sequence,
                track: track,
                tracks: tracks,
                previousSource: previousSource,
                debugTiming: debugTiming
            )
        }
    }

    private func continueLocalPlayNowAfterSourceSwitch(
        sequence: UInt64,
        track: LocalMusicTrack,
        tracks: [LocalMusicTrack],
        previousSource: SourceMode,
        debugTiming: DebugTimingContext?
    ) async {
        defer {
            if sequence == localPlayNowSequence {
                localPlayNowTask = nil
            }
        }
        selectSourceMode(.filePlayback, reason: "local Play Now", requestedBy: "local-play-now")

        let didSwitch = await waitForLocalPlayNowSourceActivation(sequence: sequence)
        guard !Task.isCancelled, sequence == localPlayNowSequence else { return }

        guard didSwitch else {
            let message = sourceMode == .filePlayback
                ? "Local Music did not finish activating for Play Now."
                : "Could not switch to Local Music for Play Now. Current source is \(sourceMode.displayName)."
            statusMessage = message
            lastError = message
            isLocalFileLoading = false
            pendingSessionQueueIndex = nil
            clearPendingLocalPresentation()
            logLocalPlayNowDebug(
                "completed",
                selectedTrack: track,
                previousSource: previousSource,
                sourceSwitchRequired: true,
                sourceSwitchStarted: true,
                sourceSwitchSuccess: false,
                finalState: debugPlaybackStateSnapshot(),
                error: message
            )
            return
        }

        logLocalPlayNowDebug(
            "source switch completed",
            selectedTrack: track,
            previousSource: previousSource,
            sourceSwitchRequired: true,
            sourceSwitchStarted: true,
            sourceSwitchSuccess: true,
            finalState: debugPlaybackStateSnapshot()
        )
        startSessionQueue(from: tracks, startTrackID: track.id, shuffle: false, autoplay: true, debugTiming: debugTiming)
    }

    private func waitForLocalPlayNowSourceActivation(sequence: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.localPlayNowSourceSwitchTimeout)
        while Date() < deadline {
            guard !Task.isCancelled, sequence == localPlayNowSequence else { return false }
            if sourceMode == .filePlayback,
               sourceSwitchTargetMode == nil,
               !isLiveMonitorTransitioning,
               !sourceSwitchRequests.isProcessing {
                return true
            }

            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return false
            }
        }

        return sourceMode == .filePlayback &&
            sourceSwitchTargetMode == nil &&
            !isLiveMonitorTransitioning &&
            !sourceSwitchRequests.isProcessing
    }

    func selectLocalMusicTrack(_ track: LocalMusicTrack) {
        selectedLibraryTrackID = track.id
        selectedSessionQueueIndex = nil
    }

    func playNextLocalMusicTrack() {
        skipLocalTransport(offset: 1)
    }

    func playPreviousLocalMusicTrack() {
        skipLocalTransport(offset: -1)
    }

    func selectSessionQueueIndex(_ index: Int) {
        guard sessionQueue.indices.contains(index) else { return }
        selectedSessionQueueIndex = index
    }

    func playSessionQueueIndex(_ index: Int) {
        guard sessionQueue.indices.contains(index) else { return }
        let debugTiming = DebugTimingLog.makeCommand(prefix: "local-row-play", sourceMode: sourceMode)
        logLocalTransportTiming(
            debugTiming,
            "command received",
            targetQueueIndex: index,
            track: queueTrack(for: index),
            extra: ["command=\"row-play\""]
        )
        selectedSessionQueueIndex = index
        logLocalTransportTiming(
            debugTiming,
            "UI state updated",
            targetQueueIndex: index,
            track: queueTrack(for: index),
            extra: ["selectedSessionQueueIndex=\(index)"]
        )
        _ = playQueueIndex(index, debugTiming: debugTiming)
    }

    func playSelectedSessionQueueTrack() {
        let debugTiming = DebugTimingLog.makeCommand(prefix: "local-row-play", sourceMode: sourceMode)
        logLocalTransportTiming(
            debugTiming,
            "command received",
            targetQueueIndex: selectedSessionQueueIndex,
            track: selectedSessionQueueIndex.flatMap { queueTrack(for: $0) },
            extra: ["command=\"selected-row-play\""]
        )
        if let selectedSessionQueueIndex, sessionQueue.indices.contains(selectedSessionQueueIndex) {
            if currentFileURL?.path == sessionQueue[selectedSessionQueueIndex].id, sourceMode == .filePlayback {
                toggleLocalMusicPlayback()
                return
            }
            playQueueIndex(selectedSessionQueueIndex, debugTiming: debugTiming)
            return
        }

        toggleLocalMusicPlayback()
    }

    func playAllLocalMusic(shuffle: Bool = false) {
        let debugTiming = DebugTimingLog.makeCommand(prefix: shuffle ? "local-shuffle" : "local-play-all", sourceMode: sourceMode)
        logLocalTransportTiming(
            debugTiming,
            "command received",
            extra: ["command=\"\(shuffle ? "shuffle" : "playAll")\""]
        )
        startSessionQueue(
            from: visibleLocalMusicTracks,
            startTrackID: visibleLocalMusicTracks.first?.id,
            shuffle: shuffle,
            autoplay: true,
            debugTiming: debugTiming
        )
    }

    func playSelectedLocalMusicPlaylist(shuffle: Bool = false) {
        guard let playlist = selectedLocalMusicPlaylist ?? localMusicPlaylists.first else {
            statusMessage = "No M3U playlists are available. Add one in Settings or scan a folder that contains playlists."
            return
        }

        playLocalMusicPlaylist(playlist, shuffle: shuffle)
    }

    func addLocalMusicTrackToQueue(_ track: LocalMusicTrack) {
        let wasEmpty = sessionQueue.isEmpty
        sessionQueue.append(track)
        selectedLibraryTrackID = track.id

        if wasEmpty {
            selectedSessionQueueIndex = 0
        }

        rebuildLocalGaplessQueueAfterSessionMutation(reason: "session queue item added")
        statusMessage = "Added \(track.displayTitle) to the session queue."
    }

    func createLocalMusicPlaylist(named rawName: String) {
        do {
            let name = try validatedPlaylistName(rawName)
            if let existingPlaylist = editableLocalMusicPlaylist(named: name) {
                selectedLocalMusicPlaylistID = existingPlaylist.id
                statusMessage = "\(existingPlaylist.name) already exists."
                return
            }

            let playlist = try localMusicLibrary.createPlaylist(name: name, tracks: [])
            registerLocalMusicPlaylist(playlist)
            selectedLocalMusicPlaylistID = playlist.id
            persistLocalMusicDatabase()
            statusMessage = "Created playlist \(playlist.name)."
            AppLogger.shared.notice(category: "local-music", "Created playlist path=\(playlist.path)")
        } catch {
            handleLocalMusicPlaylistMutationError(error, logPrefix: "Could not create playlist")
        }
    }

    func addLocalMusicTrackToNewPlaylist(_ track: LocalMusicTrack, named rawName: String) {
        do {
            let name = try validatedPlaylistName(rawName)
            if let existingPlaylist = editableLocalMusicPlaylist(named: name) {
                addLocalMusicTrackToPlaylist(track, existingPlaylist)
                return
            }

            let playlist = try localMusicLibrary.createPlaylist(name: name, tracks: [track])
            registerLocalMusicPlaylist(playlist)
            selectedLibraryTrackID = track.id
            selectedLocalMusicPlaylistID = playlist.id
            persistLocalMusicDatabase()
            statusMessage = "Added \(track.displayTitle) to new playlist \(playlist.name)."
            AppLogger.shared.notice(category: "local-music", "Created playlist from track path=\(playlist.path) track=\(track.fileName)")
        } catch {
            handleLocalMusicPlaylistMutationError(error, logPrefix: "Could not add track to new playlist")
        }
    }

    func addLocalMusicTrackToPlaylist(_ track: LocalMusicTrack, _ playlist: LocalMusicPlaylist) {
        do {
            let updated = try localMusicLibrary.appendTrack(
                track,
                to: playlist,
                knownTracks: localMusicTracks
            )
            replaceLocalMusicPlaylist(playlist.id, with: updated)
            selectedLibraryTrackID = track.id
            selectedLocalMusicPlaylistID = updated.id
            persistLocalMusicDatabase()
            statusMessage = "Added \(track.displayTitle) to \(updated.name)."
            AppLogger.shared.notice(category: "local-music", "Added track to playlist path=\(updated.path) track=\(track.fileName)")
        } catch {
            handleLocalMusicPlaylistMutationError(error, logPrefix: "Could not add track to playlist")
        }
    }

    func moveLocalMusicPlaylistTrackUp(_ playlist: LocalMusicPlaylist, index: Int) {
        moveLocalMusicPlaylistTrack(in: playlist, from: index, to: index - 1)
    }

    func moveLocalMusicPlaylistTrackDown(_ playlist: LocalMusicPlaylist, index: Int) {
        moveLocalMusicPlaylistTrack(in: playlist, from: index, to: index + 1)
    }

    func removeLocalMusicPlaylistTrack(_ playlist: LocalMusicPlaylist, index: Int) {
        guard playlist.trackPaths.indices.contains(index) else { return }
        var trackPaths = playlist.trackPaths
        let removedPath = trackPaths.remove(at: index)
        let removedTitle = localMusicTracks.first { $0.path == removedPath }?.displayTitle ??
            URL(fileURLWithPath: removedPath).deletingPathExtension().lastPathComponent

        do {
            let updated = try localMusicLibrary.updateEditablePlaylist(
                playlist,
                trackPaths: trackPaths,
                knownTracks: localMusicTracks
            )
            replaceLocalMusicPlaylist(playlist.id, with: updated)
            selectedLocalMusicPlaylistID = updated.id
            persistLocalMusicDatabase()
            statusMessage = "Removed \(removedTitle) from \(updated.name)."
        } catch {
            handleLocalMusicPlaylistMutationError(error, logPrefix: "Could not remove playlist track")
        }
    }

    func renameLocalMusicPlaylist(_ playlist: LocalMusicPlaylist, named rawName: String) {
        do {
            let name = try validatedPlaylistName(rawName)
            if let existingPlaylist = editableLocalMusicPlaylist(named: name),
               existingPlaylist.id != playlist.id {
                throw LocalMusicPlaylistMutationError.nameConflict(existingPlaylist.name)
            }

            let renamed = try localMusicLibrary.renameEditablePlaylist(playlist, to: name)
            replaceRegisteredPlaylistPath(oldPath: playlist.path, newPath: renamed.path)
            replaceLocalMusicPlaylist(playlist.id, with: renamed)
            selectedLocalMusicPlaylistID = renamed.id
            persistLocalMusicDatabase()
            statusMessage = "Renamed playlist to \(renamed.name)."
            AppLogger.shared.notice(category: "local-music", "Renamed playlist oldPath=\(playlist.path) newPath=\(renamed.path)")
        } catch {
            handleLocalMusicPlaylistMutationError(error, logPrefix: "Could not rename playlist")
        }
    }

    func moveLocalMusicPlaylistUp(_ playlist: LocalMusicPlaylist) {
        moveLocalMusicPlaylist(playlist, offset: -1)
    }

    func moveLocalMusicPlaylistDown(_ playlist: LocalMusicPlaylist) {
        moveLocalMusicPlaylist(playlist, offset: 1)
    }

    func canMoveLocalMusicPlaylistUp(_ playlist: LocalMusicPlaylist) -> Bool {
        guard let index = localMusicPlaylists.firstIndex(where: { $0.id == playlist.id }) else { return false }
        return index > 0
    }

    func canMoveLocalMusicPlaylistDown(_ playlist: LocalMusicPlaylist) -> Bool {
        guard let index = localMusicPlaylists.firstIndex(where: { $0.id == playlist.id }) else { return false }
        return index < localMusicPlaylists.count - 1
    }

    func deleteLocalMusicPlaylist(_ playlist: LocalMusicPlaylist) {
        let isEditable = isEditableLocalMusicPlaylist(playlist)

        do {
            if isEditable {
                try localMusicLibrary.deleteEditablePlaylist(playlist)
            }

            localMusicPlaylists.removeAll { $0.id == playlist.id }
            localMusicSettings.m3uPlaylistPaths.removeAll { $0 == playlist.path }
            if selectedLocalMusicPlaylistID == playlist.id {
                selectedLocalMusicPlaylistID = localMusicPlaylists.first?.id
            }
            persistLocalMusicDatabase()

            statusMessage = isEditable
                ? "Deleted playlist \(playlist.name)."
                : "Removed playlist \(playlist.name) from Orbisonic."
            AppLogger.shared.notice(
                category: "local-music",
                "\(isEditable ? "Deleted" : "Removed") playlist path=\(playlist.path)"
            )
        } catch {
            handleLocalMusicPlaylistMutationError(error, logPrefix: "Could not delete playlist")
        }
    }

    func addSelectedLocalMusicPlaylistToQueue(shuffle: Bool = false) {
        guard let playlist = selectedLocalMusicPlaylist ?? localMusicPlaylists.first else {
            statusMessage = "No M3U playlists are available. Add one in Settings or scan a folder that contains playlists."
            return
        }

        addLocalMusicPlaylistToQueue(playlist, shuffle: shuffle)
    }

    func addLocalMusicPlaylistToQueue(_ playlist: LocalMusicPlaylist, shuffle: Bool = false) {
        var tracks = tracks(for: playlist)
        guard !tracks.isEmpty else {
            statusMessage = "\(playlist.name) has no playable tracks in the current library."
            return
        }

        if shuffle {
            tracks.shuffle()
        }

        let wasEmpty = sessionQueue.isEmpty
        sessionQueue.append(contentsOf: tracks)
        selectedLocalMusicPlaylistID = playlist.id

        if wasEmpty {
            selectedSessionQueueIndex = 0
        }

        rebuildLocalGaplessQueueAfterSessionMutation(reason: "playlist appended to session queue")
        statusMessage = "Added \(tracks.count) track\(tracks.count == 1 ? "" : "s") from \(playlist.name) to the session queue."
    }

    func saveSessionQueueAsPlaylist(named rawName: String) {
        guard !sessionQueue.isEmpty else {
            statusMessage = "Session queue is empty."
            return
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let message = "Playlist name is required."
            statusMessage = message
            lastError = message
            return
        }

        do {
            let playlist = try localMusicLibrary.saveSessionPlaylist(
                name: name,
                tracks: sessionQueue
            )
            if !localMusicSettings.m3uPlaylistPaths.contains(playlist.path) {
                localMusicSettings.m3uPlaylistPaths.append(playlist.path)
            }
            localMusicPlaylists.removeAll { $0.id == playlist.id }
            localMusicPlaylists.append(playlist)
            selectedLocalMusicPlaylistID = playlist.id
            persistLocalMusicDatabase()
            statusMessage = "Saved session queue as \(playlist.name)."
            AppLogger.shared.notice(category: "local-music", "Saved session queue playlist tracks=\(sessionQueue.count) path=\(playlist.path)")
        } catch {
            let message = "Could not save session queue playlist: \(error.localizedDescription)"
            statusMessage = message
            lastError = message
            AppLogger.shared.error(category: "local-music", message)
        }
    }

    private func moveLocalMusicPlaylistTrack(in playlist: LocalMusicPlaylist, from sourceIndex: Int, to destinationIndex: Int) {
        guard playlist.trackPaths.indices.contains(sourceIndex),
              playlist.trackPaths.indices.contains(destinationIndex),
              sourceIndex != destinationIndex
        else { return }

        var trackPaths = playlist.trackPaths
        trackPaths.swapAt(sourceIndex, destinationIndex)

        do {
            let updated = try localMusicLibrary.updateEditablePlaylist(
                playlist,
                trackPaths: trackPaths,
                knownTracks: localMusicTracks
            )
            replaceLocalMusicPlaylist(playlist.id, with: updated)
            selectedLocalMusicPlaylistID = updated.id
            persistLocalMusicDatabase()
            statusMessage = "Reordered \(updated.name)."
        } catch {
            handleLocalMusicPlaylistMutationError(error, logPrefix: "Could not reorder playlist")
        }
    }

    private func moveLocalMusicPlaylist(_ playlist: LocalMusicPlaylist, offset: Int) {
        guard let sourceIndex = localMusicPlaylists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let destinationIndex = sourceIndex + offset
        guard localMusicPlaylists.indices.contains(destinationIndex) else { return }

        localMusicPlaylists.swapAt(sourceIndex, destinationIndex)
        syncRegisteredPlaylistPathOrderWithVisiblePlaylistOrder()
        selectedLocalMusicPlaylistID = playlist.id
        persistLocalMusicDatabase()
        statusMessage = "Moved \(playlist.name) \(offset < 0 ? "up" : "down")."
    }

    private func validatedPlaylistName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LocalMusicPlaylistMutationError.invalidName
        }
        return name
    }

    private func editableLocalMusicPlaylist(named name: String) -> LocalMusicPlaylist? {
        localMusicPlaylists.first { playlist in
            isEditableLocalMusicPlaylist(playlist) &&
                playlist.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func registerLocalMusicPlaylist(_ playlist: LocalMusicPlaylist) {
        if !localMusicSettings.m3uPlaylistPaths.contains(playlist.path) {
            localMusicSettings.m3uPlaylistPaths.append(playlist.path)
        }
        replaceLocalMusicPlaylist(playlist.id, with: playlist)
    }

    private func replaceRegisteredPlaylistPath(oldPath: String, newPath: String) {
        if let index = localMusicSettings.m3uPlaylistPaths.firstIndex(of: oldPath) {
            localMusicSettings.m3uPlaylistPaths[index] = newPath
        } else if !localMusicSettings.m3uPlaylistPaths.contains(newPath) {
            localMusicSettings.m3uPlaylistPaths.append(newPath)
        }
    }

    private func replaceLocalMusicPlaylist(_ oldID: String, with playlist: LocalMusicPlaylist) {
        if let index = localMusicPlaylists.firstIndex(where: { $0.id == oldID || $0.id == playlist.id }) {
            localMusicPlaylists[index] = playlist
            localMusicPlaylists.removeAll { $0.id != playlist.id && ($0.id == oldID || $0.id == playlist.id) }
        } else {
            localMusicPlaylists.append(playlist)
        }
        syncRegisteredPlaylistPathOrderWithVisiblePlaylistOrder()
    }

    private func orderedLocalMusicPlaylistsAfterScan(_ scannedPlaylists: [LocalMusicPlaylist]) -> [LocalMusicPlaylist] {
        let scannedByID = Dictionary(uniqueKeysWithValues: scannedPlaylists.map { ($0.id, $0) })
        var seenIDs = Set<String>()
        let preserved = localMusicPlaylists.compactMap { playlist -> LocalMusicPlaylist? in
            guard let scanned = scannedByID[playlist.id], seenIDs.insert(playlist.id).inserted else { return nil }
            return scanned
        }
        let additions = scannedPlaylists.filter { seenIDs.insert($0.id).inserted }
        return preserved + additions
    }

    private func syncRegisteredPlaylistPathOrderWithVisiblePlaylistOrder() {
        let registeredPaths = Set(localMusicSettings.m3uPlaylistPaths)
        let visibleRegisteredPaths = localMusicPlaylists
            .map(\.path)
            .filter { registeredPaths.contains($0) }
        let hiddenRegisteredPaths = localMusicSettings.m3uPlaylistPaths
            .filter { !visibleRegisteredPaths.contains($0) }
        localMusicSettings.m3uPlaylistPaths = visibleRegisteredPaths + hiddenRegisteredPaths
    }

    private func handleLocalMusicPlaylistMutationError(_ error: Error, logPrefix: String) {
        let message = error.localizedDescription
        statusMessage = message
        if (error as? LocalMusicPlaylistMutationError) != .duplicateTrack {
            lastError = message
        }
        AppLogger.shared.error(category: "local-music", "\(logPrefix): \(message)")
    }

    func clearSessionQueue() {
        cancelPendingLocalFileLoad()
        clearLocalPreparedFilePreloads(reason: "session queue cleared")
        sessionQueue = []
        sessionQueueIndex = nil
        selectedSessionQueueIndex = nil
        pendingSessionQueueIndex = nil
        rebuildLocalGaplessQueueAfterSessionMutation(reason: "session queue cleared")
        statusMessage = "Session queue cleared."
    }

    func moveSessionQueueItemUp(_ index: Int) {
        moveSessionQueueItem(from: index, to: index - 1)
    }

    func moveSessionQueueItemDown(_ index: Int) {
        moveSessionQueueItem(from: index, to: index + 1)
    }

    func removeSessionQueueItem(_ index: Int) {
        guard sessionQueue.indices.contains(index) else { return }

        clearLocalPreparedFilePreloads(reason: "session queue item removed")
        let removed = sessionQueue.remove(at: index)

        if sessionQueue.isEmpty {
            sessionQueueIndex = nil
            selectedSessionQueueIndex = nil
            pendingSessionQueueIndex = nil
        } else if let currentIndex = sessionQueueIndex {
            if currentIndex == index {
                refreshSessionQueueIndexForCurrentFile()
            } else if index < currentIndex {
                sessionQueueIndex = currentIndex - 1
            }
        }

        if let selectedIndex = selectedSessionQueueIndex {
            if selectedIndex == index {
                selectedSessionQueueIndex = nil
            } else if index < selectedIndex {
                selectedSessionQueueIndex = selectedIndex - 1
            }
        }

        if let pendingIndex = pendingSessionQueueIndex {
            if pendingIndex == index {
                cancelPendingLocalFileLoad()
            } else if index < pendingIndex {
                pendingSessionQueueIndex = pendingIndex - 1
            }
        }

        rebuildLocalGaplessQueueAfterSessionMutation(reason: "session queue item removed")
        statusMessage = "Removed \(removed.displayTitle) from the session queue."
    }

    func playLocalMusicPlaylist(_ playlist: LocalMusicPlaylist, shuffle: Bool = false) {
        let tracks = tracks(for: playlist)
        guard !tracks.isEmpty else {
            statusMessage = "\(playlist.name) has no playable tracks in the current library."
            return
        }

        selectedLocalMusicPlaylistID = playlist.id
        startSessionQueue(from: tracks, startTrackID: tracks.first?.id, shuffle: shuffle, autoplay: true)
    }

    var localMusicCountText: String {
        let total = localMusicTracks.count
        let visible = visibleLocalMusicTracks.count

        if localMusicSettings.watchFolderPaths.isEmpty && localMusicSettings.m3uPlaylistPaths.isEmpty {
            return "Add watch folders or M3U playlists in Settings."
        }

        if total == 0 {
            return "No audio files scanned yet."
        }

        let hasSearch = !localMusicSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasSearch && localMusicChannelFilter == 0 {
            return "\(total) tracks."
        }

        return "\(visible) of \(total) shown."
    }

    var localMusicWatchFolderText: String {
        let count = localMusicSettings.watchFolderPaths.count
        return count == 1 ? "1 watch folder." : "\(count) watch folders."
    }

    var localMusicPlaylistCountText: String {
        let count = localMusicPlaylists.count
        return count == 1 ? "1 playlist." : "\(count) playlists."
    }

    var localMusicQueueText: String {
        guard !sessionQueue.isEmpty else { return "Queue is empty." }
        let current = sessionQueueIndex.map { $0 + 1 } ?? 0
        return current > 0 ? "\(current) of \(sessionQueue.count)" : "\(sessionQueue.count) queued."
    }

    var localMusicDatabasePath: String {
        localMusicLibrary.databasePath
    }

    var localMusicArtworkDirectoryPath: String {
        localMusicLibrary.artworkDirectoryPath
    }

    var localMusicSavedPlaylistDirectoryPath: String {
        localMusicLibrary.playlistDirectoryPath
    }

    var localMusicArtworkStatusText: String {
        let count = localMusicTracks.filter { $0.artworkPath != nil }.count
        return "\(count) tracks with cached artwork."
    }

    var currentLocalArtworkURL: URL? {
        guard let path = visibleLocalPlaybackTrack?.artworkPath else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    var spotifyArtworkURL: URL? {
        guard let coverURL = spotifyNowPlayingForActiveStatus?.coverURL else { return nil }
        return URL(string: coverURL)
    }

    var availableLocalMusicChannelCounts: [Int] {
        Array(Set(localMusicTracks.map { $0.channelCount }.filter { $0 > 0 })).sorted()
    }

    var visibleLocalMusicTracks: [LocalMusicTrack] {
        let query = localMusicSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelFilter = localMusicChannelFilter
        let sortedTracks = channelFilter > 0
            ? sortedLocalMusicTracks.filter { $0.channelCount == channelFilter }
            : sortedLocalMusicTracks
        guard !query.isEmpty else { return sortedTracks }

        return sortedTracks.filter { track in track.matches(query) }
    }

    var selectedLocalMusicTrack: LocalMusicTrack? {
        guard let selectedLibraryTrackID else { return nil }
        return localMusicTracks.first { $0.id == selectedLibraryTrackID }
    }

    var currentLocalMusicTrack: LocalMusicTrack? {
        guard let currentFileURL else { return nil }
        return localMusicTracks.first { $0.id == currentFileURL.path }
    }

    var selectedLocalMusicPlaylist: LocalMusicPlaylist? {
        guard let selectedLocalMusicPlaylistID else { return nil }
        return localMusicPlaylists.first { $0.id == selectedLocalMusicPlaylistID }
    }

    var editableLocalMusicPlaylists: [LocalMusicPlaylist] {
        localMusicPlaylists.filter(isEditableLocalMusicPlaylist)
    }

    func isEditableLocalMusicPlaylist(_ playlist: LocalMusicPlaylist) -> Bool {
        localMusicLibrary.isEditablePlaylist(playlist)
    }

    var currentQueueTrack: LocalMusicTrack? {
        guard let sessionQueueIndex, sessionQueue.indices.contains(sessionQueueIndex) else { return nil }
        return sessionQueue[sessionQueueIndex]
    }

    private var audibleLocalPlaybackTrack: LocalMusicTrack? {
        currentQueueTrack ?? currentLocalMusicTrack
    }

    private var hasAudibleLocalPresentation: Bool {
        audibleLocalPlaybackTrack != nil || currentFileURL != nil || sourceMetadata != nil
    }

    var visibleLocalPlaybackTrack: LocalMusicTrack? {
        if let audibleLocalPlaybackTrack {
            return audibleLocalPlaybackTrack
        }

        if !hasAudibleLocalPresentation,
           isLocalFileLoading,
           let pendingSessionQueueIndex,
           sessionQueue.indices.contains(pendingSessionQueueIndex) {
            return sessionQueue[pendingSessionQueueIndex]
        }

        return nil
    }

    var visibleLocalSourceMetadata: AudioSourceMetadata? {
        if let sourceMetadata {
            return sourceMetadata
        }

        if !hasAudibleLocalPresentation,
           isLocalFileLoading,
           let pendingLocalSourceMetadata {
            return pendingLocalSourceMetadata
        }

        return nil
    }

    var pureSphericalLosslessBadgePresentation: PureSphericalLosslessBadgePresentation? {
        PureSphericalLosslessBadgePresenter.presentation(for: pureSphericalLosslessState)
    }

    private func updatePureSphericalLosslessState(for url: URL) {
        do {
            pureSphericalLosslessState = try validatePureSphericalLosslessFile(
                url: url,
                currentSphere: currentPureSphericalSphereProfile(),
                route: currentPureSphericalOutputRouteDescriptor()
            ).state
        } catch {
            pureSphericalLosslessState = .none
            AppLogger.shared.warning(
                category: "pure-spherical",
                "Pure Spherical Lossless validation failed file=\(url.lastPathComponent) error=\(error.localizedDescription)"
            )
        }
    }

    private func reevaluatePureSphericalLosslessStateForCurrentFile() {
        guard sourceMode == .filePlayback, let currentFileURL else {
            pureSphericalLosslessState = .none
            return
        }
        updatePureSphericalLosslessState(for: currentFileURL)
    }

    private func validatePureSphericalLosslessFile(
        url: URL,
        currentSphere: SonicSphereProfile?,
        route: AudioContracts.OutputRouteDescriptor?
    ) throws -> PureSphericalLosslessValidation {
        try pureSphericalLosslessValidator.validate(
            url: url,
            currentSphere: currentSphere,
            route: route
        )
    }

    private func currentPureSphericalSphereProfile() -> SonicSphereProfile? {
        let outputCount = max(
            rendererScene.outputSpeakers.count,
            rendererPreset.outputTopology.fullRangeCount + rendererPreset.outputTopology.lfeCount
        )
        guard outputCount > 0 else { return nil }

        let routeSampleRate = try? AudioSampleRate(hertz: rendererOutputRoute.nominalSampleRate)
        let sampleRate = routeSampleRate ?? .defaultProduction
        let outputLayout = outputCount == AudioChannelLayoutDescriptor.direct31.channelCount
            ? AudioChannelLayoutDescriptor.direct31
            : AudioChannelLayoutDescriptor.discrete(count: outputCount)

        return SonicSphereProfile(
            id: "sonic-sphere-31-reference",
            outputMapID: "direct-30.1-logical",
            sampleRate: sampleRate,
            outputChannelCount: outputCount,
            outputLayout: outputLayout
        )
    }

    private func currentPureSphericalOutputRouteDescriptor() -> AudioContracts.OutputRouteDescriptor? {
        guard rendererOutputSelection != .none else { return nil }
        return RouteCapabilityValidator().outputRouteDescriptor(from: rendererOutputRoute)
    }

    private func queueTrack(for index: Int) -> LocalMusicTrack? {
        sessionQueue.indices.contains(index) ? sessionQueue[index] : nil
    }

    func tracks(for playlist: LocalMusicPlaylist) -> [LocalMusicTrack] {
        let tracksByPath = Dictionary(uniqueKeysWithValues: localMusicTracks.map { ($0.path, $0) })
        return playlist.trackPaths.compactMap { tracksByPath[$0] }
    }

#if DEBUG
    func replaceLocalMusicQueueForTesting(
        tracks: [LocalMusicTrack],
        currentIndex: Int?,
        selectedIndex: Int?
    ) {
        clearLocalPreparedFilePreloads(reason: "test local music queue replaced")
        localMusicBaseTracks = tracks
        localMusicTracks = tracks
        sessionQueue = tracks
        sessionQueueIndex = currentIndex
        selectedSessionQueueIndex = selectedIndex
        selectedLibraryTrackID = nil
        pendingSessionQueueIndex = nil
        clearPendingLocalPresentation()
    }

    func setActivityForTesting(_ activity: PlaybackActivity) {
        self.activity = activity
    }

    func setSourceModeForTesting(_ mode: SourceMode) {
        sourceMode = mode
        if mode != .spotify {
            clearSpotifyVisibleState(reason: "test source changed")
        }
    }

    func setSpotifyNowPlayingForTesting(_ nowPlaying: SpotifyNowPlaying?) {
        lastSpotifyNowPlayingRefreshTime = .distantFuture
        updateSpotifyNowPlaying(nowPlaying, reason: "test", forceVisible: true)
    }

    func setSpotifyReceiverStatusForTesting(_ status: SpotifyReceiverStatus) {
        spotifyReceiverStatus = status
    }

    func setLiveMonitorStateForTesting(_ state: LiveMonitorState) {
        liveMonitorState = state
    }

    func setLiveAudioSignalStateForTesting(_ state: LiveAudioSignalState, silenceDuration: Int? = nil) {
        liveAudioSignalState = state
        liveAudioSignalSilenceDuration = silenceDuration
        lastLiveSignalDetectedSecond = state == .receiving ? 0 : nil
        lastLiveSignalPresent = state == .receiving
    }

    func setRoonBridgeSnapshotForTesting(_ snapshot: RoonBridgeSnapshot) {
        roonBridgeSnapshot = snapshot
    }

    func setInputRouteForTesting(_ route: InputRouteInfo, availableRoutes: [InputRouteInfo]? = nil) {
        inputRoute = route
        if let availableRoutes {
            self.availableInputRoutes = availableRoutes
        }
    }

    func applySpotifyNowPlayingForTesting(_ nowPlaying: SpotifyNowPlaying?) {
        lastSpotifyNowPlayingRefreshTime = .distantFuture
        updateSpotifyNowPlaying(nowPlaying, reason: "test")
    }

    func waitForSpotifyPlaybackStatusDebounceForTesting() async {
        let task = spotifyPlaybackStatusDebounceTask
        await task?.value
    }

    func setRoonNowPlayingForTesting(_ nowPlaying: RoonNowPlaying?) {
        roonNowPlaying = nowPlaying
        roonNowPlayingStatus = nowPlaying?.updatedText ?? "No Roon playback line found in RoonServer log yet."
    }

    func setAtmosDRPStateForTesting(
        track: LocalMusicTrack?,
        state: DolbyReferencePlayerSessionState,
        bitstreamInfo: DolbyBitstreamInfo? = nil
    ) {
        sourceMode = .atmosDRP
        currentAtmosDRPTrack = track
        currentFileURL = track?.url
        isPlaying = state == .playing
        liveMonitorState = state == .playing ? .monitoring : .stopped
        if let track, !localMusicTracks.contains(where: { $0.id == track.id }) {
            localMusicBaseTracks.append(track)
            localMusicTracks.append(track)
        }
        duration = track?.duration ?? 0
        currentTime = min(42, duration)
        scrubProgress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
        let session = track.map {
            DolbyReferencePlayerSession(
                fileURL: $0.url,
                processIdentifier: 12_345,
                metadataDirectoryURL: FileManager.default.temporaryDirectory,
                outputDevice: DolbyReferencePlayerDevice(
                    id: 7,
                    name: AtmosDRPRoutingPolicy.drpOutputDeviceName,
                    channelCount: 64
                ),
                outputLayout: atmosDRPOutputLayout,
                startedAt: Date().addingTimeInterval(-currentTime),
                state: state,
                pausedAt: state == .paused ? Date() : nil,
                accumulatedPausedDuration: 0
            )
        }
        dolbyReferencePlayerSnapshot = DolbyReferencePlayerControllerSnapshot(
            session: session,
            bitstreamInfo: bitstreamInfo,
            lastOutput: "",
            lastError: state == .failed ? "Dolby Reference Player exited with status 1." : nil
        )
    }

    @discardableResult
    func playQueueIndexForTesting(_ index: Int) -> Bool {
        playQueueIndex(index)
    }

    static var adjacentFullLocalPCMPreloadEnabledByDefaultForTesting: Bool {
        preloadsAdjacentLocalMusicTracksByDefault
    }

    var adjacentFullLocalPCMPreloadEnabledForTesting: Bool {
        Self.enableAdjacentLocalPCMPreload && preloadsAdjacentLocalMusicTracks
    }

    func loadQueueIndexForTesting(_ index: Int, autoplay: Bool = false, isPlaying: Bool = false) async throws {
        guard sessionQueue.indices.contains(index) else { return }
        let track = sessionQueue[index]
        _ = loadFile(
            url: track.url,
            autoplay: autoplay,
            queueCommit: LocalFileQueueCommit(index: index, trackID: track.id, isNaturalAdvance: false)
        )
        while isLocalFileLoading {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        self.isPlaying = isPlaying
    }

    func hasPreparedLocalFileForTesting(path: String) -> Bool {
        localPreparedFileCache.containsValid(for: URL(fileURLWithPath: path))
    }

    func awaitNextTrackPreloadForTesting() async {
        await localPreparedFilePreloadTask?.value
    }

    func setPreloadStatusForTesting(_ status: NextTrackPreloadStatus) {
        nextTrackPreloadStatus = status
    }

    func hasCachedLocalDescriptorForTesting(path: String) -> Bool {
        localAudioDescriptorCache.containsValid(for: URL(fileURLWithPath: path))
    }

    @discardableResult
    func cachePreparedLocalFileForTesting(_ loaded: LoadedAudioFile) -> String {
        guard let key = PreparedLocalFileKey.make(for: loaded.url) else {
            return "file changed"
        }

        let result = localPreparedFileCache.store(loaded, for: loaded.url, expectedKey: key)
        return result.reason
    }

    func triggerPlaybackEndedForTesting() {
        handlePlaybackEnded()
    }

    func triggerLocalGaplessLogicalTrackStartedForTesting(_ descriptor: LocalGaplessTrackDescriptor) {
        handleLocalGaplessLogicalTrackStarted(descriptor)
    }

    func triggerLocalGaplessLogicalTrackEndedForTesting(_ descriptor: LocalGaplessTrackDescriptor) {
        handleLocalGaplessLogicalTrackEnded(descriptor)
    }

    func triggerLocalGaplessQueueEndedForTesting() {
        handleLocalGaplessQueueEnded()
    }

    var isLocalGaplessEngineQueueActiveForTesting: Bool {
        isLocalGaplessEngineQueueActive
    }

    func waitForLocalMusicMetadataEnrichmentForTesting() async {
        await localMusicMetadataEnrichmentTask?.value
    }

    var localMusicMetadataOverlaysForTesting: [String: LocalMusicMetadataOverlay] {
        localMusicMetadataOverlays
    }
#endif

    private var cachedSortedLocalMusicTracks: [LocalMusicTrack]?

    #if DEBUG
    private(set) var localMusicSortComputeCountForTesting = 0
    #endif

    private func invalidateSortedLocalMusicTracksCache() {
        cachedSortedLocalMusicTracks = nil
    }

    // Memoized: sorting the whole library is expensive and this is read on every
    // SwiftUI body eval and web poll. Invalidated when tracks or sort mode change.
    private var sortedLocalMusicTracks: [LocalMusicTrack] {
        if let cached = cachedSortedLocalMusicTracks {
            return cached
        }
        let sorted = localMusicTracks.sorted(by: localMusicComparator)
        cachedSortedLocalMusicTracks = sorted
        #if DEBUG
        localMusicSortComputeCountForTesting += 1
        #endif
        return sorted
    }

    @discardableResult
    private func loadFile(
        url: URL,
        autoplay: Bool,
        queueCommit: LocalFileQueueCommit? = nil,
        kind: LocalFileLoadKind = .selectedTrack,
        startPolicy: LocalFileLoadStartPolicy = .immediate,
        debugTiming: DebugTimingContext? = nil
    ) -> Bool {
        let request = nextLocalFileLoadRequest(
            url: url,
            autoplay: autoplay,
            queueCommit: queueCommit,
            kind: kind,
            startPolicy: startPolicy,
            debugTiming: debugTiming
        )
        resetLocalGaplessHandoffState(reason: "new local file request")
        pendingSessionQueueIndex = queueCommit?.index
        logLocalTransportTiming(
            debugTiming,
            "user intent received",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: url,
            extra: [
                "generation=\(request.generation)",
                "autoplay=\(autoplay)",
                "startPolicy=\"\(String(describing: startPolicy))\"",
                "kind=\"\(String(describing: kind))\""
            ]
        )
        logLocalTransportTiming(
            debugTiming,
            "pending target set",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: url
        )
        logLocalPlayNowDebug(
            "load requested",
            request: request,
            loadStarted: false
        )
        statusMessage = requestImmediateStatus(request)
        isLocalFileLoading = true
        activity = PlaybackActivity(phase: .probing, detail: localLoadActivityName(for: request))
        publishPendingLocalIntent(for: request)
        logLocalTransportTiming(
            debugTiming,
            "UI state published",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: url,
            extra: ["status=\"\(statusMessage)\""]
        )
        lastError = nil
        cancelLocalPreparedFilePreload(debugTiming: debugTiming, reason: "new local playback generation \(request.generation)")

        if let loaded = preparedLocalFile(for: request) {
            finishPreparedLocalFileLoad(loaded, request: request)
            return true
        }

        startLocalFileLoadStatusTask(for: request)

        queueLocalFileLoadForStart(request)
        return true
    }

    private func nextLocalFileLoadRequest(
        url: URL,
        autoplay: Bool,
        queueCommit: LocalFileQueueCommit?,
        kind: LocalFileLoadKind,
        startPolicy: LocalFileLoadStartPolicy,
        debugTiming: DebugTimingContext?
    ) -> LocalFileLoadRequest {
        let generation = nextLocalPlaybackGeneration()
        return LocalFileLoadRequest(
            id: generation,
            generation: generation,
            url: url,
            autoplay: autoplay,
            queueCommit: queueCommit,
            kind: kind,
            startPolicy: startPolicy,
            debugTiming: debugTiming,
            requestedFromSource: sourceMode,
            isLocalPlayNow: debugTiming?.id.hasPrefix("local-play-now-") == true
        )
    }

    private func nextLocalPlaybackGeneration() -> UInt64 {
        localFileLoadSequence = max(localFileLoadSequence, currentLocalFileLoadGeneration)
        localFileLoadSequence &+= 1
        currentLocalFileLoadGeneration = localFileLoadSequence
        return currentLocalFileLoadGeneration
    }

    private func isCurrentLocalPlaybackGeneration(_ generation: UInt64) -> Bool {
        currentLocalFileLoadGeneration == generation
    }

    private func requestTrackTitle(_ request: LocalFileLoadRequest) -> String? {
        request.queueCommit.flatMap { queueTrack(for: $0.index)?.displayTitle }
    }

    private func localLoadActivityName(for request: LocalFileLoadRequest) -> String {
        requestTrackTitle(request) ?? request.url.deletingPathExtension().lastPathComponent
    }

    /// Reset activity to idle only if it currently reflects a load phase, so a
    /// concurrent output-device switch overlay is never clobbered.
    private func endLoadActivityIfLoading() {
        switch activity.phase {
        case .probing, .decoding, .converting, .preparing:
            activity = .idle
        case .idle, .switchingOutput:
            break
        }
    }

    private func requestImmediateStatus(_ request: LocalFileLoadRequest) -> String {
        request.kind.immediateStatus(
            trackTitle: requestTrackTitle(request),
            fileName: request.url.lastPathComponent
        )
    }

    private func track(for request: LocalFileLoadRequest) -> LocalMusicTrack? {
        if let queueCommit = request.queueCommit,
           sessionQueue.indices.contains(queueCommit.index),
           sessionQueue[queueCommit.index].id == queueCommit.trackID {
            return sessionQueue[queueCommit.index]
        }

        return localMusicTracks.first { $0.id == request.url.path }
    }

    private func publishPendingLocalIntent(for request: LocalFileLoadRequest) {
        guard isCurrentLocalPlaybackGeneration(request.generation) else { return }

        pendingLocalPresentationGeneration = request.generation
        pendingLocalAssetDescriptor = nil
        pendingLocalSourceMetadata = pendingMetadata(for: request)
        loadedFileName = request.url.lastPathComponent

        if let track = track(for: request) {
            duration = track.duration
            loadedChannels = SurroundLayoutDetector.fallbackLayout(for: track.channelCount).channels
        } else {
            duration = 0
            loadedChannels = []
        }
        currentTime = 0
        scrubProgress = 0
    }

    private func publishPendingLocalDescriptor(_ descriptor: AudioAssetDescriptor, for request: LocalFileLoadRequest) {
        guard activeLocalFileLoadRequest?.id == request.id,
              isCurrentLocalPlaybackGeneration(request.generation)
        else {
            logLocalTransportTiming(
                request.debugTiming,
                "stale descriptor discarded",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: request.url,
                extra: [
                    "reason=\"descriptor completed for stale local load\"",
                    "generation=\(request.generation)",
                    "currentGeneration=\(currentLocalFileLoadGeneration)"
                ]
            )
            return
        }

        pendingLocalPresentationGeneration = request.generation
        pendingLocalAssetDescriptor = descriptor
        pendingLocalSourceMetadata = pendingMetadata(for: descriptor, request: request)
        loadedFileName = descriptor.url.lastPathComponent
        duration = descriptor.durationSeconds ?? 0
        currentTime = 0
        scrubProgress = 0
        loadedChannels = descriptor.channelLayout.channels
        logLocalTransportTiming(
            request.debugTiming,
            "UI descriptor state published",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: request.url,
            extra: descriptor.logFields
        )
    }

    private func clearPendingLocalPresentation(generation: UInt64? = nil) {
        if let generation,
           let pendingLocalPresentationGeneration,
           pendingLocalPresentationGeneration != generation {
            return
        }

        pendingLocalPresentationGeneration = nil
        pendingLocalAssetDescriptor = nil
        pendingLocalSourceMetadata = nil
    }

    private func pendingMetadata(for request: LocalFileLoadRequest) -> AudioSourceMetadata {
        let track = track(for: request)
        let channelCount = track?.channelCount ?? 0
        let layout = channelCount > 0
            ? SurroundLayoutDetector.fallbackLayout(for: channelCount)
            : SurroundLayout(name: "Probing", channels: [])
        let layoutSource = "Pending local library metadata"

        return AudioSourceMetadata(
            fileName: request.url.lastPathComponent,
            containerName: request.url.pathExtension.trimmedNilIfBlank?.uppercased() ?? "Unknown",
            codecName: "Probing",
            layoutName: track?.layoutName ?? layout.name,
            channelSummary: track?.channelSummary ?? layout.channelSummary,
            channelCount: channelCount,
            sampleRate: track?.sampleRate ?? 0,
            bitDepth: 0,
            duration: track?.duration ?? 0,
            title: track?.title?.trimmedNilIfBlank,
            album: track?.album?.trimmedNilIfBlank,
            artist: track?.artist?.trimmedNilIfBlank,
            formatNote: "Preparing full playback buffers.",
            channelLayoutConfidence: AudioSourceMetadata.fallbackLayoutConfidence(for: channelCount),
            channelLayoutSourceDescription: layoutSource,
            channelLayoutWarnings: AudioSourceMetadata.fallbackLayoutWarnings(
                channelCount: channelCount,
                channelSummary: layout.channelSummary,
                sourceDescription: layoutSource
            )
        )
    }

    private func pendingMetadata(
        for descriptor: AudioAssetDescriptor,
        request: LocalFileLoadRequest
    ) -> AudioSourceMetadata {
        let track = track(for: request)
        let layoutSource = "Audio asset descriptor channel layout"
        return AudioSourceMetadata(
            fileName: descriptor.url.lastPathComponent,
            containerName: descriptor.containerDescription ?? descriptor.url.pathExtension.trimmedNilIfBlank?.uppercased() ?? "Unknown",
            codecName: descriptor.codecDescription ?? "Unknown",
            layoutName: descriptor.channelLayout.name,
            channelSummary: descriptor.channelLayout.channelSummary,
            channelCount: descriptor.channelCount,
            sampleRate: descriptor.sourceSampleRate,
            bitDepth: 0,
            duration: descriptor.durationSeconds ?? 0,
            title: track?.title?.trimmedNilIfBlank,
            album: track?.album?.trimmedNilIfBlank,
            artist: track?.artist?.trimmedNilIfBlank,
            formatNote: "Descriptor ready; preparing full playback buffers.",
            channelLayoutConfidence: AudioSourceMetadata.fallbackLayoutConfidence(for: descriptor.channelCount),
            channelLayoutSourceDescription: layoutSource,
            channelLayoutWarnings: AudioSourceMetadata.fallbackLayoutWarnings(
                channelCount: descriptor.channelCount,
                channelSummary: descriptor.channelLayout.channelSummary,
                sourceDescription: layoutSource
            )
        )
    }

    private func localGaplessQueueSnapshot(for queueCommit: LocalFileQueueCommit?) -> LocalGaplessEngineQueueSnapshot? {
        guard LocalGaplessPlaybackPolicy.enableLocalGaplessScheduler,
              let queueCommit,
              sessionQueue.indices.contains(queueCommit.index),
              sessionQueue[queueCommit.index].id == queueCommit.trackID
        else { return nil }

        return localGaplessQueueSnapshot(startIndex: queueCommit.index)
    }

    private func localGaplessQueueSnapshot(startIndex: Int) -> LocalGaplessEngineQueueSnapshot? {
        guard LocalGaplessPlaybackPolicy.enableLocalGaplessScheduler,
              sessionQueue.indices.contains(startIndex)
        else { return nil }

        let descriptors = sessionQueue.enumerated().map { index, track in
            LocalGaplessTrackDescriptor(
                id: track.id,
                url: track.url,
                queueIndex: index,
                displayName: track.displayTitle
            )
        }
        return LocalGaplessEngineQueueSnapshot(tracks: descriptors, startIndex: startIndex)
    }

    private func resetLocalGaplessHandoffState(reason: String) {
        guard isLocalGaplessEngineQueueActive
            || localGaplessQueueEndAwaitingPlaybackEnded
            || !finalizedLocalGaplessQueueIndices.isEmpty
        else { return }

        AppLogger.shared.debug(
            category: LocalGaplessSchedulerLog.category,
            "Reset local gapless handoff state reason=\"\(reason)\""
        )
        isLocalGaplessEngineQueueActive = false
        localGaplessQueueEndAwaitingPlaybackEnded = false
        finalizedLocalGaplessQueueIndices.removeAll()
    }

    private func rebuildLocalGaplessQueueAfterSessionMutation(reason: String) {
        guard LocalGaplessPlaybackPolicy.enableLocalGaplessScheduler,
              isLocalGaplessEngineQueueActive,
              sourceMode == .filePlayback
        else { return }

        localGaplessQueueEndAwaitingPlaybackEnded = false
        finalizedLocalGaplessQueueIndices.removeAll()

        guard let currentTrackID = currentFileURL?.path,
              let currentIndex = sessionQueue.firstIndex(where: { $0.id == currentTrackID }),
              let snapshot = localGaplessQueueSnapshot(startIndex: currentIndex)
        else {
            AppLogger.shared.notice(
                category: LocalGaplessSchedulerLog.category,
                "Stopping local gapless playback after queue mutation removed the current logical track. reason=\"\(reason)\""
            )
            stop()
            return
        }

        sessionQueueIndex = currentIndex
        if engine.rebuildLocalGaplessQueue(snapshot, reason: reason) {
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                "Rebuilt view-model local gapless queue reason=\"\(reason)\" currentIndex=\(currentIndex) queueCount=\(sessionQueue.count)"
            )
        } else {
            AppLogger.shared.notice(
                category: LocalGaplessSchedulerLog.category,
                "Stopping local gapless playback after queue mutation rebuild was rejected. reason=\"\(reason)\""
            )
            stop()
        }
    }

    private func handleLocalGaplessLogicalTrackStarted(_ descriptor: LocalGaplessTrackDescriptor) {
        guard sourceMode == .filePlayback,
              let queueIndex = descriptor.queueIndex,
              sessionQueue.indices.contains(queueIndex),
              sessionQueue[queueIndex].id == descriptor.id
        else {
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                "Ignored local gapless logical start for stale queue item file=\(descriptor.url.lastPathComponent)"
            )
            return
        }

        if !isLocalGaplessEngineQueueActive {
            finalizedLocalGaplessQueueIndices.removeAll()
        }
        isLocalGaplessEngineQueueActive = true
        localGaplessQueueEndAwaitingPlaybackEnded = false
        finalizedLocalGaplessQueueIndices.remove(queueIndex)

        let track = sessionQueue[queueIndex]
        clearPendingLocalPresentation()
        pendingSessionQueueIndex = nil
        sessionQueueIndex = queueIndex
        selectedSessionQueueIndex = queueIndex
        loadedFileName = track.fileName
        currentFileURL = track.url
        sourceMetadata = localGaplessMetadata(for: track)
        loadedChannels = SurroundLayoutDetector.fallbackLayout(for: track.channelCount).channels
        duration = track.duration
        currentTime = 0
        scrubProgress = 0
        meterStore.configure(channels: loadedChannels)
        meterStore.reset()
        monitorMeterStore.reset()
        updateRendererMeters(from: Array(repeating: 0, count: max(track.channelCount, 1)))
        isPlaying = true
        statusMessage = "Playing \(track.displayTitle) through \(routeDisplayName) with \(rendererScene.renderMode.displayName)."
        scheduleAdjacentLocalFilePreloads(reason: "gapless logical start \(track.fileName)")
        AppLogger.shared.debug(
            category: LocalGaplessSchedulerLog.category,
            "Committed local gapless logical track file=\(track.fileName) queueIndex=\(queueIndex)"
        )
    }

    private func handleLocalGaplessLogicalTrackEnded(_ descriptor: LocalGaplessTrackDescriptor) {
        guard sourceMode == .filePlayback,
              isLocalGaplessEngineQueueActive,
              let queueIndex = descriptor.queueIndex,
              sessionQueue.indices.contains(queueIndex),
              sessionQueue[queueIndex].id == descriptor.id
        else {
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                "Ignored local gapless logical end for stale queue item file=\(descriptor.url.lastPathComponent)"
            )
            return
        }

        guard finalizedLocalGaplessQueueIndices.insert(queueIndex).inserted else {
            AppLogger.shared.debug(
                category: LocalGaplessSchedulerLog.category,
                "Ignored duplicate local gapless logical end file=\(descriptor.url.lastPathComponent) queueIndex=\(queueIndex)"
            )
            return
        }

        if sessionQueueIndex == queueIndex {
            currentTime = duration
            if duration > 0 {
                scrubProgress = 1
            }
        }

        AppLogger.shared.debug(
            category: LocalGaplessSchedulerLog.category,
            "Finalized local gapless logical track file=\(descriptor.url.lastPathComponent) queueIndex=\(queueIndex)"
        )
    }

    private func handleLocalGaplessQueueEnded() {
        guard sourceMode == .filePlayback,
              isLocalGaplessEngineQueueActive
        else { return }

        localGaplessQueueEndAwaitingPlaybackEnded = true
        AppLogger.shared.debug(
            category: LocalGaplessSchedulerLog.category,
            "Local gapless queue ended; awaiting physical playback completion."
        )
    }

    private func localGaplessMetadata(for track: LocalMusicTrack) -> AudioSourceMetadata {
        let layoutSource = "Local library channel metadata"
        return AudioSourceMetadata(
            fileName: track.fileName,
            containerName: track.url.pathExtension.trimmedNilIfBlank?.uppercased() ?? "Unknown",
            codecName: "Local file",
            layoutName: track.layoutName,
            channelSummary: track.channelSummary,
            channelCount: track.channelCount,
            sampleRate: track.sampleRate,
            bitDepth: 0,
            duration: track.duration,
            title: track.title?.trimmedNilIfBlank,
            album: track.album?.trimmedNilIfBlank,
            artist: track.artist?.trimmedNilIfBlank,
            formatNote: "Gapless local playback; decoded in bounded chunks.",
            channelLayoutConfidence: AudioSourceMetadata.fallbackLayoutConfidence(for: track.channelCount),
            channelLayoutSourceDescription: layoutSource,
            channelLayoutWarnings: AudioSourceMetadata.fallbackLayoutWarnings(
                channelCount: track.channelCount,
                channelSummary: track.channelSummary,
                sourceDescription: layoutSource
            )
        )
    }

    private func logStreamingLocalPlaybackDecision(
        _ descriptor: AudioAssetDescriptor?,
        request: LocalFileLoadRequest
    ) {
        var fields = descriptor?.logFields ?? []
        fields.append("enabled=\(Self.enableStreamingLocalPlayback)")
        fields.append("initialPrerollFrames=\(StreamingLocalPlaybackPolicy.initialPrerollFrames)")
        fields.append("steadyChunkFrames=\(StreamingLocalPlaybackPolicy.steadyChunkFrames)")
        fields.append("targetBufferAheadSeconds=\(String(format: "%.1f", StreamingLocalPlaybackPolicy.targetBufferAheadSeconds))")
        fields.append("hardPCMByteCap=\(StreamingLocalPlaybackPolicy.hardPCMByteCap)")
        fields.append("reason=\"engine scheduler still consumes prepared full-file buffers\"")

        logLocalTransportTiming(
            request.debugTiming,
            Self.enableStreamingLocalPlayback
                ? "streaming local source skeleton enabled but falling back to full prepare"
                : "streaming local source disabled; using full prepare fallback",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: request.url,
            extra: fields
        )
    }

    private func preparedLocalFile(for request: LocalFileLoadRequest) -> LoadedAudioFile? {
        guard activeLocalFileLoadRequest == nil,
              localFileLoadTask == nil,
              let loaded = localPreparedFileCache.takeValid(for: request.url)
        else { return nil }

        if localFileLoadDebounceTask != nil {
            cancelLocalFileLoadDebounce(reason: "prepared cache hit")
        }
        queuedLocalFileLoadRequest = nil
        readyQueuedLocalFileLoadGeneration = nil
        logLocalTransportTiming(
            request.debugTiming,
            "prepared cache hit",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: request.url
        )
        return loaded
    }

    private func finishPreparedLocalFileLoad(_ loaded: LoadedAudioFile, request: LocalFileLoadRequest) {
        if let validationFailure = localFileLoadValidationFailure(for: request) {
            pendingSessionQueueIndex = nil
            isLocalFileLoading = false
            clearPendingLocalPresentation(generation: request.generation)
            logLocalTransportTiming(
                request.debugTiming,
                "stale prepared cache discarded",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: request.url,
                extra: ["reason=\"\(validationFailure)\""]
            )
            logLocalPlayNowDebug(
                "completed",
                request: request,
                loadStarted: false,
                loadCompleted: false,
                error: validationFailure
            )
            return
        }

        pendingSessionQueueIndex = nil
        isLocalFileLoading = false
        stopLocalFileLoadStatusTask()
        clearPendingLocalPresentation(generation: request.generation)
        logLocalPlayNowDebug(
            "load completed",
            request: request,
            loadStarted: false,
            loadCompleted: true
        )
        finishLoadedFile(
            loaded,
            autoplay: request.autoplay,
            queueCommit: request.queueCommit,
            localPlayNowRequest: request,
            debugTiming: request.debugTiming
        )
    }

    private func startLocalFileLoadStatusTask(for request: LocalFileLoadRequest) {
        localFileLoadStatusTask?.cancel()
        localFileLoadStatusTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.localLoadSubtleStatusNanoseconds)
                guard let self, self.isLocalFileLoadRequestCurrent(request) else { return }
                self.statusMessage = request.kind.subtleStatus(
                    trackTitle: self.requestTrackTitle(request),
                    fileName: request.url.lastPathComponent
                )
                self.logLocalTransportTiming(
                    request.debugTiming,
                    "UI state updated",
                    targetQueueIndex: request.queueCommit?.index,
                    track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                    fileURL: request.url,
                    extra: ["status=\"\(self.statusMessage)\""]
                )

                try await Task.sleep(nanoseconds: Self.localLoadClearStatusNanoseconds - Self.localLoadSubtleStatusNanoseconds)
                guard self.isLocalFileLoadRequestCurrent(request) else { return }
                self.statusMessage = request.kind.clearStatus(
                    trackTitle: self.requestTrackTitle(request),
                    fileName: request.url.lastPathComponent
                )
                self.logLocalTransportTiming(
                    request.debugTiming,
                    "UI state updated",
                    targetQueueIndex: request.queueCommit?.index,
                    track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                    fileURL: request.url,
                    extra: ["status=\"\(self.statusMessage)\""]
                )

                try await Task.sleep(nanoseconds: Self.localLoadStillLoadingNanoseconds - Self.localLoadClearStatusNanoseconds)
                guard self.isLocalFileLoadRequestCurrent(request) else { return }
                self.statusMessage = request.kind.stillLoadingStatus
                self.logLocalTransportTiming(
                    request.debugTiming,
                    "UI state updated",
                    targetQueueIndex: request.queueCommit?.index,
                    track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                    fileURL: request.url,
                    extra: ["status=\"\(self.statusMessage)\""]
                )
            } catch {
                return
            }
        }
    }

    private func stopLocalFileLoadStatusTask() {
        localFileLoadStatusTask?.cancel()
        localFileLoadStatusTask = nil
    }

    private func cancelActiveLocalFileDecode(reason: String, debugTiming: DebugTimingContext? = nil) {
        guard let decodeTask = localFileDecodeTask else { return }

        let request = activeLocalFileLoadRequest
        decodeTask.cancel()
        logLocalTransportTiming(
            debugTiming ?? request?.debugTiming,
            "decode cancel requested",
            targetQueueIndex: request?.queueCommit?.index,
            track: request?.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: request?.url,
            extra: ["reason=\"\(reason)\""]
        )
    }

    private func clearLocalFileDecodeTask(for requestID: UInt64) {
        guard localFileDecodeRequestID == requestID else { return }

        localFileDecodeTask = nil
        localFileDecodeRequestID = nil
    }

    private func isLocalFileLoadRequestCurrent(_ request: LocalFileLoadRequest) -> Bool {
        isCurrentLocalPlaybackGeneration(request.generation) &&
            (activeLocalFileLoadRequest?.generation == request.generation ||
             queuedLocalFileLoadRequest?.generation == request.generation)
    }

    private func localFileLoadValidationFailure(for request: LocalFileLoadRequest) -> String? {
        guard isCurrentLocalPlaybackGeneration(request.generation) else {
            return "generation \(request.generation) invalidated by \(currentLocalFileLoadGeneration)"
        }
        guard sourceMode == .filePlayback else {
            return "source mode changed to \(sourceMode.rawValue)"
        }
        if let queueCommit = request.queueCommit {
            guard sessionQueue.indices.contains(queueCommit.index) else {
                return "target queue index \(queueCommit.index) is no longer valid"
            }
            guard sessionQueue[queueCommit.index].id == queueCommit.trackID else {
                return "target queue index \(queueCommit.index) now points at a different track"
            }
            if let pendingSessionQueueIndex,
               pendingSessionQueueIndex != queueCommit.index {
                return "pending target changed from \(queueCommit.index) to \(pendingSessionQueueIndex)"
            }
        }
        return nil
    }

    private func cancelLocalFileLoadDebounce(reason: String) {
        guard let request = queuedLocalFileLoadRequest ?? activeLocalFileLoadRequest,
              localFileLoadDebounceTask != nil
        else {
            localFileLoadDebounceTask?.cancel()
            localFileLoadDebounceTask = nil
            readyQueuedLocalFileLoadGeneration = nil
            return
        }

        localFileLoadDebounceTask?.cancel()
        localFileLoadDebounceTask = nil
        readyQueuedLocalFileLoadGeneration = nil
        logLocalTransportTiming(
            request.debugTiming,
            "debounce canceled",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: request.url,
            extra: ["reason=\"\(reason)\""]
        )
        logLocalTransportTiming(
            request.debugTiming,
            "generation invalidated",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: request.url,
            extra: ["reason=\"\(reason)\""]
        )
    }

    private func queueLocalFileLoadForStart(_ request: LocalFileLoadRequest) {
        if let activeRequest = activeLocalFileLoadRequest,
           activeRequest.generation != request.generation {
            logLocalTransportTiming(
                activeRequest.debugTiming,
                "generation invalidated",
                targetQueueIndex: activeRequest.queueCommit?.index,
                track: activeRequest.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: activeRequest.url,
                extra: ["reason=\"superseded by local load \(request.generation)\""]
            )
            cancelActiveLocalFileDecode(
                reason: "superseded by local load \(request.generation)",
                debugTiming: activeRequest.debugTiming
            )
        }
        if let queuedRequest = queuedLocalFileLoadRequest,
           queuedRequest.generation != request.generation {
            logLocalTransportTiming(
                queuedRequest.debugTiming,
                "stale completion discarded",
                targetQueueIndex: queuedRequest.queueCommit?.index,
                track: queuedRequest.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: queuedRequest.url,
                extra: ["reason=\"queued load superseded by \(request.generation)\""]
            )
        }

        switch request.startPolicy {
        case .immediate:
            cancelLocalFileLoadDebounce(reason: "immediate local load replacing debounce")
            queuedLocalFileLoadRequest = nil
            readyQueuedLocalFileLoadGeneration = nil
            if activeLocalFileLoadRequest == nil {
                startLocalFileLoad(request)
            } else {
                queuedLocalFileLoadRequest = request
                AppLogger.shared.info(
                    category: "ui",
                    "Queued local load request id=\(request.id) file=\(request.url.lastPathComponent)"
                )
            }
        case .debounced:
            if localFileLoadDebounceTask != nil {
                cancelLocalFileLoadDebounce(reason: "debounce reset")
            }
            queuedLocalFileLoadRequest = request
            readyQueuedLocalFileLoadGeneration = nil
            logLocalTransportTiming(
                request.debugTiming,
                "debounce started",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: request.url,
                extra: ["debounceMs=120"]
            )
            localFileLoadDebounceTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.localTransportDebounceNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                guard self.isCurrentLocalPlaybackGeneration(request.generation),
                      self.queuedLocalFileLoadRequest?.generation == request.generation
                else {
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "stale completion discarded",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url,
                        extra: ["reason=\"debounce fired for stale generation \(request.generation)\""]
                    )
                    return
                }
                self.localFileLoadDebounceTask = nil
                self.readyQueuedLocalFileLoadGeneration = request.generation
                self.logLocalTransportTiming(
                    request.debugTiming,
                    "debounce fired",
                    targetQueueIndex: request.queueCommit?.index,
                    track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                    fileURL: request.url
                )
                guard self.activeLocalFileLoadRequest == nil else { return }
                self.queuedLocalFileLoadRequest = nil
                self.readyQueuedLocalFileLoadGeneration = nil
                self.startLocalFileLoad(request)
            }
        }
    }

    private func managedImportCacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Orbisonic/ManagedImports", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func managedImportCacheKey(originalURL: URL, targetSampleRateHertz: Double) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: originalURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let seed = "\(originalURL.path)|\(size)|\(Int64(mtime.rounded()))|\(Int(targetSampleRateHertz.rounded()))"
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx-%d", hash, Int(targetSampleRateHertz.rounded()))
    }

    // Off-rate production files cannot stream through the fixed-rate Dante
    // session, so prepare (or reuse) a managed session-rate CAF copy and decode
    // that instead. Returns the original URL unchanged when no conversion is
    // needed (renderer not selected, or rates already match within 1 Hz).
    private func resolveManagedSessionRateFile(
        originalURL: URL,
        sourceSampleRate: Double
    ) async throws -> URL {
        guard rendererOutputSelection != .none else { return originalURL }
        let targetHertz = rendererOutputRoute.nominalSampleRate
        guard targetHertz > 0, sourceSampleRate > 0 else { return originalURL }
        guard abs(sourceSampleRate - targetHertz) > 1.0 else { return originalURL }

        let targetRate = try AudioSampleRate(hertz: targetHertz)
        let cacheDir = try managedImportCacheDirectory()
        let key = managedImportCacheKey(originalURL: originalURL, targetSampleRateHertz: targetHertz)
        let managedURL = cacheDir.appendingPathComponent("\(key).caf")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: managedURL.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 {
            return managedURL
        }

        let displayName = originalURL.lastPathComponent
        statusMessage = "Converting \(displayName) to \(formatSampleRate(targetHertz)) for production\u{2026}"

        let sessionFormat = AudioSessionFormat(
            sampleRate: targetRate,
            maxFramesPerBlock: 512,
            dante: DanteOutputFormat(physicalChannelCount: 32, sampleRate: targetRate),
            desktop: DesktopOutputFormat(sampleRate: targetRate)
        )

        // AVFoundation cannot open Matroska containers, so ManagedAssetImporter
        // (which reads via AVAudioFile) fails an off-rate MKV/MKA with
        // kAudioFileUnsupportedFileTypeError. Demux the chosen stream to a
        // temporary CAF first -- the same ffmpeg path used for on-rate Matroska
        // playback -- then resample that CAF to the session rate. The demux runs
        // off the main actor so the ffmpeg subprocess never blocks the UI.
        var importSourceURL = originalURL
        var temporaryDemuxURL: URL?
        if MatroskaFLACSupport.isMatroska(originalURL) {
            let demuxedURL = try await Task.detached(priority: .userInitiated) {
                let streamInfo = try MatroskaAudioProbe().probe(url: originalURL)
                return try MatroskaFLACDemuxer().demuxToCAF(url: originalURL, streamInfo: streamInfo)
            }.value
            importSourceURL = demuxedURL
            temporaryDemuxURL = demuxedURL
        }
        defer {
            if let temporaryDemuxURL {
                try? FileManager.default.removeItem(at: temporaryDemuxURL)
            }
        }

        let originalPath = importSourceURL.path
        let managedPath = managedURL.path
        let importTask = Task.detached(priority: .userInitiated) {
            try ManagedAssetImporter().importAsset(
                originalPath: originalPath,
                managedPath: managedPath,
                managedAssetID: key,
                targetSessionFormat: sessionFormat
            )
        }
        let descriptor = try await importTask.value
        return URL(fileURLWithPath: descriptor.managedPath)
    }

    private func startLocalFileLoad(_ request: LocalFileLoadRequest) {
        guard isCurrentLocalPlaybackGeneration(request.generation) else {
            clearPendingLocalPresentation(generation: request.generation)
            logLocalTransportTiming(
                request.debugTiming,
                "stale completion discarded",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: request.url,
                extra: ["reason=\"start ignored for stale generation \(request.generation)\""]
            )
            return
        }

        activeLocalFileLoadRequest = request
        if readyQueuedLocalFileLoadGeneration == request.generation {
            readyQueuedLocalFileLoadGeneration = nil
        }
        pendingSessionQueueIndex = request.queueCommit?.index
        isLocalFileLoading = true
        activity = PlaybackActivity(phase: .decoding, detail: localLoadActivityName(for: request))
        statusMessage = requestImmediateStatus(request)
        let audioLoader = localAudioLoader
        logLocalTransportTiming(
            request.debugTiming,
            "decode scheduled",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: request.url
        )
        logLocalPlayNowDebug(
            "load started",
            request: request,
            loadStarted: true
        )

        localFileLoadTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                var localDescriptor: AudioAssetDescriptor?
                if let descriptor = self.localAudioDescriptorCache.descriptor(for: request.url) {
                    localDescriptor = descriptor
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "descriptor cache hit before full prepare",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url,
                        extra: descriptor.logFields
                    )
                    self.publishPendingLocalDescriptor(descriptor, for: request)
                } else {
                    do {
                        let descriptorProbeStart = DispatchTime.now().uptimeNanoseconds
                        self.logLocalTransportTiming(
                            request.debugTiming,
                            "descriptor probe started",
                            targetQueueIndex: request.queueCommit?.index,
                            track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                            fileURL: request.url
                        )
                        let descriptor = try await AudioFileProbe().probe(
                            url: request.url,
                            debugTiming: request.debugTiming
                        )
                        localDescriptor = descriptor
                        self.logLocalTransportTiming(
                            request.debugTiming,
                            "descriptor probe finished",
                            targetQueueIndex: request.queueCommit?.index,
                            track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                            fileURL: request.url,
                            extra: descriptor.logFields + [
                                "probeMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - descriptorProbeStart) / 1_000_000.0))"
                            ]
                        )
                        self.publishPendingLocalDescriptor(descriptor, for: request)
                    } catch is CancellationError {
                        self.logLocalTransportTiming(
                            request.debugTiming,
                            "descriptor probe canceled",
                            targetQueueIndex: request.queueCommit?.index,
                            track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                            fileURL: request.url
                        )
                        self.completeLocalFileLoad(request: request, result: .failure(CancellationError()))
                        return
                    } catch {
                        self.logLocalTransportTiming(
                            request.debugTiming,
                            "descriptor probe failed",
                            targetQueueIndex: request.queueCommit?.index,
                            track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                            fileURL: request.url,
                            extra: ["error=\"\(error.localizedDescription)\"", "reason=\"continuing to existing full prepare path\""]
                        )
                    }
                }
                self.logStreamingLocalPlaybackDecision(localDescriptor, request: request)
                if let descriptor = localDescriptor,
                   let gateError = self.blockLocalFileProductionIfNeeded(
                    descriptor.legacyLocalFileSourceDescription,
                    debugTiming: request.debugTiming,
                    fileURL: request.url,
                    isSessionRunning: true
                   ) {
                    self.completeLocalFileLoad(request: request, result: .failure(gateError))
                    return
                }

                guard self.activeLocalFileLoadRequest?.id == request.id,
                      self.isCurrentLocalPlaybackGeneration(request.generation)
                else {
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "stale completion discarded",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url,
                        extra: ["reason=\"descriptor completed for stale local load\""]
                    )
                    self.completeLocalFileLoad(request: request, result: .failure(CancellationError()))
                    return
                }

                var effectiveURL = request.url
                if let descriptor = localDescriptor {
                    do {
                        effectiveURL = try await self.resolveManagedSessionRateFile(
                            originalURL: request.url,
                            sourceSampleRate: descriptor.sourceSampleRate
                        )
                    } catch is CancellationError {
                        self.completeLocalFileLoad(request: request, result: .failure(CancellationError()))
                        return
                    } catch {
                        self.completeLocalFileLoad(request: request, result: .failure(error))
                        return
                    }
                }

                let mustStreamForFullSpatial = StreamingLocalPlaybackPolicy
                    .requiresStreamingForFullSpatialRender(
                        durationFrames: localDescriptor?.durationFrames
                    )
                if Self.enableStreamingLocalPlayback || mustStreamForFullSpatial,
                   request.autoplay,
                   effectiveURL == request.url,
                   self.queuedLocalFileLoadRequest == nil,
                   let descriptor = localDescriptor {
                    do {
                        try await self.finishStreamingLocalFileLoad(
                            descriptor,
                            request: request
                        )
                        return
                    } catch is CancellationError {
                        self.completeLocalFileLoad(request: request, result: .failure(CancellationError()))
                        return
                    } catch {
                        self.logLocalTransportTiming(
                            request.debugTiming,
                            "streaming start failed; falling back to full prepare",
                            targetQueueIndex: request.queueCommit?.index,
                            track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                            fileURL: request.url,
                            extra: ["error=\"\(error.localizedDescription)\""]
                        )
                    }
                }

                let decodeStart = DispatchTime.now().uptimeNanoseconds
                request.debugTiming?.log(
                    "decode started",
                    sourceMode: self.sourceMode,
                    targetQueueIndex: request.queueCommit?.index,
                    trackTitle: request.queueCommit.flatMap { self.queueTrack(for: $0.index)?.displayTitle },
                    fileURL: request.url
                )
                let decodeTask = Task.detached(priority: .utility) {
                    try audioLoader(effectiveURL, request.debugTiming)
                }
                self.localFileDecodeTask = decodeTask
                self.localFileDecodeRequestID = request.id
                let loaded = try await withTaskCancellationHandler {
                    try await decodeTask.value
                } onCancel: {
                    decodeTask.cancel()
                }
                let decodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000.0
                request.debugTiming?.log(
                    "decode finished",
                    sourceMode: self.sourceMode,
                    targetQueueIndex: request.queueCommit?.index,
                    trackTitle: request.queueCommit.flatMap { self.queueTrack(for: $0.index)?.displayTitle },
                    fileURL: request.url,
                    extra: ["decodeMs=\(String(format: "%.1f", decodeMilliseconds))"]
                )
                self.clearLocalFileDecodeTask(for: request.id)
                guard !Task.isCancelled else {
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "decode canceled",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url
                    )
                    return
                }
                guard self.activeLocalFileLoadRequest?.id == request.id else {
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "stale completion discarded",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url
                    )
                    return
                }
                let identityLoaded = effectiveURL == request.url ? loaded : loaded.withURL(request.url)
                self.completeLocalFileLoad(request: request, result: .success(identityLoaded))
            } catch {
                guard let self else { return }
                self.clearLocalFileDecodeTask(for: request.id)
                if error is CancellationError {
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "decode canceled",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url,
                        extra: ["reason=\"cancellation observed by AudioFileLoader\""]
                    )
                    guard self.activeLocalFileLoadRequest?.id == request.id else {
                        self.logLocalTransportTiming(
                            request.debugTiming,
                            "stale completion discarded",
                            targetQueueIndex: request.queueCommit?.index,
                            track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                            fileURL: request.url,
                            extra: ["reason=\"canceled decode no longer active\""]
                        )
                        return
                    }
                    self.completeLocalFileLoad(request: request, result: .failure(error))
                    return
                }
                guard !Task.isCancelled else {
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "decode canceled",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url,
                        extra: ["error=\"\(error.localizedDescription)\""]
                    )
                    return
                }
                guard self.activeLocalFileLoadRequest?.id == request.id else {
                    self.logLocalTransportTiming(
                        request.debugTiming,
                        "stale completion discarded",
                        targetQueueIndex: request.queueCommit?.index,
                        track: request.queueCommit.flatMap { self.queueTrack(for: $0.index) },
                        fileURL: request.url,
                        extra: ["error=\"\(error.localizedDescription)\""]
                    )
                    return
                }
                self.completeLocalFileLoad(request: request, result: .failure(error))
            }
        }
    }

    private func currentLocalSourceDescriptionForGate() -> LegacyLocalFileSourceDescription? {
        guard let currentFileURL, let sourceMetadata else { return nil }
        return sourceMetadata.legacyLocalFileSourceDescription(path: currentFileURL.path)
    }

    @discardableResult
    private func blockLocalFileProductionIfNeeded(
        _ source: LegacyLocalFileSourceDescription,
        debugTiming: DebugTimingContext?,
        fileURL: URL?,
        isSessionRunning: Bool
    ) -> LegacyLocalFileProductionGateError? {
        let admission = LegacyLocalFileProductionGate.admission(
            for: source,
            monitorRoute: monitorOutputRoute,
            systemOutputRoute: systemOutputRoute,
            rendererRoute: rendererOutputRoute,
            rendererOutputSelected: rendererOutputSelection != .none,
            isSessionRunning: isSessionRunning
        )

        switch admission {
        case .allowed(let reason):
            if rendererOutputSelection != .none {
                AppLogger.shared.notice(category: "local-file", reason)
            }
            return nil
        case .blocked(let reason):
            let message = reason
            statusMessage = message
            lastError = message
            AppLogger.shared.error(category: "local-file", message)
            logLocalTransportTiming(
                debugTiming,
                "production gate blocked",
                targetQueueIndex: nil,
                track: nil,
                fileURL: fileURL,
                extra: [
                    "file=\"\(source.displayName)\"",
                    "sampleRate=\"\(source.sampleRateText)\"",
                    "reason=\"\(message)\""
                ]
            )
            return LegacyLocalFileProductionGateError(message: message)
        }
    }

    private func completeLocalFileLoad(request: LocalFileLoadRequest, result: Result<LoadedAudioFile, Error>) {
        localFileLoadTask = nil
        clearLocalFileDecodeTask(for: request.id)
        if activeLocalFileLoadRequest?.generation == request.generation {
            activeLocalFileLoadRequest = nil
        }

        if let queuedRequest = queuedLocalFileLoadRequest {
            guard isCurrentLocalPlaybackGeneration(queuedRequest.generation) else {
                logLocalTransportTiming(
                    queuedRequest.debugTiming,
                    "stale completion discarded",
                    targetQueueIndex: queuedRequest.queueCommit?.index,
                    track: queuedRequest.queueCommit.flatMap { queueTrack(for: $0.index) },
                    fileURL: queuedRequest.url,
                    extra: ["reason=\"queued generation \(queuedRequest.generation) invalidated by \(currentLocalFileLoadGeneration)\""]
                )
                queuedLocalFileLoadRequest = nil
                readyQueuedLocalFileLoadGeneration = nil
                if activeLocalFileLoadRequest == nil {
                    pendingSessionQueueIndex = nil
                    isLocalFileLoading = false
                    stopLocalFileLoadStatusTask()
                    clearPendingLocalPresentation()
                }
                return
            }
            logLocalTransportTiming(
                request.debugTiming,
                "stale completion discarded",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: request.url,
                extra: ["reason=\"superseded by queued local load \(queuedRequest.id)\""]
            )
            if queuedRequest.startPolicy == .debounced,
               readyQueuedLocalFileLoadGeneration != queuedRequest.generation {
                if localFileLoadDebounceTask == nil {
                    queueLocalFileLoadForStart(queuedRequest)
                }
                return
            }
            queuedLocalFileLoadRequest = nil
            readyQueuedLocalFileLoadGeneration = nil
            startLocalFileLoad(queuedRequest)
            return
        }

        if let validationFailure = localFileLoadValidationFailure(for: request) {
            stopLocalFileLoadStatusTask()
            logLocalTransportTiming(
                request.debugTiming,
                "stale completion discarded",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: request.url,
                extra: ["reason=\"\(validationFailure)\""]
            )
            if pendingSessionQueueIndex == request.queueCommit?.index {
                pendingSessionQueueIndex = nil
            }
            if activeLocalFileLoadRequest == nil && queuedLocalFileLoadRequest == nil {
                isLocalFileLoading = false
                clearPendingLocalPresentation(generation: request.generation)
            }
            logLocalPlayNowDebug(
                "completed",
                request: request,
                loadStarted: true,
                loadCompleted: false,
                error: validationFailure
            )
            return
        }

        isLocalFileLoading = false
        pendingSessionQueueIndex = nil
        stopLocalFileLoadStatusTask()

        switch result {
        case .success(let loaded):
            logLocalPlayNowDebug(
                "load completed",
                request: request,
                loadStarted: true,
                loadCompleted: true
            )
            finishLoadedFile(
                loaded,
                autoplay: request.autoplay,
                queueCommit: request.queueCommit,
                localPlayNowRequest: request,
                debugTiming: request.debugTiming
            )
        case .failure(let error) where error is CancellationError:
            clearPendingLocalPresentation(generation: request.generation)
            logLocalPlayNowDebug(
                "completed",
                request: request,
                loadStarted: true,
                loadCompleted: false,
                error: "canceled"
            )
            logLocalTransportTiming(
                request.debugTiming,
                "decode canceled",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: request.url,
                extra: ["reason=\"cancellation completed before UI commit\""]
            )
        case .failure(let error):
            clearPendingLocalPresentation(generation: request.generation)
            logLocalPlayNowDebug(
                "completed",
                request: request,
                loadStarted: true,
                loadCompleted: false,
                error: error.localizedDescription
            )
            handleLocalFileLoadFailure(
                url: request.url,
                error: error,
                queueCommit: request.queueCommit,
                debugTiming: request.debugTiming
            )
        }
    }

    private func finishLoadedFile(
        _ loaded: LoadedAudioFile,
        autoplay: Bool,
        queueCommit: LocalFileQueueCommit?,
        localPlayNowRequest: LocalFileLoadRequest?,
        debugTiming: DebugTimingContext?
    ) {
        if let localPlayNowRequest,
           let validationFailure = localFileLoadValidationFailure(for: localPlayNowRequest) {
            clearPendingLocalPresentation(generation: localPlayNowRequest.generation)
            logLocalTransportTiming(
                debugTiming,
                "stale completion discarded",
                targetQueueIndex: queueCommit?.index,
                track: queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: loaded.url,
                extra: ["reason=\"\(validationFailure)\""]
            )
            return
        }

        if let gateError = blockLocalFileProductionIfNeeded(
            loaded.legacyLocalFileSourceDescription,
            debugTiming: debugTiming,
            fileURL: loaded.url,
            isSessionRunning: autoplay || isPlaying
        ) {
            clearPendingLocalPresentation(generation: localPlayNowRequest?.generation)
            if let localPlayNowRequest {
                logLocalPlayNowDebug(
                    "completed",
                    request: localPlayNowRequest,
                    loadStarted: true,
                    loadCompleted: false,
                    error: gateError.localizedDescription
                )
            }
            return
        }

        cancelDiagnosticsForMusicAction()
        sourceMode = .filePlayback
        defer {
            scheduleAdjacentLocalFilePreloads(reason: "loaded \(loaded.url.lastPathComponent)")
        }

        let commitStart = DispatchTime.now().uptimeNanoseconds
        logLocalTransportTiming(
            debugTiming,
            "engine commit started",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: loaded.url
        )
        _ = engine.loadPreparedFile(
            loaded,
            debugTiming: debugTiming,
            localGaplessQueue: localGaplessQueueSnapshot(for: queueCommit),
            rendererScene: committedRendererScene(for: loaded)
        )
        logLocalTransportTiming(
            debugTiming,
            "engine commit finished",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: loaded.url,
            extra: ["commitMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - commitStart) / 1_000_000.0))"]
        )
        logLocalTransportTiming(
            debugTiming,
            "publish player state start",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: loaded.url
        )
        clearPendingLocalPresentation(generation: localPlayNowRequest?.generation)
        loadedFileName = loaded.url.lastPathComponent
        currentFileURL = loaded.url
        if let queueCommit {
            sessionQueueIndex = queueCommit.index
            if !sessionQueue.indices.contains(queueCommit.index) ||
                sessionQueue[queueCommit.index].id != queueCommit.trackID {
                refreshSessionQueueIndexForCurrentFile()
            }
        }
        sourceMetadata = loaded.metadata
        updatePureSphericalLosslessState(for: loaded.url)
        loadedChannels = loaded.layout.channels
        resetRendererRequestToAutomatic(reason: "new track")
        duration = loaded.duration
        currentTime = 0
        scrubProgress = 0
        meterStore.configure(channels: loaded.layout.channels)
        meterStore.reset()
        monitorMeterStore.reset()
        updateRendererMeters(from: Array(repeating: 0, count: loaded.layout.channelCount))
        isPlaying = false
        lastHeartbeatSecond = -1
        lastLiveMeterLogSecond = -1
        lastLiveBufferLogSecond = -1
        lastLiveSilenceWarningSecond = -1
        lastLiveSignalPresent = nil
        lastLiveSignalDetectedSecond = nil
        liveAudioSignalState = .unknown
        liveAudioSignalSilenceDuration = nil
        liveSignalStatus = "File playback source loaded."
        liveBufferStatus = "No live buffer."
        roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
        roonSignalPath = nil
        logLocalTransportTiming(
            debugTiming,
            "now-playing committed",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: loaded.url
        )
        logLocalTransportTiming(
            debugTiming,
            "publish player state end",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: loaded.url
        )

        if autoplay {
            guard prepareOutputForMusicPlayback() else {
                if let localPlayNowRequest {
                    logLocalPlayNowDebug(
                        "completed",
                        request: localPlayNowRequest,
                        loadStarted: true,
                        loadCompleted: true,
                        playStarted: false,
                        error: "output preparation failed"
                    )
                }
                return
            }
            do {
                try engine.play(debugTiming: debugTiming)
                isPlaying = true
                statusMessage = "Playing \(loaded.metadata.fileName) through \(routeDisplayName) with \(rendererScene.renderMode.displayName)."
                if let localPlayNowRequest {
                    logLocalPlayNowDebug(
                        "completed",
                        request: localPlayNowRequest,
                        loadStarted: true,
                        loadCompleted: true,
                        playStarted: true
                    )
                }
            } catch {
                AppLogger.shared.error(category: "ui", "Playback start failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
                logLocalTransportTiming(
                    debugTiming,
                    "error shown",
                    targetQueueIndex: queueCommit?.index,
                    track: queueCommit.flatMap { queueTrack(for: $0.index) },
                    fileURL: loaded.url,
                    extra: ["error=\"\(error.localizedDescription)\""]
                )
                if let localPlayNowRequest {
                    logLocalPlayNowDebug(
                        "completed",
                        request: localPlayNowRequest,
                        loadStarted: true,
                        loadCompleted: true,
                        playStarted: false,
                        error: error.localizedDescription
                    )
                }
            }
        } else if rendererOutputRoute.isAvailable {
            statusMessage = "Loaded \(loaded.metadata.fileName). Ready to render through \(rendererOutputRoute.deviceName)."
            if let localPlayNowRequest {
                logLocalPlayNowDebug(
                    "completed",
                    request: localPlayNowRequest,
                    loadStarted: true,
                    loadCompleted: true,
                    playStarted: false
                )
            }
        } else {
            statusMessage = "Loaded \(loaded.metadata.fileName). Playback can use Output 1 Monitor or current macOS output."
            if let localPlayNowRequest {
                logLocalPlayNowDebug(
                    "completed",
                    request: localPlayNowRequest,
                    loadStarted: true,
                    loadCompleted: true,
                    playStarted: false
                )
            }
        }
    }

    private func finishStreamingLocalFileLoad(
        _ descriptor: AudioAssetDescriptor,
        request: LocalFileLoadRequest
    ) async throws {
        if let validationFailure = localFileLoadValidationFailure(for: request) {
            clearPendingLocalPresentation(generation: request.generation)
            logLocalTransportTiming(
                request.debugTiming,
                "stale streaming start discarded",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: descriptor.url,
                extra: ["reason=\"\(validationFailure)\""]
            )
            throw CancellationError()
        }

        if let gateError = blockLocalFileProductionIfNeeded(
            descriptor.legacyLocalFileSourceDescription,
            debugTiming: request.debugTiming,
            fileURL: descriptor.url,
            isSessionRunning: true
        ) {
            throw gateError
        }

        cancelDiagnosticsForMusicAction()
        sourceMode = .filePlayback
        guard prepareOutputForMusicPlayback() else {
            throw StreamingAudioFileSourceError.invalidConfiguration("output preparation failed")
        }

        let commitStart = DispatchTime.now().uptimeNanoseconds
        logLocalTransportTiming(
            request.debugTiming,
            "streaming engine commit started",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: descriptor.url,
            extra: descriptor.logFields
        )
        let source = StreamingAudioFileSource(url: descriptor.url, debugTiming: request.debugTiming)
        try await engine.startStreaming(
            source: source,
            descriptor: descriptor,
            rendererScene: committedRendererScene(for: descriptor.channelLayout),
            debugTiming: request.debugTiming
        )

        if let validationFailure = localFileLoadValidationFailure(for: request) {
            engine.stop()
            clearPendingLocalPresentation(generation: request.generation)
            logLocalTransportTiming(
                request.debugTiming,
                "stale streaming start discarded",
                targetQueueIndex: request.queueCommit?.index,
                track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: descriptor.url,
                extra: ["reason=\"\(validationFailure)\""]
            )
            throw CancellationError()
        }

        localFileLoadTask = nil
        clearLocalFileDecodeTask(for: request.id)
        if activeLocalFileLoadRequest?.generation == request.generation {
            activeLocalFileLoadRequest = nil
        }
        isLocalFileLoading = false
        pendingSessionQueueIndex = nil
        stopLocalFileLoadStatusTask()

        logLocalTransportTiming(
            request.debugTiming,
            "streaming engine commit finished",
            targetQueueIndex: request.queueCommit?.index,
            track: request.queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: descriptor.url,
            extra: ["commitMs=\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - commitStart) / 1_000_000.0))"]
        )

        let metadata = streamingMetadata(for: descriptor, request: request)
        clearPendingLocalPresentation(generation: request.generation)
        loadedFileName = descriptor.url.lastPathComponent
        currentFileURL = descriptor.url
        if let queueCommit = request.queueCommit {
            sessionQueueIndex = queueCommit.index
            if !sessionQueue.indices.contains(queueCommit.index) ||
                sessionQueue[queueCommit.index].id != queueCommit.trackID {
                refreshSessionQueueIndexForCurrentFile()
            }
        }
        sourceMetadata = metadata
        updatePureSphericalLosslessState(for: descriptor.url)
        loadedChannels = descriptor.channelLayout.channels
        resetRendererRequestToAutomatic(reason: "new streaming track")
        duration = descriptor.durationSeconds ?? 0
        currentTime = 0
        scrubProgress = 0
        meterStore.configure(channels: descriptor.channelLayout.channels)
        meterStore.reset()
        monitorMeterStore.reset()
        updateRendererMeters(from: Array(repeating: 0, count: descriptor.channelLayout.channelCount))
        isPlaying = true
        lastHeartbeatSecond = -1
        lastLiveMeterLogSecond = -1
        lastLiveBufferLogSecond = -1
        lastLiveSilenceWarningSecond = -1
        lastLiveSignalPresent = nil
        lastLiveSignalDetectedSecond = nil
        liveAudioSignalState = .unknown
        liveAudioSignalSilenceDuration = nil
        liveSignalStatus = "Streaming file playback source loaded."
        liveBufferStatus = "No live buffer."
        roonNowPlayingStatus = "Roon metadata is only shown for live Roon input."
        roonSignalPath = nil
        statusMessage = "Streaming \(metadata.fileName) through \(routeDisplayName) with \(rendererScene.renderMode.displayName)."
        logLocalPlayNowDebug(
            "completed",
            request: request,
            loadStarted: true,
            loadCompleted: true,
            playStarted: true
        )
        scheduleAdjacentLocalFilePreloads(reason: "streaming \(descriptor.url.lastPathComponent)")
    }

    private func streamingMetadata(
        for descriptor: AudioAssetDescriptor,
        request: LocalFileLoadRequest
    ) -> AudioSourceMetadata {
        let track = track(for: request)
        let layoutSource = "Streaming asset descriptor channel layout"
        return AudioSourceMetadata(
            fileName: descriptor.url.lastPathComponent,
            containerName: descriptor.containerDescription ?? descriptor.url.pathExtension.trimmedNilIfBlank?.uppercased() ?? "Unknown",
            codecName: descriptor.codecDescription ?? "Unknown",
            layoutName: descriptor.channelLayout.name,
            channelSummary: descriptor.channelLayout.channelSummary,
            channelCount: descriptor.channelCount,
            sampleRate: descriptor.sourceSampleRate,
            bitDepth: 32,
            duration: descriptor.durationSeconds ?? 0,
            title: track?.title?.trimmedNilIfBlank,
            album: track?.album?.trimmedNilIfBlank,
            artist: track?.artist?.trimmedNilIfBlank,
            formatNote: "Streaming local playback; decoded in bounded chunks.",
            channelLayoutConfidence: AudioSourceMetadata.fallbackLayoutConfidence(for: descriptor.channelCount),
            channelLayoutSourceDescription: layoutSource,
            channelLayoutWarnings: AudioSourceMetadata.fallbackLayoutWarnings(
                channelCount: descriptor.channelCount,
                channelSummary: descriptor.channelLayout.channelSummary,
                sourceDescription: layoutSource
            )
        )
    }

    private func handleLocalFileLoadFailure(
        url: URL,
        error: Error,
        queueCommit: LocalFileQueueCommit?,
        debugTiming: DebugTimingContext?
    ) {
        let message = "Could not load \(url.lastPathComponent): \(error.localizedDescription)"
        AppLogger.shared.error(category: "ui", "Load failed: \(error.localizedDescription)")
        lastError = message
        statusMessage = message
        logLocalTransportTiming(
            debugTiming,
            "error shown",
            targetQueueIndex: queueCommit?.index,
            track: queueCommit.flatMap { queueTrack(for: $0.index) },
            fileURL: url,
            extra: ["error=\"\(error.localizedDescription)\""]
        )
        if queueCommit?.isNaturalAdvance == true {
            isPlaying = false
            meterStore.reset()
            monitorMeterStore.reset()
            rendererMeterStore.reset()
            reevaluateAutomaticRendererMode(reason: "load failed")
        }
    }

    private func cancelPendingLocalFileLoad(debugTiming: DebugTimingContext? = nil) {
        cancelLocalPreparedFilePreload(debugTiming: debugTiming, reason: "pending local load canceled")
        let activeTiming = debugTiming ?? activeLocalFileLoadRequest?.debugTiming ?? queuedLocalFileLoadRequest?.debugTiming
        let canceledRequest = queuedLocalFileLoadRequest ?? activeLocalFileLoadRequest
        if localFileLoadDebounceTask != nil {
            cancelLocalFileLoadDebounce(reason: "local load canceled")
        }
        let invalidatedGeneration = currentLocalFileLoadGeneration
        let newGeneration = nextLocalPlaybackGeneration()
        if localFileLoadTask != nil || activeLocalFileLoadRequest != nil || queuedLocalFileLoadRequest != nil {
            logLocalTransportTiming(
                activeTiming,
                "decode canceled",
                targetQueueIndex: canceledRequest?.queueCommit?.index,
                track: canceledRequest?.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: canceledRequest?.url
            )
            logLocalTransportTiming(
                activeTiming,
                "generation invalidated",
                targetQueueIndex: canceledRequest?.queueCommit?.index,
                track: canceledRequest?.queueCommit.flatMap { queueTrack(for: $0.index) },
                fileURL: canceledRequest?.url,
                extra: [
                    "invalidatedGeneration=\(invalidatedGeneration)",
                    "currentGeneration=\(newGeneration)"
                ]
            )
        }
        cancelActiveLocalFileDecode(reason: "local load canceled", debugTiming: activeTiming)
        queuedLocalFileLoadRequest = nil
        readyQueuedLocalFileLoadGeneration = nil
        pendingSessionQueueIndex = nil
        isLocalFileLoading = false
        stopLocalFileLoadStatusTask()
        clearPendingLocalPresentation()
    }

    private func loadLocalMusicDatabase() {
        let database = localMusicLibrary.load()
        localMusicSettings = Self.normalizedLocalMusicSettings(database.settings)
        localMusicBaseTracks = database.tracks
        localMusicMetadataOverlays = database.metadataOverlays
        if database.metadataScannedTrackIDs.isEmpty, !database.tracks.isEmpty {
            localMusicMetadataScannedTrackIDs = Set(database.tracks.map(\.id))
        } else {
            localMusicMetadataScannedTrackIDs = database.metadataScannedTrackIDs
        }
        refreshEffectiveLocalMusicTracks()
        localMusicPlaylists = database.playlists
        sessionQueue = []
        sessionQueueIndex = nil
        selectedSessionQueueIndex = nil
        pendingSessionQueueIndex = nil
        clearPendingLocalPresentation()
        AppLogger.shared.notice(
            category: "local-music",
            "Loaded local music database tracks=\(localMusicTracks.count) playlists=\(localMusicPlaylists.count) watchFolders=\(localMusicSettings.watchFolderPaths.count)"
        )
        if localMusicSettings != database.settings {
            persistLocalMusicDatabase()
        }
        preloadFirstLocalMusicTrackIfNeeded(reason: "local music database loaded")
        scheduleLocalMusicMetadataEnhancement(reason: "local music database loaded")
        scheduleLocalMusicMatroskaRepair(reason: "local music database loaded")
    }

    private func preloadFirstLocalMusicTrackIfNeeded(reason: String) {
        guard preloadsFirstLocalMusicTrack,
              sourceMode == .filePlayback,
              currentFileURL == nil,
              !isPlaying,
              !isLocalFileLoading,
              let firstTrack = sortedLocalMusicTracks.first
        else { return }

        AppLogger.shared.notice(category: "local-music", "Preloading first library track reason=\(reason) track=\(firstTrack.fileName)")
        startSessionQueue(
            from: sortedLocalMusicTracks,
            startTrackID: firstTrack.id,
            shuffle: false,
            autoplay: false
        )
    }

    private func clearLocalPreparedFilePreloadDecodeTask(for decodeID: UInt64) {
        guard localPreparedFilePreloadDecodeID == decodeID else { return }

        localPreparedFilePreloadDecodeTask = nil
        localPreparedFilePreloadDecodeID = nil
    }

    private func cancelLocalPreparedFilePreload(
        debugTiming: DebugTimingContext? = nil,
        reason: String = "local playback intent"
    ) {
        let hadPreparedPreload = localPreparedFilePreloadTask != nil
        let hadPreparedDecode = localPreparedFilePreloadDecodeTask != nil
        let hadMetadataPreload = localMetadataPreloadTask != nil
        let hadAnyPreload = hadPreparedPreload || hadPreparedDecode || hadMetadataPreload
        if hadAnyPreload {
            logLocalTransportTiming(
                debugTiming,
                "old preload cancellation requested",
                extra: [
                    "reason=\"\(reason)\"",
                    "hadPreparedPreload=\(hadPreparedPreload)",
                    "hadPreparedDecode=\(hadPreparedDecode)",
                    "hadMetadataPreload=\(hadMetadataPreload)"
                ]
            )
        }
        localPreparedFilePreloadDecodeTask?.cancel()
        localPreparedFilePreloadDecodeTask = nil
        localPreparedFilePreloadDecodeID = nil
        localPreparedFilePreloadTask?.cancel()
        localPreparedFilePreloadTask = nil
        localMetadataPreloadTask?.cancel()
        localMetadataPreloadTask = nil
        if hadAnyPreload {
            logLocalTransportTiming(
                debugTiming,
                "old preload cancellation observed",
                extra: [
                    "reason=\"\(reason)\"",
                    "preparedPreloadActive=\(localPreparedFilePreloadTask != nil)",
                    "preparedDecodeActive=\(localPreparedFilePreloadDecodeTask != nil)",
                    "metadataPreloadActive=\(localMetadataPreloadTask != nil)"
                ]
            )
        }
    }

    private func clearLocalPreparedFilePreloads(reason: String) {
        cancelLocalPreparedFilePreload(reason: reason)
        localPreparedFileCache.removeAll()
        localAudioDescriptorCache.removeAll()
        if preloadNextTrackEnabled { nextTrackPreloadStatus = .idle }
        AppLogger.shared.info(category: "local-music", "Cleared local preload caches reason=\(reason)")
    }

    private func scheduleAdjacentLocalFilePreloads(reason: String) {
        cancelLocalPreparedFilePreload(reason: "reschedule adjacent preloads: \(reason)")
        guard sourceMode == .filePlayback else {
            if preloadNextTrackEnabled { nextTrackPreloadStatus = .idle }
            return
        }

        let fullPCMPreloadEnabled = preloadNextTrackEnabled || preloadsAdjacentLocalMusicTracks
        if !fullPCMPreloadEnabled {
            logAdjacentLocalPCMPreloadDisabledIfNeeded(reason: reason)
        }

        let candidates = adjacentLocalFilePreloadCandidates()
        if preloadNextTrackEnabled {
            nextTrackPreloadStatus = candidates.isEmpty ? .noNextTrack : .idle
        }
        guard !candidates.isEmpty else { return }

        let preloadGeneration = currentLocalFileLoadGeneration
        scheduleAdjacentLocalMetadataPreloads(
            candidates: Array(candidates.prefix(Self.maxAdjacentMetadataPreloadCount)),
            reason: reason,
            generation: preloadGeneration
        )
        guard fullPCMPreloadEnabled else { return }

        scheduleAdjacentFullLocalPCMPreloads(
            candidates: Array(candidates.prefix(1)),
            reason: reason,
            generation: preloadGeneration
        )
    }

    private func scheduleAdjacentLocalMetadataPreloads(
        candidates: [(track: LocalMusicTrack, key: PreparedLocalFileKey, estimatedDecodedBytes: Int?)],
        reason: String,
        generation preloadGeneration: UInt64
    ) {
        guard preloadsAdjacentLocalMetadata else { return }

        let metadataCandidates = candidates.filter {
            !localAudioDescriptorCache.containsValid(for: $0.track.url)
        }
        guard !metadataCandidates.isEmpty else { return }

        localMetadataPreloadTask = Task { @MainActor [weak self] in
            defer { self?.localMetadataPreloadTask = nil }
            for candidate in metadataCandidates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.shouldPreloadAdjacentTrack(candidate.track, expectedKey: candidate.key, generation: preloadGeneration),
                      !self.localAudioDescriptorCache.containsValid(for: candidate.track.url)
                else { continue }

                let debugTiming = DebugTimingLog.makeCommand(prefix: "local-metadata-preload", sourceMode: self.sourceMode)
                self.logLocalTransportTiming(
                    debugTiming,
                    "adjacent metadata preload started",
                    track: candidate.track,
                    fileURL: candidate.track.url,
                    extra: [
                        "generation=\(preloadGeneration)",
                        "estimatedDecodedBytes=\(candidate.estimatedDecodedBytes.map(String.init) ?? "unknown")",
                        "reason=\"\(reason)\""
                    ]
                )

                do {
                    let preloadStart = DispatchTime.now().uptimeNanoseconds
                    let descriptor = try await AudioFileProbe().probe(
                        url: candidate.track.url,
                        debugTiming: debugTiming,
                        priority: .background
                    )
                    try Task.checkCancellation()
                    let preloadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - preloadStart) / 1_000_000.0

                    guard self.shouldPreloadAdjacentTrack(candidate.track, expectedKey: candidate.key, generation: preloadGeneration) else {
                        self.logLocalTransportTiming(
                            debugTiming,
                            "adjacent metadata preload discarded",
                            track: candidate.track,
                            fileURL: candidate.track.url,
                            extra: [
                                "generation=\(preloadGeneration)",
                                "currentGeneration=\(self.currentLocalFileLoadGeneration)",
                                "reason=\"queue, file, or playback generation changed\""
                            ]
                        )
                        continue
                    }

                    let storeResult = self.localAudioDescriptorCache.store(
                        descriptor,
                        for: candidate.track.url,
                        expectedKey: candidate.key
                    )
                    var logFields = descriptor.logFields
                    logFields.append(contentsOf: [
                        "generation=\(preloadGeneration)",
                        "metadataPreloadMs=\(String(format: "%.1f", preloadMilliseconds))",
                        "reason=\"\(storeResult.reason)\""
                    ])
                    self.logLocalTransportTiming(
                        debugTiming,
                        storeResult.stored ? "adjacent metadata preload finished" : "adjacent metadata preload discarded",
                        track: candidate.track,
                        fileURL: candidate.track.url,
                        extra: logFields
                    )
                } catch is CancellationError {
                    self.logLocalTransportTiming(
                        debugTiming,
                        "adjacent metadata preload canceled",
                        track: candidate.track,
                        fileURL: candidate.track.url,
                        extra: [
                            "generation=\(preloadGeneration)",
                            "currentGeneration=\(self.currentLocalFileLoadGeneration)"
                        ]
                    )
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.logLocalTransportTiming(
                        debugTiming,
                        "adjacent metadata preload failed",
                        track: candidate.track,
                        fileURL: candidate.track.url,
                        extra: ["error=\"\(error.localizedDescription)\""]
                    )
                }
            }
        }
    }

    private func scheduleAdjacentFullLocalPCMPreloads(
        candidates: [(track: LocalMusicTrack, key: PreparedLocalFileKey, estimatedDecodedBytes: Int?)],
        reason: String,
        generation preloadGeneration: UInt64
    ) {
        let audioLoader = localAudioLoader
        localPreparedFilePreloadTask = Task { @MainActor [weak self] in
            defer { self?.localPreparedFilePreloadTask = nil }
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.shouldPreloadAdjacentTrack(candidate.track, expectedKey: candidate.key, generation: preloadGeneration),
                      !self.localPreparedFileCache.containsValid(for: candidate.track.url)
                else { continue }

                let debugTiming = DebugTimingLog.makeCommand(prefix: "local-preload", sourceMode: self.sourceMode)
                let budgetDecision = self.adjacentPreloadBudgetDecision(estimatedBytes: candidate.estimatedDecodedBytes)
                self.logLocalTransportTiming(
                    debugTiming,
                    budgetDecision.allowed ? "adjacent full PCM preload budget allowed" : "adjacent full PCM preload skipped",
                    track: candidate.track,
                    fileURL: candidate.track.url,
                    extra: [
                        "estimatedDecodedBytes=\(candidate.estimatedDecodedBytes.map(String.init) ?? "unknown")",
                        "maxAdjacentFullPreloadPCMBytes=\(self.adjacentFullPreloadPCMByteLimit)",
                        "allowed=\(budgetDecision.allowed)",
                        "reason=\"\(budgetDecision.reason)\""
                    ]
                )
                guard budgetDecision.allowed else { continue }
                if self.preloadNextTrackEnabled { self.nextTrackPreloadStatus = .preparing }

                self.logLocalTransportTiming(
                    debugTiming,
                    "adjacent full PCM preload started",
                    track: candidate.track,
                    fileURL: candidate.track.url,
                    extra: [
                        "generation=\(preloadGeneration)",
                        "estimatedDecodedBytes=\(candidate.estimatedDecodedBytes.map(String.init) ?? "unknown")",
                        "reason=\"\(reason)\""
                    ]
                )

                var preloadDecodeID: UInt64?
                do {
                    let preloadStart = DispatchTime.now().uptimeNanoseconds
                    self.localPreparedFilePreloadDecodeSequence &+= 1
                    preloadDecodeID = self.localPreparedFilePreloadDecodeSequence
                    let decodeTask = Task.detached(priority: .utility) {
                        try audioLoader(candidate.track.url, debugTiming)
                    }
                    self.localPreparedFilePreloadDecodeTask = decodeTask
                    self.localPreparedFilePreloadDecodeID = preloadDecodeID
                    let loaded = try await withTaskCancellationHandler {
                        try await decodeTask.value
                    } onCancel: {
                        decodeTask.cancel()
                    }
                    if let preloadDecodeID {
                        self.clearLocalPreparedFilePreloadDecodeTask(for: preloadDecodeID)
                    }
                    let preloadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - preloadStart) / 1_000_000.0

                    guard !Task.isCancelled else {
                        self.logLocalTransportTiming(
                            debugTiming,
                            "adjacent full PCM preload discarded",
                            track: candidate.track,
                            fileURL: candidate.track.url,
                            extra: [
                                "generation=\(preloadGeneration)",
                                "currentGeneration=\(self.currentLocalFileLoadGeneration)",
                                "reason=\"preload task canceled before cache store\""
                            ]
                        )
                        return
                    }
                    guard self.shouldPreloadAdjacentTrack(candidate.track, expectedKey: candidate.key, generation: preloadGeneration) else {
                        self.logLocalTransportTiming(
                            debugTiming,
                            "adjacent full PCM preload discarded",
                            track: candidate.track,
                            fileURL: candidate.track.url,
                            extra: [
                                "generation=\(preloadGeneration)",
                                "currentGeneration=\(self.currentLocalFileLoadGeneration)",
                                "reason=\"queue, file, or playback generation changed\""
                            ]
                        )
                        continue
                    }

                    try Task.checkCancellation()
                    let storeResult = self.localPreparedFileCache.store(
                        loaded,
                        for: candidate.track.url,
                        expectedKey: candidate.key
                    )
                    if self.preloadNextTrackEnabled {
                        self.nextTrackPreloadStatus = storeResult.stored ? .ready : .skippedLowMemory
                    }
                    self.logLocalTransportTiming(
                        debugTiming,
                        storeResult.stored ? "adjacent full PCM preload finished" : "adjacent full PCM preload discarded",
                        track: candidate.track,
                        fileURL: candidate.track.url,
                        extra: [
                            "generation=\(preloadGeneration)",
                            "estimatedDecodedBytes=\(loaded.preparedPCMByteCount)",
                            "maxPreparedCacheBytes=\(Self.maxPreparedCacheBytes)",
                            "preloadMs=\(String(format: "%.1f", preloadMilliseconds))",
                            "reason=\"\(storeResult.reason)\""
                        ]
                    )
                } catch {
                    if let preloadDecodeID {
                        self.clearLocalPreparedFilePreloadDecodeTask(for: preloadDecodeID)
                    }
                    if error is CancellationError {
                        self.logLocalTransportTiming(
                            debugTiming,
                            "adjacent full PCM preload canceled",
                            track: candidate.track,
                            fileURL: candidate.track.url,
                            extra: [
                                "generation=\(preloadGeneration)",
                                "currentGeneration=\(self.currentLocalFileLoadGeneration)",
                                "reason=\"cancellation observed by AudioFileLoader\""
                            ]
                        )
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self.logLocalTransportTiming(
                        debugTiming,
                        "adjacent full PCM preload failed",
                        track: candidate.track,
                        fileURL: candidate.track.url,
                        extra: ["error=\"\(error.localizedDescription)\""]
                    )
                }
            }
        }
    }

    private func adjacentPreloadBudgetDecision(estimatedBytes: Int?) -> (allowed: Bool, reason: String) {
        if preloadNextTrackEnabled {
            let memory = systemMemoryProvider.snapshot()
            let decision = planNextTrackPreload(
                estimatedBytes: estimatedBytes,
                availableBytes: memory.availableBytes,
                fraction: Self.nextTrackPreloadAvailableRAMFraction
            )
            switch decision {
            case .allow:
                return (true, "within adaptive RAM budget")
            case .skipLowMemory:
                nextTrackPreloadStatus = .skippedLowMemory
                return (false, "estimated decoded PCM exceeds adaptive RAM budget")
            case .skipUnknownSize:
                nextTrackPreloadStatus = .skippedUnknownSize
                return (false, "missing decoded PCM estimate")
            }
        }

        guard adjacentFullPreloadPCMByteLimit > 0 else {
            return (false, "adjacent full PCM preload cap is zero")
        }
        guard let estimatedBytes, estimatedBytes > 0 else {
            return (false, "missing decoded PCM estimate")
        }
        guard estimatedBytes <= adjacentFullPreloadPCMByteLimit else {
            return (false, "estimated decoded PCM exceeds adjacent preload cap")
        }
        return (true, "within adjacent preload cap")
    }

    private func logAdjacentLocalPCMPreloadDisabledIfNeeded(reason: String) {
        guard !didLogAdjacentLocalPCMPreloadDisabled else { return }

        didLogAdjacentLocalPCMPreloadDisabled = true
        AppLogger.shared.info(
            category: "local-music",
            "Skipped adjacent local full PCM preload because enableAdjacentLocalPCMPreload=false reason=\(reason)"
        )
    }

    private func adjacentLocalFilePreloadCandidates() -> [(track: LocalMusicTrack, key: PreparedLocalFileKey, estimatedDecodedBytes: Int?)] {
        guard let currentIndex = sessionQueueIndex,
              sessionQueue.indices.contains(currentIndex),
              sessionQueue.count > 1
        else { return [] }

        let nextIndex = (currentIndex + 1) % sessionQueue.count
        let previousIndex = (currentIndex - 1 + sessionQueue.count) % sessionQueue.count
        var seenTrackIDs = Set<String>()
        var candidates: [(track: LocalMusicTrack, key: PreparedLocalFileKey, estimatedDecodedBytes: Int?)] = []

        for index in [nextIndex, previousIndex] {
            let track = sessionQueue[index]
            guard track.id != currentFileURL?.path,
                  seenTrackIDs.insert(track.id).inserted,
                  !localPreparedFileCache.containsValid(for: track.url),
                  let key = PreparedLocalFileKey.make(for: track.url)
            else { continue }

            candidates.append((
                track: track,
                key: key,
                estimatedDecodedBytes: estimatedPreparedPCMBytes(for: track)
            ))
        }

        return candidates
    }

    var nextTrackPreloadCaptionText: String {
        let summary = nextTrackPreloadWebSummary()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        var parts: [String] = ["Free memory: \(formatter.string(fromByteCount: Int64(summary.freeBytes)))"]
        if let bytes = summary.nextEstimateBytes, bytes > 0 {
            parts.append("Next \u{2248} \(formatter.string(fromByteCount: Int64(bytes)))")
        }
        if preloadNextTrackEnabled {
            parts.append(nextTrackPreloadStatus.displayLabel)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The next track in the queue, independent of cache state, for display
    /// purposes. Unlike the preload candidates, this still resolves once the
    /// track is prepared so chips keep showing the name in the `.ready` state.
    private func nextQueueTrackForDisplay() -> LocalMusicTrack? {
        guard let currentIndex = sessionQueueIndex,
              sessionQueue.indices.contains(currentIndex),
              sessionQueue.count > 1
        else { return nil }
        let nextIndex = (currentIndex + 1) % sessionQueue.count
        let track = sessionQueue[nextIndex]
        guard track.id != currentFileURL?.path else { return nil }
        return track
    }

    /// Cheap next-track label for view bodies: no memory snapshot syscall.
    var nextTrackPreloadDisplayLabel: String? {
        nextQueueTrackForDisplay()?.displayTitle
    }

    func nextTrackPreloadWebSummary() -> (nextLabel: String?, nextEstimateBytes: Int?, freeBytes: Int, totalBytes: Int) {
        let memory = systemMemoryProvider.snapshot()
        let next = nextQueueTrackForDisplay()
        return (
            nextLabel: next?.displayTitle,
            nextEstimateBytes: next.flatMap { estimatedPreparedPCMBytes(for: $0) },
            freeBytes: memory.availableBytes,
            totalBytes: memory.totalBytes
        )
    }

    private func estimatedPreparedPCMBytes(for track: LocalMusicTrack) -> Int? {
        PreparedPCMPolicy.estimatedDecodedPCMBytes(
            durationSeconds: track.duration,
            sampleRate: track.sampleRate,
            channelCount: track.channelCount
        )
    }

    private func shouldPreloadAdjacentTrack(_ track: LocalMusicTrack, expectedKey: PreparedLocalFileKey, generation: UInt64) -> Bool {
        guard isCurrentLocalPlaybackGeneration(generation),
              sourceMode == .filePlayback,
              PreparedLocalFileKey.make(for: track.url) == expectedKey,
              let currentIndex = sessionQueueIndex,
              sessionQueue.indices.contains(currentIndex),
              sessionQueue.count > 1,
              sessionQueue.contains(where: { $0.id == track.id })
        else { return false }

        let nextIndex = (currentIndex + 1) % sessionQueue.count
        let previousIndex = (currentIndex - 1 + sessionQueue.count) % sessionQueue.count
        return sessionQueue[nextIndex].id == track.id || sessionQueue[previousIndex].id == track.id
    }

    private func persistLocalMusicDatabase() {
        localMusicLibrary.save(LocalMusicDatabase(
            settings: localMusicSettings,
            tracks: localMusicBaseTracks,
            playlists: localMusicPlaylists,
            metadataOverlays: localMusicMetadataOverlays,
            metadataScannedTrackIDs: localMusicMetadataScannedTrackIDs
        ))
    }

    private func updateLocalMusicSettings(_ settings: LocalMusicSettings, rescan: Bool) {
        localMusicSettings = Self.normalizedLocalMusicSettings(settings)
        refreshEffectiveLocalMusicTracks()
        persistLocalMusicDatabase()
        if rescan {
            rescanLocalMusicLibrary()
        }
    }

    private static func normalizedLocalMusicSettings(_ settings: LocalMusicSettings) -> LocalMusicSettings {
        var normalized = settings
        normalized.extractsAlbumArt = true
        normalized.importsM3UPlaylists = true
        return normalized
    }

    private func refreshEffectiveLocalMusicTracks() {
        guard localMusicSettings.enhancesMetadata else {
            localMusicTracks = localMusicBaseTracks
            refreshSessionQueueMetadata()
            return
        }

        localMusicTracks = Self.applyMetadataOverlays(
            localMusicMetadataOverlays,
            to: localMusicBaseTracks
        )
        refreshSessionQueueMetadata()
    }

    private static func applyMetadataOverlays(
        _ overlays: [String: LocalMusicMetadataOverlay],
        to tracks: [LocalMusicTrack]
    ) -> [LocalMusicTrack] {
        tracks.map { track in
            track.applyingMetadataOverlay(overlays[track.id])
        }
    }

    private func refreshSessionQueueMetadata() {
        guard !sessionQueue.isEmpty else { return }

        let effectiveTracksByID = Dictionary(uniqueKeysWithValues: localMusicTracks.map { ($0.id, $0) })
        sessionQueue = sessionQueue.map { track in
            effectiveTracksByID[track.id] ?? track.applyingMetadataOverlay(
                localMusicSettings.enhancesMetadata ? localMusicMetadataOverlays[track.id] : nil
            )
        }
    }

    // Runs the Matroska channel/artwork repair off the synchronous load path.
    // It launches ffprobe subprocesses (Process.waitUntilExit pumps a runloop),
    // which must never happen on the main thread during the SwiftUI StateObject
    // init or a screen-parameters notification can reenter the graph and abort.
    private func scheduleLocalMusicMatroskaRepair(reason: String) {
        localMusicMatroskaRepairTask?.cancel()
        guard !Self.isRunningUnitTests, !localMusicBaseTracks.isEmpty else { return }
        let tracks = localMusicBaseTracks
        let extractsAlbumArt = localMusicSettings.extractsAlbumArt
        let library = localMusicLibrary
        localMusicMatroskaRepairTask = Task(priority: .background) { @MainActor [weak self] in
            let repaired = await library.repairingStaleMatroskaTracks(in: tracks, extractsAlbumArt: extractsAlbumArt)
            guard let self, !Task.isCancelled else { return }
            self.localMusicMatroskaRepairTask = nil
            guard repaired != self.localMusicBaseTracks else { return }
            self.localMusicBaseTracks = repaired
            self.refreshEffectiveLocalMusicTracks()
            self.persistLocalMusicDatabase()
            AppLogger.shared.notice(
                category: "local-music",
                "Repaired stale Matroska metadata reason=\(reason) tracks=\(repaired.count)"
            )
        }
    }

    private func scheduleLocalMusicMetadataEnhancement(reason: String, force: Bool = false) {
        localMusicMetadataEnrichmentTask?.cancel()
        guard localMusicSettings.enhancesMetadata,
              let localMusicMetadataEnricher,
              !localMusicBaseTracks.isEmpty
        else { return }

        let tracks = localMusicBaseTracks
        let existingOverlays = localMusicMetadataOverlays
        let alreadyScanned = localMusicMetadataScannedTrackIDs
        localMusicMetadataEnrichmentTask = Task(priority: .background) { @MainActor [weak self] in
            let result = await localMusicMetadataEnricher.enrich(
                tracks: tracks,
                existingOverlays: existingOverlays,
                alreadyScannedTrackIDs: alreadyScanned,
                forceRescan: force
            )
            guard let self, !Task.isCancelled else { return }
            self.localMusicMetadataEnrichmentTask = nil
            guard self.localMusicSettings.enhancesMetadata else { return }

            let overlaysChanged = result.overlays != self.localMusicMetadataOverlays
            let scannedChanged = result.scannedTrackIDs != self.localMusicMetadataScannedTrackIDs
            guard overlaysChanged || scannedChanged else { return }

            let previousDisplayTracks = self.localMusicTracks
            self.localMusicMetadataOverlays = result.overlays
            self.localMusicMetadataScannedTrackIDs = result.scannedTrackIDs
            self.refreshEffectiveLocalMusicTracks()
            self.persistLocalMusicDatabase()
            let changedCount = zip(previousDisplayTracks, self.localMusicTracks).filter { $0 != $1 }.count
            AppLogger.shared.notice(
                category: "local-music",
                "Applied metadata enhancement reason=\(reason) force=\(force) changedTracks=\(changedCount) scanned=\(result.scannedTrackIDs.count)"
            )
        }
    }

    private func startSessionQueue(
        from tracks: [LocalMusicTrack],
        startTrackID: String?,
        shuffle: Bool,
        autoplay: Bool,
        isNaturalAdvance: Bool = false,
        debugTiming: DebugTimingContext? = nil
    ) {
        guard !tracks.isEmpty else {
            statusMessage = "No local music matches the current view."
            logLocalTransportTiming(debugTiming, "error shown", extra: ["error=\"No local music matches the current view.\""])
            return
        }

        isShuffleEnabled = shuffle

        let startTrack = startTrackID.flatMap { id in tracks.first { $0.id == id } } ?? tracks[0]
        let queue: [LocalMusicTrack]
        if shuffle {
            let rest = tracks.filter { $0.id != startTrack.id }.shuffled()
            queue = [startTrack] + rest
        } else {
            queue = tracks
        }

        clearLocalPreparedFilePreloads(reason: "session queue replaced")
        sessionQueue = queue
        let startIndex = queue.firstIndex { $0.id == startTrack.id } ?? 0
        logLocalTransportTiming(
            debugTiming,
            "UI state updated",
            targetQueueIndex: startIndex,
            track: startTrack,
            extra: ["sessionQueueCount=\(queue.count)", "shuffle=\(shuffle)"]
        )
        _ = loadFile(
            url: startTrack.url,
            autoplay: autoplay,
            queueCommit: LocalFileQueueCommit(index: startIndex, trackID: startTrack.id, isNaturalAdvance: isNaturalAdvance),
            kind: isNaturalAdvance ? .naturalAdvance : (autoplay ? .startingPlayback : .selectedTrack),
            debugTiming: debugTiming
        )
    }

    func skipLocalTransport(offset: Int) {
        let stateBefore = debugPlaybackStateSnapshot()
        defer {
            logTransportDebug(
                command: offset < 0 ? "back" : "forward",
                allowed: !sessionQueue.isEmpty || !localMusicTracks.isEmpty,
                handler: "skipLocalTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot()
            )
        }
        let prefix = offset < 0 ? "local-back" : "local-forward"
        let debugTiming = DebugTimingLog.makeCommand(prefix: prefix, sourceMode: sourceMode)
        logLocalTransportTiming(
            debugTiming,
            "command received",
            extra: ["command=\"\(offset < 0 ? "back" : "forward")\"", "offset=\(offset)"]
        )
        playQueueOffset(offset, wrap: true, debugTiming: debugTiming)
    }

    func skipAtmosDRPTransport(offset: Int) {
        let stateBefore = debugPlaybackStateSnapshot()
        defer {
            logTransportDebug(
                command: offset < 0 ? "back" : "forward",
                allowed: !sessionQueue.isEmpty || !localMusicTracks.isEmpty,
                handler: "skipAtmosDRPTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot()
            )
        }

        let tracks = sessionQueue.isEmpty ? visibleLocalMusicTracks : sessionQueue
        guard !tracks.isEmpty else {
            statusMessage = "Add a watch folder in Settings, then scan local music."
            return
        }

        let currentID = currentAtmosDRPTrack?.id ?? currentFileURL?.path
        let currentIndex = currentID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? (offset < 0 ? 0 : -1)
        let nextIndex = (currentIndex + offset + tracks.count) % tracks.count
        let nextTrack = tracks[nextIndex]
        guard DolbyReferencePlayerController.supportsFile(nextTrack.url) else {
            statusMessage = "\(nextTrack.fileName) is not a Dolby Reference Player target."
            return
        }

        if !sessionQueue.isEmpty {
            sessionQueueIndex = nextIndex
            selectedSessionQueueIndex = nextIndex
        }
        startAtmosDRPPipe(track: nextTrack)
    }

    private func playQueueOffset(_ offset: Int, wrap: Bool, debugTiming: DebugTimingContext? = nil) {
        if sessionQueue.isEmpty {
            let tracks = visibleLocalMusicTracks
            guard !tracks.isEmpty else {
                statusMessage = "Add a watch folder in Settings, then scan local music."
                logLocalTransportTiming(debugTiming, "error shown", extra: ["error=\"Add a watch folder in Settings, then scan local music.\""])
                return
            }
            startSessionQueue(
                from: tracks,
                startTrackID: tracks.first?.id,
                shuffle: isShuffleEnabled,
                autoplay: true,
                debugTiming: debugTiming
            )
            return
        }

        let currentIndex: Int
        if let pendingSessionQueueIndex, sessionQueue.indices.contains(pendingSessionQueueIndex) {
            currentIndex = pendingSessionQueueIndex
        } else if let sessionQueueIndex, sessionQueue.indices.contains(sessionQueueIndex) {
            currentIndex = sessionQueueIndex
        } else if let currentFileURL,
                  let loadedIndex = sessionQueue.firstIndex(where: { $0.id == currentFileURL.path }) {
            currentIndex = loadedIndex
        } else {
            currentIndex = offset < 0 ? 0 : -1
        }

        var nextIndex = currentIndex + offset
        if wrap {
            nextIndex = (nextIndex + sessionQueue.count) % sessionQueue.count
        }

        guard sessionQueue.indices.contains(nextIndex) else {
            statusMessage = "End of session queue."
            logLocalTransportTiming(debugTiming, "error shown", targetQueueIndex: nextIndex, extra: ["error=\"End of session queue.\""])
            return
        }

        logLocalTransportTiming(
            debugTiming,
            "target queue index resolved",
            targetQueueIndex: nextIndex,
            track: queueTrack(for: nextIndex)
        )
        playQueueIndex(
            nextIndex,
            kind: offset < 0 ? .previousTrack : .nextTrack,
            startPolicy: .debounced,
            debugTiming: debugTiming
        )
    }

    @discardableResult
    private func playQueueIndex(
        _ index: Int,
        isNaturalAdvance: Bool = false,
        kind: LocalFileLoadKind? = nil,
        startPolicy: LocalFileLoadStartPolicy = .immediate,
        debugTiming: DebugTimingContext? = nil
    ) -> Bool {
        guard sessionQueue.indices.contains(index) else { return false }
        let track = sessionQueue[index]
        let loadKind = kind ?? (isNaturalAdvance ? .naturalAdvance : .selectedTrack)
        logLocalTransportTiming(
            debugTiming,
            "target queue index resolved",
            targetQueueIndex: index,
            track: track,
            extra: ["naturalAdvance=\(isNaturalAdvance)"]
        )
        return loadFile(
            url: track.url,
            autoplay: true,
            queueCommit: LocalFileQueueCommit(index: index, trackID: track.id, isNaturalAdvance: isNaturalAdvance),
            kind: loadKind,
            startPolicy: startPolicy,
            debugTiming: debugTiming
        )
    }

    private func moveSessionQueueItem(from sourceIndex: Int, to destinationIndex: Int) {
        guard sessionQueue.indices.contains(sourceIndex),
              sessionQueue.indices.contains(destinationIndex),
              sourceIndex != destinationIndex
        else { return }

        clearLocalPreparedFilePreloads(reason: "session queue reordered")
        sessionQueue.swapAt(sourceIndex, destinationIndex)

        if let currentIndex = sessionQueueIndex {
            if currentIndex == sourceIndex {
                sessionQueueIndex = destinationIndex
            } else if currentIndex == destinationIndex {
                sessionQueueIndex = sourceIndex
            }
        }

        if let selectedIndex = selectedSessionQueueIndex {
            if selectedIndex == sourceIndex {
                selectedSessionQueueIndex = destinationIndex
            } else if selectedIndex == destinationIndex {
                selectedSessionQueueIndex = sourceIndex
            }
        }

        if let pendingIndex = pendingSessionQueueIndex {
            if pendingIndex == sourceIndex {
                pendingSessionQueueIndex = destinationIndex
            } else if pendingIndex == destinationIndex {
                pendingSessionQueueIndex = sourceIndex
            }
        }

        rebuildLocalGaplessQueueAfterSessionMutation(reason: "session queue reordered")
    }

    private func refreshSessionQueueIndexForCurrentFile() {
        guard let currentPath = currentFileURL?.path,
              let index = sessionQueue.firstIndex(where: { $0.id == currentPath })
        else {
            sessionQueueIndex = nil
            return
        }

        sessionQueueIndex = index
    }

    func startRoonPipe() {
        cancelDiagnosticsForMusicAction()
        clearLocalPreparedFilePreloads(reason: "manual Roon input started")
        sourceMode = .roon
        currentFileURL = nil
        refreshRoutesIfNeeded(force: true)
        refreshRoonNowPlayingIfNeeded(force: true)
        refreshRoonBridgeIfNeeded(force: true)
        selectExpectedLoopbackInputIfAvailable(for: .roon)

        guard inputRoute.isRoonLoopback else {
            let message = missingLoopbackMessage(for: .roon)
            AppLogger.shared.error(category: "ui", message)
            statusMessage = message
            lastError = message
            liveMonitorState = .unavailable(message)
            logInputSourceStatusIfNeeded(reason: "manual Roon input unavailable", force: true)
            return
        }

        guard prepareOutputForMusicPlayback() else { return }

        repairBlackHoleSampleRateIfNeeded(force: true)
        BlackHoleRouteRepair.prepareInputDeviceForCapture(inputRoute, preferredSampleRate: roonNowPlaying?.outputSampleRate)
        refreshRoutesIfNeeded(force: true)
        startLiveInputForCurrentRoute(reason: "manual")
        refreshRoonNowPlayingIfNeeded(force: true)
    }

    func startSpotifyPipe() {
        cancelDiagnosticsForMusicAction()
        clearLocalPreparedFilePreloads(reason: "manual Spotify input started")
        sourceMode = .spotify
        currentFileURL = nil
        roonNowPlaying = nil
        roonSignalPath = nil
        activeLiveChannelCount = SourceMode.spotify.fixedLiveChannelCount ?? 2
        refreshRoutesIfNeeded(force: true)
        selectExpectedLoopbackInputIfAvailable(for: .spotify)

        guard inputRoute.isSpotifyLoopback else {
            let message = missingLoopbackMessage(for: .spotify)
            AppLogger.shared.error(category: "ui", message)
            statusMessage = message
            lastError = message
            liveMonitorState = .unavailable(message)
            logInputSourceStatusIfNeeded(reason: "manual Spotify input unavailable", force: true)
            return
        }

        guard prepareOutputForMusicPlayback() else { return }

        refreshSpotifyConnectServerIfNeeded(reason: "manual spotify input", force: true)
        refreshSpotifyNowPlayingIfNeeded(force: true, reason: "manual spotify input")
        startLiveInputForCurrentRoute(reason: "manual spotify input")
    }

    func startOtherInputPipe() {
        cancelDiagnosticsForMusicAction()
        sourceMode = .aux
        currentFileURL = nil
        roonNowPlaying = nil
        roonSignalPath = nil
        refreshRoutesIfNeeded(force: true)
        selectExpectedLoopbackInputIfAvailable(for: .aux)

        guard inputRoute.isAuxLoopback else {
            let message = missingLoopbackMessage(for: .aux)
            AppLogger.shared.error(category: "ui", message)
            statusMessage = message
            lastError = message
            liveMonitorState = .unavailable(message)
            logInputSourceStatusIfNeeded(reason: "manual Aux Cable input unavailable", force: true)
            return
        }

        guard prepareOutputForMusicPlayback() else { return }

        startLiveInputForCurrentRoute(reason: "manual other input")
    }

    func startAtmosDRPPipe(track: LocalMusicTrack) {
        cancelDiagnosticsForMusicAction()
        clearLocalPreparedFilePreloads(reason: "Atmos DRP playback started")
        sourceMode = .atmosDRP
        currentAtmosDRPTrack = track
        currentFileURL = track.url
        roonNowPlaying = nil
        roonSignalPath = nil
        updateSpotifyNowPlaying(nil, reason: "Atmos DRP playback started", forceVisible: true)
        refreshRoutesIfNeeded(force: true)
        selectExpectedLoopbackInputIfAvailable(for: .atmosDRP)

        guard inputRoute.uid == AtmosDRPRoutingPolicy.captureLoopback.deviceUID else {
            let message = missingLoopbackMessage(for: .atmosDRP)
            AppLogger.shared.error(category: "atmos-drp", message)
            statusMessage = message
            lastError = message
            liveMonitorState = .unavailable(message)
            logInputSourceStatusIfNeeded(reason: "Atmos DRP input unavailable", force: true)
            return
        }

        guard prepareOutputForMusicPlayback() else { return }

        startLiveInputForCurrentRoute(reason: "Atmos DRP")
        duration = track.duration
        currentTime = 0
        scrubProgress = 0

        do {
            try dolbyReferencePlayerController.play(
                fileURL: track.url,
                volume: AtmosDRPRoutingPolicy.drpOutputVolume,
                outputLayout: atmosDRPOutputLayout
            )
            statusMessage = "Atmos DRP playing through \(AtmosDRPRoutingPolicy.drpOutputDeviceName)."
            AppLogger.shared.notice(
                category: "atmos-drp",
                "Started Atmos DRP file=\(redactedPath(track.path)) layout=\(atmosDRPOutputLayout.rawValue) output=\(AtmosDRPRoutingPolicy.drpOutputDeviceName)"
            )
        } catch {
            liveMonitorState = .error(error.localizedDescription)
            statusMessage = error.localizedDescription
            lastError = error.localizedDescription
            AppLogger.shared.error(category: "atmos-drp", "Atmos DRP launch failed: \(error.localizedDescription)")
        }
    }

    private func startLiveInputForCurrentRoute(reason: String, resetRendererMode: Bool = true) {
        guard recoverRoonMonoRouteIfNeeded(reason: reason) else { return }

        let requestedChannelCount = preferredLiveChannelCount()
        if resetRendererMode {
            resetRendererRequestToAutomatic(reason: "\(sourceMode.rawValue) input changed")
        } else {
            refreshRendererScene()
        }
        let liveLayout = SurroundLayoutDetector.fallbackLayout(for: requestedChannelCount)
        let liveRendererMode = RendererModePolicy.effectiveRequestedMode(
            requestedMode: rendererRenderMode,
            inputChannelCount: requestedChannelCount,
            alwaysMono: rendererAlwaysMono,
            twoChannelPreference: rendererTwoChannelPreference
        )
        rendererScene = RendererMatrixBuilder.sceneModel(
            for: liveLayout,
            preset: rendererPreset,
            renderMode: liveRendererMode
        )
        syncRendererAudioRouting()

        do {
            let liveSource = try engine.startLiveInput(
                activeChannelCount: requestedChannelCount,
                inputRoute: inputRoute,
                sourceName: liveInputSourceName,
                rendererMode: liveRendererMode,
                rendererPreset: rendererPreset
            )
            loadedFileName = liveSource.metadata.fileName
            sourceMetadata = liveSource.metadata
            pureSphericalLosslessState = .none
            loadedChannels = liveSource.layout.channels
            refreshRendererScene()
            duration = 0
            currentTime = 0
            scrubProgress = 0
            activeLiveChannelCount = requestedChannelCount
            meterStore.configure(channels: liveSource.layout.channels)
            meterStore.reset()
            monitorMeterStore.reset()
            updateRendererMeters(from: Array(repeating: 0, count: liveSource.layout.channelCount))
            isPlaying = true
            liveMonitorState = .silent
            lastHeartbeatSecond = -1
            lastLiveMeterLogSecond = -1
            lastLiveBufferLogSecond = -1
            lastLiveUnderflowCount = 0
            lastLiveUnderflowAt = nil
            lastLiveSilenceWarningSecond = -1
            lastLiveSignalPresent = nil
            lastLiveSignalDetectedSecond = nil
            liveAudioSignalState = .unknown
            liveAudioSignalSilenceDuration = nil
            liveSignalStatus = "Waiting for signal from \(liveInputSignalName)."
            liveBufferStatus = "Priming live buffer."
            if sourceMode == .roon {
                refreshRoonNowPlayingIfNeeded(force: true)
            }
            if sourceMode == .spotify {
                refreshSpotifyNowPlayingIfNeeded(force: true, reason: "monitor started")
                refreshSpotifyConnectServerIfNeeded(reason: "monitor started")
            }

            if sourceMode == .roon, inputRoute.isRoonLoopback {
                statusMessage = "Make sure Roon is playing to Orbisonic."
            } else if sourceMode == .spotify, inputRoute.isSpotifyLoopback {
                statusMessage = spotifyHasActiveSessionForStatus
                    ? "Spotify is connected. Control playback from Spotify."
                    : "Open Spotify and choose Orbisonic from the devices menu."
            } else {
                statusMessage = sourceMode == .aux
                    ? "Select Orbisonic Aux Cable as the output device in Ableton Live, QLab, SPAT Revolution, GarageBand, or another app."
                    : "Connect an audio source to the selected input."
            }

            AppLogger.shared.notice(
                category: "live-input",
                "Live input active source=\(sourceMode.rawValue) reason=\(reason) input=\(inputRoute.deviceName) uid=\(inputRoute.uid) activeChannels=\(requestedChannelCount)"
            )
            logInputSourceStatusIfNeeded(reason: "live input started: \(reason)", force: true)
        } catch {
            liveMonitorState = .error(error.localizedDescription)
            AppLogger.shared.error(category: "ui", "Live input failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            logInputSourceStatusIfNeeded(reason: "live input failed: \(reason)", force: true)
        }
    }

    private func recoverRoonMonoRouteIfNeeded(reason: String) -> Bool {
        guard sourceMode == .roon else { return true }

        let isStaleMono = inputRoute.inputChannelCount == 1 || activeLiveChannelCount == 1
        guard isStaleMono else { return true }

        AppLogger.shared.warning(
            category: "route",
            "Recovering stale Roon mono route reason=\(reason) route=\(inputRoute.deviceName) channels=\(inputRoute.inputChannelCount) active=\(activeLiveChannelCount)"
        )

        refreshRoutesIfNeeded(force: true)
        selectExpectedLoopbackInputIfAvailable(for: .roon)
        activeLiveChannelCount = 2

        guard inputRoute.isRoonLoopback, inputRoute.inputChannelCount >= 2 else {
            let message = "Roon route recovery could not find a valid stereo-or-better Orbisonic Roon Input."
            statusMessage = message
            lastError = message
            liveMonitorState = .unavailable(message)
            AppLogger.shared.error(category: "route", message)
            return false
        }

        AppLogger.shared.notice(
            category: "route",
            "Recovered Roon route input=\(inputRoute.deviceName) channels=\(inputRoute.inputChannelCount) active=2"
        )
        return true
    }

    func togglePlayback() {
        let stateBefore = debugPlaybackStateSnapshot()
        var commandAllowed = true
        var commandError: String?
        defer {
            logTransportDebug(
                command: "toggle",
                allowed: commandAllowed,
                handler: "togglePlayback",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }
        cancelDiagnosticsForMusicAction()

        if sourceMode == .roon {
            if liveMonitorState.isMuted {
                resumeLiveMonitor()
            } else if isPlaying {
                muteLiveMonitor()
            } else {
                startRoonPipe()
            }
            return
        }

        if sourceMode == .spotify {
            if liveMonitorState.isMuted {
                resumeLiveMonitor()
            } else if isPlaying {
                muteLiveMonitor()
            } else {
                startSpotifyPipe()
            }
            return
        }

        if sourceMode == .aux {
            if liveMonitorState.isMuted {
                resumeLiveMonitor()
            } else if isPlaying {
                muteLiveMonitor()
            } else {
                startOtherInputPipe()
            }
            return
        }

        if sourceMode == .atmosDRP {
            if dolbyReferencePlayerSnapshot.state == .playing {
                pauseAtmosDRPTransport()
            } else {
                playAtmosDRPTransport()
            }
            return
        }

        if sourceMode == .testTone {
            if isTestTonePlaying {
                stopTestTone()
            } else {
                playSelectedTestTone()
            }
            return
        }

        guard duration > 0 else {
            statusMessage = "Open a surround file first."
            AppLogger.shared.debug(category: "ui", "Play requested before a file was loaded.")
            commandAllowed = false
            commandError = statusMessage
            return
        }

        do {
            if isPlaying {
                engine.pause()
                isPlaying = false
                reevaluateAutomaticRendererMode(reason: "pause")
                statusMessage = "Paused."
            } else {
                if let source = currentLocalSourceDescriptionForGate(),
                   let gateError = blockLocalFileProductionIfNeeded(
                    source,
                    debugTiming: nil,
                    fileURL: currentFileURL,
                    isSessionRunning: true
                   ) {
                    commandAllowed = false
                    commandError = gateError.localizedDescription
                    return
                }
                guard prepareOutputForMusicPlayback() else { return }
                reevaluateAutomaticRendererMode(reason: "play")
                try engine.play()
                isPlaying = true
                statusMessage = "Playing through \(routeDisplayName) with \(rendererRenderMode.displayName)."
            }
        } catch {
            AppLogger.shared.error(category: "ui", "Playback toggle failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            commandError = error.localizedDescription
        }
    }

    var roonTransportStatusText: String {
        roonBridgeSnapshot.statusText
    }

    var roonAudioPathText: String {
        roonBridgeSnapshot.audioPathText
    }

    var roonTransportCompactStatusText: String {
        roonBridgeSnapshot.compactStatusText
    }

    var roonTransportTitleText: String? {
        roonBridgeSnapshot.selectedZone?.titleText
    }

    var roonTransportSubtitleText: String? {
        roonBridgeSnapshot.selectedZone?.subtitleText
    }

    var isRoonTransportPlaying: Bool {
        roonBridgeSnapshot.selectedZone?.isPlaying == true
    }

    func canSendRoonTransport(_ control: RoonBridgeControl) -> Bool {
        guard sourceMode == .roon,
              roonBridgeSnapshot.isReadyForTransport,
              let selectedZone = roonBridgeSnapshot.selectedZone
        else {
            return false
        }

        return selectedZone.allows(control)
    }

    func openRoon() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.roon.Roon") else {
            statusMessage = "Open Roon and enable Orbisonic in Settings > Extensions."
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.statusMessage = "Could not open Roon: \(error.localizedDescription)"
                    self?.lastError = error.localizedDescription
                } else {
                    self?.statusMessage = "Opening Roon."
                }
            }
        }
    }

    func toggleRoonTransport() {
        let control: RoonBridgeControl = isRoonTransportPlaying ? .pause : .play
        sendRoonTransport(control)
    }

    func playRoonTransport() {
        sendRoonTransport(.play)
    }

    func pauseRoonTransport() {
        sendRoonTransport(.pause)
    }

    func stopRoonTransport() {
        sendRoonTransport(.stop)
    }

    func playPreviousRoonTrack() {
        sendRoonTransport(.previous)
    }

    func playNextRoonTrack() {
        sendRoonTransport(.next)
    }

    func startSelectedLiveMonitor() {
        guard !isLiveMonitorTransitioning else { return }
        isLiveMonitorTransitioning = true
        defer { isLiveMonitorTransitioning = false }
        startSelectedLiveMonitorNow()
    }

    private func startSelectedLiveMonitorNow() {
        if !isLiveMonitorTransitioning {
            statusMessage = "Preparing \(sourceMode.rawValue) input..."
        }
        switch sourceMode {
        case .off:
            stop()
        case .roon:
            startRoonPipe()
        case .spotify:
            startSpotifyPipe()
        case .aux:
            startOtherInputPipe()
        case .atmosDRP:
            playAtmosDRPTransport()
        case .filePlayback, .testTone:
            togglePlayback()
        }
    }

    @discardableResult
    private func rampTransitionOutput(
        to target: Float,
        duration: TimeInterval,
        abortIfNewSourceSwitchPending: Bool = false
    ) async -> Bool {
        let clampedTarget = min(max(target, 0), 1)
        let start = transitionOutputGain
        let steps = max(Int((duration / 0.01).rounded(.up)), 1)

        for step in 1...steps {
            guard !Task.isCancelled else { return false }
            if abortIfNewSourceSwitchPending, sourceSwitchRequests.pendingMode != nil {
                return false
            }
            let progress = Float(step) / Float(steps)
            transitionOutputGain = start + (clampedTarget - start) * progress
            applyEffectiveOutputVolume(log: false)

            if step < steps {
                await sleepForSourceTransition(duration / Double(steps))
            }
        }
        return true
    }

    private func sleepForSourceTransition(_ duration: TimeInterval) async {
        guard duration > 0 else { return }
        do {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } catch {
            return
        }
    }

    func muteLiveMonitor() {
        guard sourceMode.isLiveInput, isPlaying else { return }
        guard !isLiveMonitorTransitioning else { return }

        engine.setLiveInputMuted(true)
        liveMonitorState = .muted
        monitorMeterStore.reset()
        rendererMeterStore.reset()
        statusMessage = "\(sourceMode.rawValue) audio muted. Input metering remains active."
        AppLogger.shared.notice(category: "live-input", "Muted live monitor source=\(sourceMode.rawValue)")
    }

    func resumeLiveMonitor() {
        guard sourceMode.isLiveInput else { return }
        guard !isLiveMonitorTransitioning else { return }

        if !isPlaying {
            startSelectedLiveMonitor()
            return
        }

        engine.setLiveInputMuted(false)
        liveMonitorState = .monitoring
        statusMessage = "\(sourceMode.rawValue) audio resumed."
        AppLogger.shared.notice(category: "live-input", "Resumed live monitor source=\(sourceMode.rawValue)")
    }

    func stopSelectedLiveMonitor() {
        guard !isLiveMonitorTransitioning else { return }
        isLiveMonitorTransitioning = true
        defer { isLiveMonitorTransitioning = false }
        guard sourceMode.isLiveInput else {
            stop()
            return
        }

        let stoppingSourceMode = sourceMode
        let sourceName = stoppingSourceMode.rawValue
        if stoppingSourceMode == .atmosDRP {
            try? dolbyReferencePlayerController.stop()
            currentAtmosDRPTrack = nil
            currentFileURL = nil
        }
        markLiveMonitorStopped(sourceMode: stoppingSourceMode)
        engine.stop()
        markLiveMonitorStopped(sourceMode: stoppingSourceMode)
        AppLogger.shared.notice(category: "live-input", "Stopped live monitor source=\(sourceName)")
    }

    private func stopLiveMonitorForSourceSwitch(to mode: SourceMode) {
        guard sourceMode.isLiveInput else { return }

        let stoppingSourceMode = sourceMode
        let sourceName = stoppingSourceMode.rawValue
        if stoppingSourceMode == .atmosDRP {
            try? dolbyReferencePlayerController.stop()
            currentAtmosDRPTrack = nil
            currentFileURL = nil
        }
        markLiveMonitorStopped(sourceMode: stoppingSourceMode)
        engine.stop()
        markLiveMonitorStopped(sourceMode: stoppingSourceMode)
        AppLogger.shared.notice(
            category: "live-input",
            "Stopped live monitor source=\(sourceName) before selecting source=\(mode.rawValue)"
        )
    }

    private func markLiveMonitorStopped(sourceMode: SourceMode) {
        isPlaying = false
        liveMonitorState = .stopped
        clearLoadedSourceSnapshot()
        duration = 0
        currentTime = 0
        scrubProgress = 0
        monitorMeterStore.reset()
        rendererMeterStore.reset()
        lastHeartbeatSecond = -1
        lastLiveMeterLogSecond = -1
        lastLiveBufferLogSecond = -1
        lastLiveSilenceWarningSecond = -1
        lastLiveSignalPresent = nil
        lastLiveSignalDetectedSecond = nil
        liveAudioSignalState = .unknown
        liveAudioSignalSilenceDuration = nil
        livePipeStatus = nil
        lastLiveUnderflowCount = 0
        lastLiveUnderflowAt = nil
        liveBufferStatus = "No live buffer."
        let waitingText = stoppedLiveSourceStatusText(for: sourceMode)
        liveSignalStatus = waitingText
        statusMessage = waitingText
    }

    private func stoppedLiveSourceStatusText(for sourceMode: SourceMode) -> String {
        switch sourceMode {
        case .roon:
            return "Waiting for Roon"
        case .spotify:
            return spotifyReceiverStatus.isRunning ? "Waiting for Spotify" : "Spotify unavailable"
        case .aux:
            return "Waiting for Aux audio"
        case .atmosDRP:
            return "Atmos DRP ready"
        case .off:
            return "Orbisonic is idle"
        case .filePlayback:
            return "Local ready"
        case .testTone:
            return "Diagnostics ready"
        }
    }

    private func clearLoadedSourceSnapshot() {
        sourceMetadata = nil
        pureSphericalLosslessState = .none
        clearPendingLocalPresentation()
        loadedChannels = []
        loadedFileName = "No file loaded"
        meterStore.configure(channels: [])
        refreshRendererScene()
    }

    func stop() {
        testToneStopTask?.cancel()
        testToneStopTask = nil
        diagnosticSequenceTask?.cancel()
        diagnosticSequenceTask = nil
        cancelPendingLocalFileLoad()
        resetLocalGaplessHandoffState(reason: "stop")
        diagnosticReturnContext = nil
        if sourceMode == .atmosDRP {
            try? dolbyReferencePlayerController.stop()
            currentAtmosDRPTrack = nil
        }
        engine.stop()
        isPlaying = false
        liveMonitorState = .stopped
        isTestTonePlaying = false
        isDiagnosticSequencePlaying = false
        isDiagnosticTransitioning = false
        activeDiagnosticPoint = nil
        activeDiagnosticChannelIndex = nil
        activeDiagnosticChannelCount = 0
        activeDiagnosticWalkTitle = ""
        rendererDiagnosticsUsingNormalMonitor = false
        rendererDiagnosticsMonitorDownmixAvailable = false
        diagnosticSequencePosition = 0
        currentTime = 0
        scrubProgress = 0
        meterStore.reset()
        monitorMeterStore.reset()
        rendererMeterStore.reset()
        lastHeartbeatSecond = -1
        lastLiveMeterLogSecond = -1
        lastLiveBufferLogSecond = -1
        lastLiveSilenceWarningSecond = -1
        lastLiveSignalPresent = nil
        lastLiveSignalDetectedSecond = nil
        liveAudioSignalState = .unknown
        liveAudioSignalSilenceDuration = nil
        liveSignalStatus = "No live input."
        liveBufferStatus = "No live buffer."
        testToneStatus = ""
        diagnosticWalkStatus = "Ready."
        roonNowPlayingStatus = "Roon metadata stopped."
        roonSignalPath = nil
        currentFileURL = (sourceMode == .filePlayback || sourceMode == .atmosDRP) ? currentFileURL : nil
        reevaluateAutomaticRendererMode(reason: "stop")
        switch sourceMode {
        case .off:
            statusMessage = "Orbisonic is idle"
        case .filePlayback:
            statusMessage = "Local ready"
        case .spotify:
            statusMessage = "Waiting for Spotify"
        case .roon:
            statusMessage = "Waiting for Roon"
        case .aux:
            statusMessage = "Aux has no transport"
        case .atmosDRP:
            statusMessage = "Atmos DRP ready"
        case .testTone:
            statusMessage = "Diagnostics stopped."
        }
    }

    var diagnosticToneSequence: [TestTonePipelinePoint] {
        TestTonePipelinePoint.channelWalkPoints
    }

    var activeDiagnosticText: String {
        if let activeDiagnosticChannelIndex {
            return "\(activeDiagnosticWalkTitle) \(activeDiagnosticChannelIndex + 1) / \(activeDiagnosticChannelCount)"
        }

        if let activeDiagnosticPoint {
            return "\(diagnosticSequencePosition) / \(diagnosticToneSequence.count): \(activeDiagnosticPoint.rawValue)"
        }

        return isDiagnosticSequencePlaying ? "Starting diagnostics..." : "Ready."
    }

    var diagnosticToneActivitySummary: DiagnosticToneActivitySummary {
        guard isTestTonePlaying || isDiagnosticSequencePlaying else {
            return .idle
        }

        let headline: String
        if let activeDiagnosticChannelIndex, activeDiagnosticChannelCount > 0 {
            let title = activeDiagnosticWalkTitle.trimmedNilIfBlank ?? "Diagnostic Tone"
            headline = "\(title) \(activeDiagnosticChannelIndex + 1) / \(activeDiagnosticChannelCount)"
        } else if isTestTonePlaying, testToneStatus.trimmedNilIfBlank != nil {
            headline = selectedTestTonePoint.rawValue
        } else if let activeDiagnosticPoint {
            headline = activeDiagnosticPoint.rawValue
        } else if isDiagnosticSequencePlaying {
            headline = "Starting diagnostics"
        } else {
            headline = "Diagnostic tone active"
        }

        var details: [String] = []
        if let status = testToneStatus.trimmedNilIfBlank {
            details.append(status)
        } else if let status = diagnosticWalkStatus.trimmedNilIfBlank, status != "Ready." {
            details.append(status)
        }

        if rendererDiagnosticsUsingNormalMonitor {
            details.append("Output 2 diagnostics are routed through Normal Monitor.")
        } else if rendererDiagnosticsMonitorDownmixAvailable {
            details.append("Output 1 Monitor downmix is active.")
        }

        return DiagnosticToneActivitySummary(
            isActive: true,
            headline: headline,
            detail: details.isEmpty ? "Tone command active in Orbisonic." : details.joined(separator: " ")
        )
    }

    var monitorChannelWalkCount: Int {
        2
    }

    var rendererOutputChannelWalkCount: Int {
        max(rendererScene.outputSpeakers.count, rendererPreset.outputTopology.fullRangeCount + rendererPreset.outputTopology.lfeCount)
    }

    var diagnosticSpeakerChannelCount: Int {
        Self.diagnosticSpeakerChannelCount
    }

    private func clampedDiagnosticSpeakerChannel(_ channel: Int) -> Int {
        min(max(channel, 1), Self.diagnosticSpeakerChannelCount)
    }

    func selectDiagnosticSpeakerChannel(_ channel: Int) {
        let clamped = clampedDiagnosticSpeakerChannel(channel)
        guard selectedDiagnosticSpeakerChannel != clamped else { return }
        selectedDiagnosticSpeakerChannel = clamped
    }

    func startMonitorChannelWalk() {
        startDiagnosticChannelWalk(kind: .monitor)
    }

    func startRendererOutputChannelWalk() {
        startDiagnosticChannelWalk(kind: .renderer)
    }

    func startDiagnosticChannelWalk() {
        startMonitorChannelWalk()
    }

    private func captureDiagnosticReturnContextIfNeeded() {
        guard diagnosticReturnContext == nil else { return }
        diagnosticReturnContext = DiagnosticReturnContext(
            sourceMode: sourceMode,
            wasPlaying: isPlaying,
            progress: min(max(scrubProgress, 0), 1),
            hadSource: sourceMetadata != nil
        )
    }

    private func clearActiveDiagnosticPlaybackState(
        diagnosticWalkStatus nextWalkStatus: String? = nil,
        testToneStatus nextToneStatus: String? = nil
    ) {
        testToneStopTask?.cancel()
        testToneStopTask = nil
        diagnosticSequenceTask?.cancel()
        diagnosticSequenceTask = nil
        engine.stopTestTone()

        isTestTonePlaying = false
        isDiagnosticSequencePlaying = false
        isDiagnosticTransitioning = false
        activeDiagnosticPoint = nil
        activeDiagnosticChannelIndex = nil
        activeDiagnosticChannelCount = 0
        activeDiagnosticWalkTitle = ""
        rendererDiagnosticsUsingNormalMonitor = false
        rendererDiagnosticsMonitorDownmixAvailable = false
        diagnosticSequencePosition = 0
        meterStore.reset()
        monitorMeterStore.reset()
        rendererMeterStore.reset()
        if let nextWalkStatus {
            diagnosticWalkStatus = nextWalkStatus
        }
        if let nextToneStatus {
            testToneStatus = nextToneStatus
        }
    }

    private func beginDiagnosticPlaybackReplacingCurrent() {
        captureDiagnosticReturnContextIfNeeded()
        clearActiveDiagnosticPlaybackState()
        if isPlaying {
            if sourceMode == .atmosDRP {
                try? dolbyReferencePlayerController.stop(waitBeforeTerminate: false)
            }
            engine.stop()
            isPlaying = false
        }
    }

    private func restoreSourceAfterFailedDiagnosticStart(
        diagnosticWalkStatus walkStatus: String = "Diagnostic start failed.",
        testToneStatus toneStatus: String = "Diagnostic start failed."
    ) {
        clearActiveDiagnosticPlaybackState(
            diagnosticWalkStatus: walkStatus,
            testToneStatus: toneStatus
        )
        restoreMusicAfterDiagnostics()
    }

    private func startDiagnosticChannelWalk(kind: DiagnosticChannelWalkKind) {
        refreshRoutesIfNeeded(force: true)
        beginDiagnosticPlaybackReplacingCurrent()

        guard prepareDiagnosticOutput(for: kind) else {
            restoreSourceAfterFailedDiagnosticStart()
            return
        }

        isTestTonePlaying = true
        isDiagnosticSequencePlaying = true
        isDiagnosticTransitioning = true
        activeDiagnosticPoint = nil
        activeDiagnosticChannelIndex = nil
        activeDiagnosticWalkTitle = kind.title
        activeDiagnosticChannelCount = kind == .monitor ? monitorChannelWalkCount : rendererOutputChannelWalkCount
        diagnosticSequencePosition = 0
        testToneStatus = ""
        if rendererDiagnosticsUsingNormalMonitor, kind == .renderer {
            diagnosticWalkStatus = "Starting Output 2 Renderer channel walk through Normal Monitor."
            statusMessage = "Output 2 Renderer is not set. Routing Output 2 Renderer channel walk through Normal Monitor on \(routeDisplayName)."
        } else if kind == .monitor {
            diagnosticWalkStatus = "Starting Output 1 Local speakers direct stereo channel walk."
            statusMessage = "Running direct stereo Output 1 Local speakers channel walk through \(routeDisplayName)."
        } else {
            diagnosticWalkStatus = "Starting \(kind.shortTitle.lowercased()) channel walk."
            statusMessage = "Running \(kind.shortTitle.lowercased()) channel walk through \(routeDisplayName)."
        }

        AppLogger.shared.notice(
            category: "diagnostics",
            "Started \(kind.title) output=\(outputRoute.deviceName) channels=\(activeDiagnosticChannelCount) normalMonitor=\(rendererDiagnosticsUsingNormalMonitor) returnSource=\(diagnosticReturnContext?.sourceMode.rawValue ?? "none") wasPlaying=\(diagnosticReturnContext?.wasPlaying ?? false)"
        )

        diagnosticSequenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
            } catch {
                await MainActor.run {
                    self?.isDiagnosticTransitioning = false
                }
                return
            }

            await MainActor.run {
                self?.isDiagnosticTransitioning = false
            }

            let total = await MainActor.run {
                self?.activeDiagnosticChannelCount ?? 0
            }

            for index in 0..<total {
                let shouldContinue = await MainActor.run {
                    self?.playDiagnosticChannel(kind: kind, index: index, total: total) ?? false
                }

                guard shouldContinue else { return }

                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    return
                }
            }

            await MainActor.run {
                self?.finishDiagnosticChannelWalk(restoreMusic: true, automatic: true)
            }
        }
    }

    private func prepareDiagnosticOutput(for kind: DiagnosticChannelWalkKind) -> Bool {
        rendererDiagnosticsUsingNormalMonitor = false
        rendererDiagnosticsMonitorDownmixAvailable = false
        try? engine.setDiagnosticMonitorOutputDevice(nil)

        switch kind {
        case .monitor:
            return ensureOutputForAction(.monitor)
        case .renderer:
            return ensureOutputForAction(.renderer)
        }
    }

    private func configureDiagnosticMonitorDownmix() -> Bool {
        configureDiagnosticMonitorDownmix(on: monitorOutputRoute)
    }

    private func configureDiagnosticMonitorDownmix(on route: OutputRouteInfo) -> Bool {
        guard route.isAvailable,
              route.isSelectableOutputTarget
        else {
            AppLogger.shared.warning(category: "diagnostics", "Output 1 Monitor downmix unavailable for Output 2 Renderer diagnostic; no Output 1 Monitor route.")
            return false
        }

        do {
            try engine.setDiagnosticMonitorOutputDevice(route.deviceID)
            return true
        } catch {
            AppLogger.shared.warning(category: "diagnostics", "Output 1 Monitor downmix unavailable: \(error.localizedDescription)")
            return false
        }
    }

    func stopDiagnosticsAndReturnToMusic() {
        finishDiagnosticChannelWalk(restoreMusic: true, automatic: false)
    }

    private func playDiagnosticChannel(
        kind: DiagnosticChannelWalkKind,
        index: Int,
        total: Int
    ) -> Bool {
        guard isDiagnosticSequencePlaying else { return false }

        do {
            let playbackOptions = DiagnosticChannelPlaybackPolicy.options(
                targetsRenderer: kind == .renderer,
                rendererMonitorDownmixAvailable: rendererDiagnosticsMonitorDownmixAvailable,
                rendererUsesNormalMonitor: rendererDiagnosticsUsingNormalMonitor
            )
            try engine.playDiagnosticChannelTone(
                channelIndex: index,
                channelCount: total,
                monitorDownmix: playbackOptions.monitorDownmix,
                primaryOutputEnabled: playbackOptions.primaryOutputEnabled
            )
            activeDiagnosticPoint = nil
            activeDiagnosticChannelIndex = index
            activeDiagnosticChannelCount = total
            activeDiagnosticWalkTitle = kind.title
            diagnosticSequencePosition = index + 1
            if rendererDiagnosticsUsingNormalMonitor, kind == .renderer {
                diagnosticWalkStatus = "Playing Output 2 Renderer channel \(index + 1) of \(total) as Output 1 Monitor downmix."
                statusMessage = "Output 2 Renderer channel \(index + 1) is routed through Normal Monitor on \(routeDisplayName)."
            } else if playbackOptions.monitorDownmix {
                diagnosticWalkStatus = "Playing Output 2 Renderer channel \(index + 1) of \(total) with Output 1 Monitor downmix."
                statusMessage = "Output 2 Renderer channel \(index + 1) is active on \(routeDisplayName); Output 1 Monitor downmix is on \(monitorOutputRoute.deviceName)."
            } else if kind == .monitor {
                diagnosticWalkStatus = "Playing Output 1 Local speakers channel \(index + 1) of \(total) as direct stereo."
                statusMessage = "Output 1 Local speakers channel \(index + 1) is active on \(routeDisplayName) with direct L/R separation."
            } else {
                diagnosticWalkStatus = "Playing \(kind.shortTitle.lowercased()) channel \(index + 1) of \(total)."
                statusMessage = "\(kind.shortTitle) channel \(index + 1) is active on \(routeDisplayName)."
            }

            meterStore.reset()
            switch kind {
            case .monitor:
                applyLocalMonitorDiagnosticMeterLevels(index: index)
            case .renderer:
                applyRendererDiagnosticMeterLevels(index: index, monitorDownmixActive: playbackOptions.monitorDownmix)
            }

            AppLogger.shared.notice(
                category: "diagnostics",
                "\(kind.title) channel \(index + 1)/\(total) output=\(outputRoute.deviceName)"
            )
            return true
        } catch {
            AppLogger.shared.error(category: "diagnostics", "\(kind.title) failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            lastDiagnosticFailure = DiagnosticEvent(message: error.localizedDescription, timestamp: Date())
            finishDiagnosticChannelWalk(restoreMusic: true, automatic: false)
            return false
        }
    }

    private func finishDiagnosticChannelWalk(restoreMusic: Bool, automatic: Bool) {
        clearActiveDiagnosticPlaybackState(
            diagnosticWalkStatus: automatic ? "Diagnostic channel walk finished." : "Diagnostic channel walk stopped."
        )

        AppLogger.shared.notice(
            category: "diagnostics",
            "Finished diagnostic channel walk automatic=\(automatic) restoreMusic=\(restoreMusic)"
        )

        if restoreMusic {
            restoreMusicAfterDiagnostics()
        } else {
            diagnosticReturnContext = nil
        }
    }

    private func restoreMusicAfterDiagnostics() {
        guard let context = diagnosticReturnContext else {
            statusMessage = "Diagnostics stopped. No previous music source to restore."
            return
        }

        diagnosticReturnContext = nil
        sourceMode = context.sourceMode

        switch context.sourceMode {
        case .off:
            statusMessage = "Diagnostics stopped. Orbisonic is idle."

        case .filePlayback:
            guard context.hadSource else {
                statusMessage = "Diagnostics stopped. Open a file or pipe in Roon to continue."
                return
            }

            guard context.wasPlaying, duration > 0 else {
                statusMessage = "Diagnostics stopped. File source is ready."
                return
            }

            do {
                engine.stop()
                scrubProgress = context.progress
                currentTime = duration * scrubProgress
                engine.seek(toProgress: scrubProgress)
                try engine.play()
                isPlaying = true
                statusMessage = "Returned to music at \(formattedCurrentTime())."
            } catch {
                AppLogger.shared.error(category: "diagnostics", "Failed to return to file playback: \(error.localizedDescription)")
                lastError = error.localizedDescription
                lastDiagnosticFailure = DiagnosticEvent(message: error.localizedDescription, timestamp: Date())
                statusMessage = "Diagnostics stopped, but music could not resume."
            }

        case .roon:
            guard context.wasPlaying else {
                statusMessage = "Diagnostics stopped. Roon route is ready."
                return
            }

            startRoonPipe()

        case .spotify:
            guard context.wasPlaying else {
                statusMessage = "Diagnostics stopped. Spotify route is ready."
                return
            }

            startSpotifyPipe()

        case .atmosDRP:
            guard context.wasPlaying else {
                statusMessage = "Diagnostics stopped. Atmos DRP route is ready."
                return
            }
            guard let track = currentAtmosDRPTrack ?? currentLocalMusicTrack else {
                statusMessage = "Diagnostics stopped. Select an Atmos track to resume DRP playback."
                return
            }

            startAtmosDRPPipe(track: track)

        case .testTone:
            statusMessage = "Diagnostics stopped. Test tone source is ready."

        case .aux:
            guard context.wasPlaying else {
                statusMessage = "Diagnostics stopped. Live input route is ready."
                return
            }

            startOtherInputPipe()
        }
    }

    private func cancelDiagnosticsForMusicAction() {
        if isDiagnosticSequencePlaying {
            finishDiagnosticChannelWalk(restoreMusic: false, automatic: false)
        } else if isTestTonePlaying {
            clearActiveDiagnosticPlaybackState(testToneStatus: "Diagnostic tone stopped.")
            diagnosticReturnContext = nil
        }
    }

    func playSelectedTestTone() {
        refreshRoutesIfNeeded(force: true)
        rendererDiagnosticsMonitorDownmixAvailable = false
        try? engine.setDiagnosticMonitorOutputDevice(nil)

        let purpose: OutputPurpose = selectedTestTonePoint.spatialChannel == nil ? .monitor : .renderer
        beginDiagnosticPlaybackReplacingCurrent()

        guard ensureOutputForAction(purpose) else {
            restoreSourceAfterFailedDiagnosticStart()
            return
        }

        let monitorDownmix = purpose == .renderer && configureDiagnosticMonitorDownmix()
        rendererDiagnosticsMonitorDownmixAvailable = monitorDownmix

        do {
            try engine.playTestTone(selectedTestTonePoint, monitorDownmix: monitorDownmix)
            isTestTonePlaying = true
            testToneStatus = "Playing \(selectedTestTonePoint.rawValue) until stopped."
            if monitorDownmix {
                statusMessage = "\(selectedTestTonePoint.pipelineDescription). Output 2 Renderer is \(routeDisplayName); Output 1 Monitor downmix is on \(monitorOutputRoute.deviceName)."
            } else if purpose == .renderer {
                statusMessage = "\(selectedTestTonePoint.pipelineDescription). Listen on \(routeDisplayName). Output 1 Monitor downmix is unavailable."
            } else {
                statusMessage = "\(selectedTestTonePoint.pipelineDescription). Listen on \(routeDisplayName)."
            }

            let channels = selectedTestTonePoint.meterChannels
            meterStore.configure(channels: channels)
            meterStore.update(with: Array(repeating: 0.82, count: channels.count))
            let rendererTestLevels = Array(repeating: Float(0.82), count: rendererScene.matrix.inputCount)
            if monitorDownmix {
                monitorMeterStore.configureIfNeeded(channels: SurroundLayoutDetector.fallbackLayout(for: monitorChannelWalkCount).channels)
                monitorMeterStore.update(
                    with: DiagnosticMonitorDownmixMeterModel.levels(
                        from: [0.82],
                        monitorChannelCount: monitorChannelWalkCount
                    )
                )
            } else if purpose == .renderer {
                monitorMeterStore.reset()
            } else {
                updateMonitorMeters(from: rendererTestLevels.isEmpty ? [Float(0.82)] : rendererTestLevels)
            }
            updateRendererMeters(from: rendererTestLevels)

            AppLogger.shared.notice(
                category: "diagnostics",
                "UI requested test tone point=\(selectedTestTonePoint.rawValue) output=\(outputRoute.deviceName)"
            )
        } catch {
            AppLogger.shared.error(category: "diagnostics", "Test tone failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            lastDiagnosticFailure = DiagnosticEvent(message: error.localizedDescription, timestamp: Date())
            restoreSourceAfterFailedDiagnosticStart(testToneStatus: "Test tone failed.")
        }
    }

    func playSelectedDiagnosticSpeakerTone() {
        refreshRoutesIfNeeded(force: true)
        rendererDiagnosticsUsingNormalMonitor = false
        rendererDiagnosticsMonitorDownmixAvailable = false
        try? engine.setDiagnosticMonitorOutputDevice(nil)
        beginDiagnosticPlaybackReplacingCurrent()

        guard ensureOutputForAction(.renderer) else {
            restoreSourceAfterFailedDiagnosticStart()
            return
        }

        let channel = clampedDiagnosticSpeakerChannel(selectedDiagnosticSpeakerChannel)
        selectDiagnosticSpeakerChannel(channel)
        let monitorDownmix = false
        let primaryOutputEnabled = true

        do {
            try engine.playDiagnosticChannelTone(
                channelIndex: channel - 1,
                channelCount: Self.diagnosticSpeakerChannelCount,
                monitorDownmix: monitorDownmix,
                primaryOutputEnabled: primaryOutputEnabled
            )
            isTestTonePlaying = true
            activeDiagnosticPoint = nil
            activeDiagnosticChannelIndex = channel - 1
            activeDiagnosticChannelCount = Self.diagnosticSpeakerChannelCount
            activeDiagnosticWalkTitle = "Test Tone"
            testToneStatus = "Playing channel \(channel) through the Sonic Sphere renderer."
            statusMessage = "Channel \(channel) tone is active on the Sonic Sphere renderer via \(routeDisplayName)."

            applyRendererDiagnosticMeterLevels(index: channel - 1, monitorDownmixActive: monitorDownmix)

            AppLogger.shared.notice(
                category: "diagnostics",
                "Started speaker test tone channel=\(channel)/\(Self.diagnosticSpeakerChannelCount) normalMonitor=\(rendererDiagnosticsUsingNormalMonitor) output=\(outputRoute.deviceName)"
            )
        } catch {
            AppLogger.shared.error(category: "diagnostics", "Speaker test tone failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            lastDiagnosticFailure = DiagnosticEvent(message: error.localizedDescription, timestamp: Date())
            restoreSourceAfterFailedDiagnosticStart(testToneStatus: "Speaker test tone failed.")
        }
    }

    func stopTestTone(automatic: Bool = false) {
        guard isTestTonePlaying || isDiagnosticSequencePlaying else { return }
        clearActiveDiagnosticPlaybackState(
            diagnosticWalkStatus: automatic ? "Diagnostic channel walk finished." : "Diagnostic channel walk stopped.",
            testToneStatus: automatic ? "Diagnostic tone finished." : "Diagnostic tone stopped."
        )

        if automatic {
            statusMessage = "Diagnostic tone finished. If you heard it, \(routeDisplayName) is receiving app audio."
        }
        restoreMusicAfterDiagnostics()
    }

    func scrubEditingChanged(_ editing: Bool) {
        guard sourceMode == .filePlayback else {
            scrubProgress = 0
            return
        }

        isScrubbing = editing
        if !editing {
            cancelLocalPreparedFilePreload(reason: "seek")
            engine.seek(toProgress: scrubProgress)
            currentTime = duration * scrubProgress
        }
    }

    func formattedCurrentTime() -> String {
        Self.timestamp(currentTime)
    }

    func formattedDuration() -> String {
        if sourceMode.isLiveInput, sourceMetadata != nil {
            return "LIVE"
        }
        return Self.timestamp(duration)
    }

    func currentTuning() -> SpatialTuning {
        SpatialTuning(
            preset: preset,
            frontAngle: frontAngle,
            rearAngle: rearAngle
        )
    }

    func selectRendererPreset(_ preset: RendererPreset) {
        applyRendererPreset(preset, markDirty: false)
        statusMessage = "Selected renderer preset \(preset.name)."
    }

    func setRendererRenderMode(_ nextMode: RendererRenderMode) {
        applyRendererModeRequest(nextMode, reason: "manual mode changed")
    }

    private func applyRendererModePolicyChange(reason: String) {
        applyRendererModeRequest(rendererRenderMode, reason: reason, persistRequestedMode: false)
    }

    private func applyRendererModeRequest(
        _ nextMode: RendererRenderMode,
        reason: String,
        persistRequestedMode: Bool = true
    ) {
        let requestedMode: RendererRenderMode
        switch nextMode {
        case .direct30, .direct31, .directPassthrough:
            requestedMode = .automatic
        default:
            requestedMode = nextMode
        }

        let nextScene = rendererScene(forRequestedMode: requestedMode)
        guard rendererRenderMode != requestedMode || rendererScene != nextScene else { return }

        rendererRenderMode = requestedMode
        if persistRequestedMode {
            persistRendererRenderMode()
        }
        rendererScene = nextScene
        syncRendererAudioRouting()
        configureRendererMeters()
        statusMessage = rendererModeStatusMessage(requestedMode: requestedMode)
        AppLogger.shared.notice(
            category: "renderer",
            "Renderer mode changed reason=\(reason) requested=\(requestedMode.rawValue) effective=\(nextScene.requestedRenderMode.rawValue) resolved=\(nextScene.renderMode.rawValue)"
        )
    }

    func resetRendererTuning() {
        rendererPreset = rendererPreset.replacingOptions(.default)
        rendererPresetIsDirty = false
        UserDefaults.standard.removeObject(forKey: Self.rendererOptionsKey)
        syncRendererControlsFromPreset(rendererPreset)
        rendererPresetStatus = "FEY renderer tuning reset to defaults."
        refreshRendererScene()
        AppLogger.shared.notice(category: "renderer", "Renderer tuning reset to defaults.")
    }

    func saveRendererPreset() {
        do {
            _ = try rendererPresetStore.save(rendererPreset)
            rendererPresetIsDirty = false
            reloadRendererPresets(selectCurrent: true)
            rendererPresetStatus = "Saved \(rendererPreset.name) to JSON."
            AppLogger.shared.notice(
                category: "renderer",
                "Saved renderer preset id=\(rendererPreset.id) name=\(rendererPreset.name) path=\(rendererPresetStore.directoryURL.path)"
            )
        } catch {
            let message = "Renderer preset save failed: \(error.localizedDescription)"
            rendererPresetStatus = message
            lastError = message
            AppLogger.shared.error(category: "renderer", message)
        }
    }

    func reloadRendererPresets(selectCurrent: Bool = true) {
        do {
            let currentID = rendererPreset.id
            let presets = try rendererPresetStore.loadPresets()
            rendererPresets = presets
            rendererPresetDirectoryText = rendererPresetStore.directoryURL.path

            if selectCurrent, let match = presets.first(where: { $0.id == currentID }) {
                applyRendererPreset(match, markDirty: false)
            } else if !presets.contains(where: { $0.id == rendererPreset.id }), let first = presets.first {
                applyRendererPreset(first, markDirty: false)
            } else {
                refreshRendererScene()
            }

            rendererPresetStatus = "Loaded \(presets.count) renderer preset\(presets.count == 1 ? "" : "s")."
        } catch {
            rendererPresets = [.sonicSphere30Point1]
            applyRendererPreset(.sonicSphere30Point1, markDirty: false)
            rendererPresetStatus = "Using built-in preset because JSON presets could not load."
            AppLogger.shared.error(category: "renderer", "Renderer preset reload failed: \(error.localizedDescription)")
        }
    }

    func revealRendererPresetFolder() {
        do {
            try rendererPresetStore.ensureDirectoryAndDefaultPreset()
            NSWorkspace.shared.activateFileViewerSelecting([rendererPresetStore.directoryURL])
        } catch {
            let message = "Could not open renderer preset folder: \(error.localizedDescription)"
            rendererPresetStatus = message
            lastError = message
            AppLogger.shared.error(category: "renderer", message)
        }
    }

    var sourceFlowTitle: String {
        switch sourceMode {
        case .off:
            return "Off"
        case .roon:
            return "Roon"
        case .spotify:
            return "Spotify"
        case .testTone:
            return "Test Tone"
        case .atmosDRP:
            return currentAtmosDRPTrack?.displayTitle ?? "Atmos"
        case .filePlayback:
            return visibleLocalSourceMetadata?.fileName ?? "Local Music"
        case .aux:
            return "Aux Cable"
        }
    }

    var sourceFlowDetail: String {
        if sourceMode == .off {
            return "Orbisonic is idle."
        }

        if sourceMode == .roon {
            if let roonNowPlaying {
                return "\(roonNowPlaying.titleLine) • \(liveSignalStatus) • \(liveBufferStatus)"
            }
            return "\(liveSignalStatus) • \(liveBufferStatus)"
        }

        if sourceMode == .spotify {
            let routeText = inputRoute.isAvailable ? inputRoute.detail : missingLoopbackMessage(for: .spotify)
            return "\(routeText) • \(spotifySetupStatusForPrimaryUI) • \(liveSignalStatus)"
        }

        if sourceMode == .aux {
            let routeText = inputRoute.isAvailable ? inputRoute.detail : missingLoopbackMessage(for: .aux)
            return "\(routeText) • \(liveSignalStatus) • \(liveBufferStatus)"
        }

        if sourceMode == .atmosDRP {
            let routeText = inputRoute.isAvailable ? inputRoute.detail : missingLoopbackMessage(for: .atmosDRP)
            let formatText = dolbyReferencePlayerSnapshot.bitstreamInfo?.formatSummary.trimmedNilIfBlank ?? "Waiting for DRP metadata"
            return "\(routeText) • \(formatText) • \(liveSignalStatus)"
        }

        if sourceMode == .testTone {
            return testToneStatus.isEmpty ? selectedTestTonePoint.rawValue : "\(selectedTestTonePoint.rawValue) • \(testToneStatus)"
        }

        guard let metadata = visibleLocalSourceMetadata else {
            return "Use Local Music to choose a track."
        }

        return "\(metadata.layoutName) • \(metadata.codecName) • \(metadata.channelCount) ch • \(metadata.sampleRateText)"
    }

    var renderFlowTitle: String {
        if sourceMode == .testTone {
            return "Test tone -> Normal Monitor"
        }

        guard let metadata = visibleLocalSourceMetadata else {
            return "Waiting For Render Input"
        }

        if sourceMode == .roon {
            return "\(metadata.layoutName) live -> Normal Monitor stereo downmix"
        }

        switch metadata.channelCount {
        case 1:
            return "Mono -> Normal Monitor stereo downmix"
        case 2:
            return "Stereo -> Normal Monitor"
        default:
            return "\(metadata.layoutName) -> Normal Monitor stereo downmix"
        }
    }

    var renderFlowDetail: String {
        guard let metadata = visibleLocalSourceMetadata else {
            if sourceMode == .testTone {
                return "Synthetic source for Output 1 Monitor and Output 2 Renderer checks."
            }
            return sourceMode.isLiveInput ? liveInputReadinessText : "No source loaded."
        }

        let sourceText = metadata.channelCount == 1
            ? "1 decoded channel"
            : "\(metadata.channelCount) decoded channels"
        return sourceMode.isLiveInput ? "\(sourceText) • live capture" : "\(sourceText) • local player"
    }

    var monitorDownmixPanelModel: MonitorDownmixPanelModel {
        MonitorDownmixPanelModel.make(
            sourceMode: sourceMode,
            metadata: visibleLocalSourceMetadata,
            signalText: renderFlowTitle,
            outputText: monitorOutputNowText,
            liveReadinessText: liveInputReadinessText
        )
    }

    var routeFlowTitle: String {
        outputRoute.deviceName
    }

    var routeFlowDetail: String {
        outputRoute.routeDetail
    }

    var targetFlowTitle: String {
        outputRoute.targetName
    }

    var targetFlowDetail: String {
        outputRoute.targetDetail
    }

    var outputNowText: String {
        outputRoute.isAvailable ? "\(outputRoute.deviceName) • \(outputRoute.routeDetail)" : "No verified macOS output"
    }

    var monitorOutputNowText: String {
        outputText(for: monitorOutputRoute, noneText: "not set")
    }

    var rendererOutputNowText: String {
        outputText(for: rendererOutputRoute, noneText: "not set")
    }

    var monitorOutputSelectionText: String {
        outputSelectionText(
            selection: monitorOutputSelection,
            route: monitorOutputRoute,
            systemLabel: "System Default"
        )
    }

    var rendererOutputSelectionText: String {
        outputSelectionText(
            selection: rendererOutputSelection,
            route: rendererOutputRoute,
            systemLabel: "System Default"
        )
    }

    var monitorOutputDevicePickerText: String {
        outputDevicePickerText(
            selection: monitorOutputSelection,
            resolvedRoute: monitorOutputRoute,
            systemLabel: "System Default"
        )
    }

    var rendererOutputDevicePickerText: String {
        outputDevicePickerText(
            selection: rendererOutputSelection,
            resolvedRoute: rendererOutputRoute,
            systemLabel: "System Default"
        )
    }

    var monitorOutputWarningText: String? {
        outputWarningText(selection: monitorOutputSelection)
    }

    var rendererOutputWarningText: String? {
        if let warning = outputWarningText(selection: rendererOutputSelection) {
            return warning
        }

        guard rendererOutputSelection != .none else {
            return nil
        }

        if DanteSafetyPolicy.requiresHighRateChannelWarning(
            outputChannelCount: rendererScene.outputSpeakers.count,
            sampleRate: rendererOutputRoute.nominalSampleRate
        ) {
            return "This device cannot be used for this output."
        }

        return nil
    }

    var outputDiagnosticsRows: [InputSourceStatusRow] {
        makeOutputDiagnosticsRows(
            title: "Output 1 Monitor",
            selection: monitorOutputSelection,
            resolvedRoute: monitorOutputRoute,
            includesRendererLimit: false
        )
        + makeOutputDiagnosticsRows(
            title: "Output 2 Renderer",
            selection: rendererOutputSelection,
            resolvedRoute: rendererOutputRoute,
            includesRendererLimit: true
        )
    }

    var monitorOutputDiagnosticsRows: [InputSourceStatusRow] {
        makeOutputDiagnosticsRows(
            title: "",
            selection: monitorOutputSelection,
            resolvedRoute: monitorOutputRoute,
            includesRendererLimit: false
        )
    }

    var rendererOutputDiagnosticsRows: [InputSourceStatusRow] {
        makeOutputDiagnosticsRows(
            title: "",
            selection: rendererOutputSelection,
            resolvedRoute: rendererOutputRoute,
            includesRendererLimit: true
        )
    }

    var diagnosticOverallStateText: String {
        if sourceSwitchTargetMode != nil || isLiveMonitorTransitioning || isDiagnosticTransitioning {
            return "recovering"
        }

        if let lastError, !lastError.isEmpty {
            return "errored"
        }

        if sourceMode == .off {
            return "ready"
        }

        if sourceMode.isLiveInput {
            switch liveMonitorState {
            case .monitoring:
                return liveAudioSignalState == .noSignal ? "no signal" : "capturing"
            case .muted:
                return "muted"
            case .silent:
                return "no signal"
            case .unavailable:
                return "blocked"
            case .error:
                return "errored"
            case .stopped:
                return "ready"
            }
        }

        if isLocalFileLoading {
            return "recovering"
        }

        if isTestTonePlaying || isDiagnosticSequencePlaying {
            return "capturing"
        }

        return isPlaying ? "capturing" : "ready"
    }

    var inputPermissionStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not determined"
        @unknown default:
            return "Unknown"
        }
    }

    var diagnosticPreviousSourceText: String {
        diagnosticReturnContext?.sourceMode.rawValue ?? "None"
    }

    var diagnosticOutput2PathText: String {
        if rendererDiagnosticsUsingNormalMonitor {
            return "Normal Monitor"
        }
        if rendererOutputRoute.isAvailable {
            return "Real renderer output"
        }
        return "No Output 2 Renderer route"
    }

    var diagnosticMonitorDownmixText: String {
        if rendererDiagnosticsMonitorDownmixAvailable {
            return "Available on \(monitorOutputRoute.deviceName)"
        }
        if monitorOutputRoute.isAvailable {
            return "Available when Output 2 diagnostics use Normal Monitor"
        }
        return "Unavailable"
    }

    var diagnosticSpeechSampleRateText: String {
        let speechRate = DiagnosticSpeechRenderer.clip(for: selectedDiagnosticSpeakerChannel)?.sampleRate
        let outputRate: Double
        if rendererOutputRoute.isAvailable {
            outputRate = rendererOutputRoute.nominalSampleRate
        } else if outputRoute.isAvailable {
            outputRate = outputRoute.nominalSampleRate
        } else {
            outputRate = 0
        }

        let speechText = speechRate.map(formatSampleRate) ?? "not available"
        let outputText = outputRate > 0 ? formatSampleRate(outputRate) : "unknown output rate"
        return "\(speechText) speech -> \(outputText) output"
    }

    var spotifyAdvertisedDeviceName: String {
        spotifyReceiverClient.configuration.receiverName
    }

    var spotifyHasReceivingAudioForStatus: Bool {
        liveAudioSignalState.isRecentlyReceiving ||
            liveSignalStatus.localizedCaseInsensitiveContains("Signal present") ||
            liveMonitorState == .monitoring
    }

    var spotifyNowPlayingForActiveStatus: SpotifyNowPlaying? {
        if spotifyHasReceivingAudioForStatus {
            return spotifyVisibleNowPlaying ?? spotifyNowPlaying
        }

        if spotifyVisibleNowPlaying?.hasActiveConnectSession == true {
            return spotifyVisibleNowPlaying
        }
        if spotifyNowPlaying?.hasActiveConnectSession == true {
            return spotifyNowPlaying
        }
        return nil
    }

    var spotifyHasActiveSessionForStatus: Bool {
        spotifyNowPlayingForActiveStatus != nil || spotifyHasReceivingAudioForStatus
    }

    var appLaunchContextText: String {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return "Proper .app bundle"
        }
        if Bundle.main.executableURL != nil {
            return "Raw executable"
        }
        return "Unknown"
    }

    func refreshRecentLogSnippetsIfNeeded() {
        guard !hasLoadedRecentLogSnippets,
              !isLoadingRecentLogSnippets
        else { return }

        refreshRecentLogSnippets()
    }

    func refreshRecentLogSnippets() {
        diagnosticsLogRefreshTask?.cancel()
        isLoadingRecentLogSnippets = true
        recentLogSnippetStatus = "Loading recent warning and error lines..."
        AppLogger.shared.info(
            category: "diagnostics",
            "Diagnostics log refresh requested maxBytes=\(Self.diagnosticsLogTailMaxBytes) maxLines=\(Self.diagnosticsLogMaxLines)"
        )

        let logStore = diagnosticsLogStore
        diagnosticsLogRefreshTask = Task { [weak self] in
            let result = await logStore.readRecentInterestingLinesWithMetrics(
                maxBytes: Self.diagnosticsLogTailMaxBytes,
                maxLines: Self.diagnosticsLogMaxLines
            )
            AppLogger.shared.info(
                category: "diagnostics",
                "Diagnostics log refresh finished bytesRead=\(result.bytesRead) fileSizeBytes=\(result.fileSizeBytes) linesReturned=\(result.lines.count) elapsedMs=\(String(format: "%.1f", result.elapsedMilliseconds))"
            )

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }

                self.recentWarningAndErrorLogSnippets = result.lines.map(self.redactSensitiveText)
                self.isLoadingRecentLogSnippets = false
                self.hasLoadedRecentLogSnippets = true
                self.recentLogSnippetStatus = result.lines.isEmpty
                    ? "No recent warning or error lines in the latest log tail."
                    : "Showing \(result.lines.count) recent warning/error line\(result.lines.count == 1 ? "" : "s")."
                self.diagnosticsLogRefreshTask = nil
            }
        }
    }

    var systemOutputNowText: String {
        systemOutputRoute.isAvailable ? "\(systemOutputRoute.deviceName) • \(systemOutputRoute.routeDetail)" : "No verified system output"
    }

    var inputNowText: String {
        inputRoute.isAvailable ? "\(inputRoute.displayName) • \(inputRoute.detail)" : liveInputReadinessText
    }

    var systemInputNowText: String {
        systemInputRoute.isAvailable ? "\(systemInputRoute.displayName) • \(systemInputRoute.detail)" : "No verified macOS system input"
    }

    var roonZoneText: String {
        "Roon"
    }

    var liveInputReadinessText: String {
        if let expectedLoopback = sourceMode.expectedLoopback {
            if sourceMode == .roon {
                return inputRoute.uid == expectedLoopback.deviceUID
                    ? "\(expectedLoopback.displayName) available."
                    : missingLoopbackMessage(for: sourceMode)
            }
            return inputRoute.isAvailable
                ? "\(expectedLoopback.displayName) ready."
                : missingLoopbackMessage(for: sourceMode)
        }

        return inputRoute.roonReadiness
    }

    var selectedSourceDeviceStatusText: String {
        guard let expectedLoopback = sourceMode.expectedLoopback else {
            return visibleLocalSourceMetadata?.fileName ?? "No local file loaded."
        }

        if inputRoute.uid == expectedLoopback.deviceUID {
            return "\(expectedLoopback.displayName) • \(inputRoute.detail)"
        }

        return missingLoopbackMessage(for: sourceMode)
    }

    var liveSourceSampleRateMismatchText: String? {
        guard sourceMode == .roon else {
            return nil
        }

        return roonLoopbackSampleRateMismatchText
    }

    var liveLoopbackDiagnostics: LiveLoopbackDiagnosticSnapshot {
        LiveLoopbackDiagnostics.snapshot(
            sourceMode: sourceMode,
            inputRoute: inputRoute,
            availableInputRoutes: availableInputRoutes,
            activeChannelCount: activeLiveChannelCount,
            signalState: liveAudioSignalState,
            silenceDuration: liveAudioSignalSilenceDuration,
            bufferDiagnostic: livePipeStatus.map {
                LiveLoopbackBufferDiagnostic(
                    minimumBufferedFrames: $0.minimumBufferedFrames,
                    maximumBufferedFrames: $0.maximumBufferedFrames,
                    targetLatencyFrames: $0.targetLatencyFrames,
                    isPriming: $0.isPriming,
                    underflowCount: $0.underflowCount,
                    underflowFrames: $0.underflowFrames,
                    overflowDropFrames: $0.overflowDropFrames
                )
            },
            sampleRateMismatchText: liveSourceSampleRateMismatchText,
            permissionStatusText: inputPermissionStatusText,
            playerActivityText: liveLoopbackPlayerActivityText
        )
    }

    var spotifySourceHealthLines: [SpotifySourceHealthLine] {
        guard sourceMode == .spotify else { return [] }

        let deviceStatus: String
        if inputRoute.isSpotifyLoopback {
            deviceStatus = "Selected input: \(inputRoute.deviceName)"
        } else if let route = availableInputRoutes.first(where: \.isSpotifyLoopback) {
            deviceStatus = "Available input: \(route.deviceName)"
        } else {
            deviceStatus = "Orbisonic Spotify Input unavailable"
        }

        let serverStatus: String
        switch spotifyReceiverStatus.state {
        case .notStarted:
            serverStatus = "Stopped"
        case .embeddedModuleUnavailable:
            serverStatus = "Error"
        case .waitingForConnection:
            if let clientName = spotifyNowPlayingForActiveStatus?.clientName?.trimmedNilIfBlank {
                serverStatus = "Session from \(clientName)"
            } else {
                serverStatus = "Advertising as \(spotifyReceiverClient.configuration.receiverName)"
            }
        case .running:
            serverStatus = "Running"
        case .restarting:
            serverStatus = "Starting"
        case .failed:
            serverStatus = "Error"
        }

        let streamRead: String
        let spotifyChannelCount = SourceMode.spotify.fixedLiveChannelCount ?? activeLiveChannelCount
        if let metadata = sourceMetadata, inputRoute.isSpotifyLoopback {
            streamRead = "Receiving format: \(spotifyChannelCount) channels, \(metadata.sampleRateText) stereo"
        } else if inputRoute.isSpotifyLoopback, liveMonitorState.isCapturing || liveMonitorState.isMuted {
            streamRead = "Monitoring format: \(spotifyChannelCount) channels, \(formatSampleRate(inputRoute.nominalSampleRate)) stereo"
        } else {
            streamRead = "Waiting for stream"
        }

        let signal: String
        switch liveAudioSignalState {
        case .receiving:
            signal = "Receiving"
        case .briefSilence:
            signal = "Brief silence"
        case .silentPassage:
            signal = "Paused or silent"
        case .noSignal:
            signal = "No signal"
        case .unknown:
            signal = lastLiveSignalPresent == true ? "Receiving" : "Unknown"
        }

        return [
            SpotifySourceHealthLine(title: "Spotify audio device", value: deviceStatus),
            SpotifySourceHealthLine(title: "Spotify Connect receiver", value: serverStatus),
            SpotifySourceHealthLine(title: "Spotify input stream", value: streamRead),
            SpotifySourceHealthLine(title: "Audio signal", value: signal)
        ]
    }

    var spotifySetupStatusForPrimaryUI: String {
        switch spotifyReceiverStatus.state {
        case .running:
            return "Available as Orbisonic"
        case .waitingForConnection, .restarting:
            return "Starting"
        case .notStarted:
            return "Unavailable"
        case .failed, .embeddedModuleUnavailable:
            return "Error"
        }
    }

    var outputSafetyText: String {
        if rendererOutputSelection == .none {
            return "Output 2 Renderer is not set. Output 2 Renderer VU remains active."
        }

        if DanteSafetyPolicy.requiresHighRateChannelWarning(
            outputChannelCount: rendererScene.outputSpeakers.count,
            sampleRate: rendererOutputRoute.nominalSampleRate
        ) {
            return "Dante Virtual Soundcard Pro supports only 16x16 channels at 176.4/192 kHz."
        }

        switch rendererOutputRoute.routeRisk {
        case .safe:
            if rendererOutputRoute.isRendererCapableOutput {
                return "Output 2 Renderer selected."
            }
            return "Output 2 Renderer selected."
        case .feedbackLoop(let name):
            return "Blocked: \(name) would feed Orbisonic back into an input loopback."
        case .virtualOutput(let name):
            return "Virtual output: verify \(name) is the intended Output 2 Renderer target."
        case .unavailable:
            return "No verified Output 2 Renderer route."
        }
    }

    var availableLiveChannelCounts: [Int] {
        LiveChannelCountPolicy.availableCounts(
            sourceMode: sourceMode,
            availableInputChannels: inputRoute.inputChannelCount
        )
    }

    var rendererText: String {
        if rendererScene.isBypass {
            return "\(rendererScene.renderMode.statusName) • direct speaker playback"
        }

        guard rendererScene.matrix.inputCount > 0 else {
            if let message = rendererScene.validationMessages.last {
                return "\(rendererRenderMode.displayName) • \(message)"
            }
            return "\(rendererRenderMode.displayName) • waiting for source"
        }
        return "\(rendererScene.renderMode.statusName) • \(rendererScene.matrix.inputCount)x\(rendererScene.matrix.outputCount) matrix"
    }

    var rendererTargetText: String {
        rendererPreset.outputTopology.kind == .sonicSphere ? "Sonic Sphere" : "Sound System"
    }

    var rendererLayoutText: String {
        "\(rendererPreset.outputTopology.fullRangeCount).\(rendererPreset.outputTopology.lfeCount) Spatial"
    }

    var rendererSelectionText: String {
        "\(rendererTargetText) \(rendererLayoutText)"
    }

    var rendererLobeInspectionText: String {
        if rendererScene.isBypass {
            return "Direct speaker playback, renderer bypassed."
        }

        if rendererScene.renderMode.isAuroBed {
            return "Auro lower uses lower/mid FEY lobes • height uses upper lobes • T uses crown"
        }

        return "FL 5/6/11/17/22/28 • FR 2/7/13/18/24/29 • rear supports 9/20/26"
    }

    var rendererChannelOrderText: String {
        if rendererScene.isBypass {
            return rendererScene.renderMode == .direct31
                ? "0...30 direct to outputs 0...30"
                : "0...29 direct to outputs 0...29"
        }

        let renderer = FeyStaticBedRenderer(options: rendererPreset.options)
        let mode = rendererScene.renderMode == .automatic ? rendererRenderMode : rendererScene.renderMode
        return renderer.getInputLayout(layoutId: mode)?.summary ?? "Waiting for supported source"
    }

    var rendererMatrixInspectionText: String {
        if rendererScene.isBypass {
            return rendererScene.renderMode == .direct31 ? "31 direct channels" : "30 direct speaker channels"
        }

        guard rendererScene.matrix.inputCount > 0 else {
            return rendererScene.validationMessages.last ?? "Waiting for supported source"
        }

        let summary = (0..<min(rendererScene.matrix.inputCount, 4)).map { inputIndex in
            let labels = rendererScene.matrix
                .strongestOutputs(forInputAt: inputIndex, limit: 2)
                .map { "\($0.index + 1)" }
                .joined(separator: "/")
            return "In \(inputIndex + 1): \(labels)"
        }
        .joined(separator: " • ")

        return summary.isEmpty ? "No active matrix" : summary
    }

    var monitorOutputStatusText: String {
        return outputStatusText(
            for: monitorOutputRoute,
            selection: monitorOutputSelection,
            noneDetail: "Output 1 Monitor disabled",
            safeDetail: monitorOutputRoute.isRendererCapableOutput ? "multichannel output" : "Output 1 Monitor"
        )
    }

    var appleSpatialHeadphonesToggleIsEnabled: Bool {
        false
    }

    var appleSpatialHeadphonesStatusText: String {
        let status = appleSpatialHeadphoneMonitorStatus
        if status.isActive {
            return status.userVisibleMessage
        }
        if status.isPendingRestart {
            return status.userVisibleMessage
        }
        return status.lastError ?? status.userVisibleMessage
    }

    var appleSpatialHeadphonesDetailText: String {
        let status = appleSpatialHeadphoneMonitorStatus
        switch status.mode {
        case .referenceStereo:
            return "Reference Stereo Monitor is selected. Dante output is unaffected."
        case .appleSpatialHeadphones:
            if status.isActive {
                return status.headTrackingStatus.displayText
            }
            return "Monitor only, Dante unaffected."
        }
    }

    func setAppleSpatialHeadphonesEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(false, forKey: Self.appleSpatialHeadphonesEnabledKey)
        appleSpatialHeadphonesEnabled = false
        refreshAppleSpatialHeadphoneMonitorStatus(updateStatusMessage: enabled)
    }

    private func refreshAppleSpatialHeadphoneMonitorStatus(updateStatusMessage: Bool) {
        let routeDescriptor: AudioContracts.OutputRouteDescriptor? = monitorOutputRoute.isAvailable
            ? RouteCapabilityValidator().outputRouteDescriptor(from: monitorOutputRoute)
            : nil
        let sessionRate: AudioSampleRate? = monitorOutputRoute.nominalSampleRate > 0
            ? try? AudioSampleRate(hertz: monitorOutputRoute.nominalSampleRate)
            : nil
        let nextStatus = appleSpatialHeadphoneMonitor.status(
            mode: .referenceStereo,
            options: .disabled,
            route: routeDescriptor,
            sessionSampleRate: sessionRate,
            liveDesktopBranchConnected: false
        )
        appleSpatialHeadphoneMonitorStatus = nextStatus

        if updateStatusMessage {
            if appleSpatialHeadphonesEnabled {
                appleSpatialHeadphonesEnabled = false
            }
            statusMessage = "Apple Spatial Headphones is disabled in this build. Reference Stereo Monitor is active."
        }
    }

    var rendererOutputStatusText: String {
        if rendererOutputSelection == .none {
            return "not set • Output 2 Renderer not selected"
        }

        if DanteSafetyPolicy.requiresHighRateChannelWarning(
            outputChannelCount: rendererScene.outputSpeakers.count,
            sampleRate: rendererOutputRoute.nominalSampleRate
        ) {
            return "Warning • 176.4/192 kHz limits high channel counts"
        }

        return outputStatusText(
            for: rendererOutputRoute,
            selection: rendererOutputSelection,
            noneDetail: "Output 2 Renderer not selected",
            safeDetail: "Output 2 Renderer selected"
        )
    }

    var rendererSceneOutputText: String {
        let target = "\(rendererTargetText) \(rendererPreset.outputTopology.fullRangeCount).\(rendererPreset.outputTopology.lfeCount)"
        if rendererScene.isBypass {
            return "\(target) • Direct speaker playback, renderer bypassed"
        }

        guard rendererScene.matrix.inputCount > 0 else {
            if let message = rendererScene.validationMessages.last {
                return "\(target) • \(message)"
            }
            return "\(target) • waiting for source"
        }

        return "\(target) • \(rendererScene.matrix.inputCount) -> \(rendererScene.matrix.outputCount) matrix"
    }

    private func outputText(for route: OutputRouteInfo, noneText: String) -> String {
        route.isAvailable ? "\(route.deviceName) • \(route.routeDetail)" : noneText
    }

    private func outputSelectionText(
        selection: OutputSelectionMode,
        route: OutputRouteInfo,
        systemLabel: String
    ) -> String {
        switch selection {
        case .none:
            return "not set"
        case .systemDefault:
            return route.isAvailable ? "\(systemLabel): \(route.deviceName)" : systemLabel
        case .device:
            return route.isAvailable ? route.deviceName : "Unavailable Device"
        }
    }

    private func outputDevicePickerText(
        selection: OutputSelectionMode,
        resolvedRoute: OutputRouteInfo,
        systemLabel: String
    ) -> String {
        switch selection {
        case .none:
            return "not set"
        case .systemDefault:
            let route = selectedOutputCandidate(for: selection) ?? resolvedRoute
            return route.isAvailable ? "\(systemLabel): \(route.deviceName)" : systemLabel
        case .device:
            if let route = selectedOutputCandidate(for: selection), route.isAvailable {
                return route.deviceName
            }
            return resolvedRoute.isAvailable ? resolvedRoute.deviceName : "Unavailable Device"
        }
    }

    private func outputStatusText(
        for route: OutputRouteInfo,
        selection: OutputSelectionMode,
        noneDetail: String,
        safeDetail: String
    ) -> String {
        if selection == .none {
            return "not set • \(noneDetail)"
        }

        guard route.isAvailable else {
            return "Unavailable • no verified route"
        }

        switch route.routeRisk {
        case .safe:
            return "Safe • \(safeDetail)"
        case .feedbackLoop(let name):
            return "Blocked • \(name) would feed back into Orbisonic"
        case .virtualOutput(let name):
            return "Warning • verify \(name) is the intended target"
        case .unavailable:
            return "Unavailable • no verified route"
        }
    }

    private func outputWarningText(selection: OutputSelectionMode) -> String? {
        guard selection != .none else {
            return nil
        }

        guard let selectedRoute = selectedOutputCandidate(for: selection),
              selectedRoute.isAvailable
        else {
            return "This device is unavailable. Choose another output."
        }

        if selectedRoute.routeRisk.blocksLiveMonitoring {
            return "This output may create a feedback loop. Choose a different device."
        }

        if !selectedRoute.isSelectableOutputTarget {
            return "This device cannot be used for this output."
        }

        return nil
    }

    private func selectedOutputCandidate(for selection: OutputSelectionMode) -> OutputRouteInfo? {
        switch selection {
        case .none:
            return nil
        case .systemDefault:
            return systemOutputRoute
        case .device(let uid):
            return availableOutputRoutes.first { $0.uid == uid }
        }
    }

    private func makeOutputDiagnosticsRows(
        title: String,
        selection: OutputSelectionMode,
        resolvedRoute: OutputRouteInfo,
        includesRendererLimit: Bool
    ) -> [InputSourceStatusRow] {
        func rowTitle(_ suffix: String) -> String {
            title.trimmedNilIfBlank.map { "\($0) \(suffix)" } ?? suffix
        }

        let selectedRoute = selectedOutputCandidate(for: selection)
        let diagnosticRoute = selectedRoute ?? (resolvedRoute.isAvailable ? resolvedRoute : nil)
        var rows: [InputSourceStatusRow] = [
            InputSourceStatusRow(title: rowTitle("selected device"), value: outputDiagnosticSelectionText(selection: selection, selectedRoute: selectedRoute)),
            InputSourceStatusRow(title: rowTitle("resolved device"), value: outputDiagnosticRouteText(resolvedRoute)),
            InputSourceStatusRow(title: rowTitle("device UID"), value: diagnosticRoute?.uid.trimmedNilIfBlank ?? outputSelectedDeviceUID(selection) ?? "none"),
            InputSourceStatusRow(title: rowTitle("resolved device UID"), value: resolvedRoute.uid.trimmedNilIfBlank ?? "none"),
            InputSourceStatusRow(title: rowTitle("transport"), value: diagnosticRoute?.transportName ?? "none"),
            InputSourceStatusRow(title: rowTitle("channels"), value: diagnosticRoute.map { "\($0.outputChannelCount)" } ?? "none"),
            InputSourceStatusRow(title: rowTitle("sample rate"), value: outputDiagnosticSampleRateText(diagnosticRoute)),
            InputSourceStatusRow(title: rowTitle("route detail"), value: diagnosticRoute?.routeDetail ?? "not selected"),
            InputSourceStatusRow(title: rowTitle("safety"), value: outputSafetyClassification(for: diagnosticRoute)),
            InputSourceStatusRow(title: rowTitle("feedback loop"), value: outputFeedbackClassification(for: diagnosticRoute))
        ]

        if case .device(let uid) = selection, selectedRoute == nil {
            rows.append(InputSourceStatusRow(title: rowTitle("unavailable remembered device"), value: uid))
        }

        if let selectedRoute, case .virtualOutput(let name) = selectedRoute.routeRisk {
            rows.append(InputSourceStatusRow(title: rowTitle("virtual-device warning"), value: "Verify \(name) is the intended output target."))
        }

        if includesRendererLimit,
           rendererOutputSelection != .none,
           DanteSafetyPolicy.requiresHighRateChannelWarning(
               outputChannelCount: rendererScene.outputSpeakers.count,
               sampleRate: rendererOutputRoute.nominalSampleRate
           ) {
            rows.append(InputSourceStatusRow(title: rowTitle("high-rate channel warning"), value: "Dante Virtual Soundcard Pro supports only 16x16 channels at 176.4/192 kHz."))
        }

        return rows
    }

    private func outputDiagnosticSelectionText(
        selection: OutputSelectionMode,
        selectedRoute: OutputRouteInfo?
    ) -> String {
        switch selection {
        case .none:
            return "not set"
        case .systemDefault:
            if let selectedRoute, selectedRoute.isAvailable {
                return "System Default: \(selectedRoute.deviceName) • \(selectedRoute.routeDetail)"
            }
            return "System Default unavailable"
        case .device(let uid):
            if let selectedRoute, selectedRoute.isAvailable {
                return "\(selectedRoute.deviceName) • \(selectedRoute.routeDetail)"
            }
            return "Remembered device UID \(uid)"
        }
    }

    private func outputDiagnosticRouteText(_ route: OutputRouteInfo) -> String {
        route.isAvailable ? "\(route.deviceName) • \(route.routeDetail)" : "none"
    }

    private func outputSelectedDeviceUID(_ selection: OutputSelectionMode) -> String? {
        if case .device(let uid) = selection {
            return uid
        }
        return nil
    }

    private func outputDiagnosticSampleRateText(_ route: OutputRouteInfo?) -> String {
        guard let route, route.nominalSampleRate > 0 else {
            return "unknown"
        }
        return formatSampleRate(route.nominalSampleRate)
    }

    private func outputSafetyClassification(for route: OutputRouteInfo?) -> String {
        guard let route else {
            return "not selected"
        }

        switch route.routeRisk {
        case .safe:
            return "safe"
        case .feedbackLoop(let name):
            return "feedback loop blocked: \(name)"
        case .virtualOutput(let name):
            return "virtual output warning: \(name)"
        case .unavailable:
            return "unavailable"
        }
    }

    private func outputFeedbackClassification(for route: OutputRouteInfo?) -> String {
        guard let route else {
            return "not selected"
        }

        switch route.routeRisk {
        case .feedbackLoop(let name):
            return "blocked: \(name)"
        case .safe, .virtualOutput:
            return "clear"
        case .unavailable:
            return "unavailable"
        }
    }

    private var routeDisplayName: String {
        outputRoute.isAvailable ? outputRoute.deviceName : "the current macOS output"
    }

    private var liveInputSourceName: String {
        switch sourceMode {
        case .off:
            return "Off"
        case .roon:
            return "Roon"
        case .spotify:
            return "Spotify"
        case .aux:
            return "Aux Cable"
        case .atmosDRP:
            return "Atmos"
        case .filePlayback:
            return "Local Music"
        case .testTone:
            return "Test Tone"
        }
    }

    private var liveInputSignalName: String {
        if sourceMode == .roon {
            return OrbisonicLoopbackDevice.roonInput.displayName
        }
        if sourceMode == .spotify {
            return OrbisonicLoopbackDevice.spotifyInput.displayName
        }
        if sourceMode == .aux {
            return OrbisonicLoopbackDevice.auxCable.displayName
        }
        if sourceMode == .atmosDRP {
            return AtmosDRPRoutingPolicy.captureLoopback.displayName
        }
        return inputRoute.deviceName
    }

    private var roonLoopbackSampleRateMismatchText: String? {
        guard let roonRate = roonNowPlaying?.outputSampleRate, inputRoute.nominalSampleRate > 0 else {
            return nil
        }

        guard abs(roonRate - inputRoute.nominalSampleRate) > 1 else {
            return nil
        }

        return "Roon is streaming \(formatSampleRate(roonRate)) but \(liveInputSignalName) is \(formatSampleRate(inputRoute.nominalSampleRate)). Set the Roon output and Orbisonic loopback to the same rate, then restart listening."
    }

    private var roonLoopbackSampleRateMismatch: Double? {
        guard let roonRate = roonNowPlaying?.outputSampleRate,
              inputRoute.isRoonLoopback || inputRoute.isBlackHole,
              inputRoute.nominalSampleRate > 0,
              abs(roonRate - inputRoute.nominalSampleRate) > 1
        else { return nil }

        return roonRate
    }

    private func formatSampleRate(_ sampleRate: Double) -> String {
        let kilohertz = sampleRate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return "\(Int(kilohertz.rounded())) kHz"
        }

        return String(format: "%.1f kHz", kilohertz)
    }

    private func preferredLiveChannelCount() -> Int {
        LiveChannelCountPolicy.preferredCount(
            sourceMode: sourceMode,
            availableInputChannels: inputRoute.inputChannelCount,
            activeCount: activeLiveChannelCount
        )
    }

    @discardableResult
    private func selectExpectedLoopbackInputIfAvailable(for mode: SourceMode) -> Bool {
        guard let route = expectedLoopbackRoute(for: mode) else {
            return false
        }

        if inputRoute.deviceID != route.deviceID {
            inputRoute = route
            AppLogger.shared.notice(
                category: "route",
                "Selected expected source input source=\(mode.rawValue) device=\(route.deviceName) uid=\(route.uid)"
            )
        }

        applyLiveChannelDefaults(for: route)

        return true
    }

    private func expectedLoopbackRoute(for mode: SourceMode) -> InputRouteInfo? {
        guard let expectedLoopback = mode.expectedLoopback else { return nil }
        return availableInputRoutes.first { $0.uid == expectedLoopback.deviceUID }
    }

    private func missingLoopbackMessage(for mode: SourceMode) -> String {
        mode.missingLoopbackMessage()
    }

    private func inputSelectionBlockedMessage(for route: InputRouteInfo) -> String {
        guard let expectedLoopback = sourceMode.expectedLoopback else {
            return "\(sourceMode.rawValue) does not use \(route.deviceName) as a live input."
        }

        switch sourceMode {
        case .roon:
            return "Roon mode captures \(expectedLoopback.displayName) only."
        case .spotify:
            return "Spotify mode captures \(expectedLoopback.displayName) only. Aux Cable and Roon Input stay separate."
        case .aux:
            return "Aux Cable mode captures \(expectedLoopback.displayName) only."
        case .atmosDRP:
            return "Atmos mode captures \(expectedLoopback.displayName) until the dedicated Atmos input exists."
        case .off, .filePlayback, .testTone:
            return "\(sourceMode.rawValue) does not use a live input route."
        }
    }

    private var outputFeedbackMessage: String {
        outputFeedbackMessage(for: outputRoute, purpose: .renderer)
    }

    private func outputFeedbackMessage(for route: OutputRouteInfo, purpose: OutputPurpose) -> String {
        switch route.routeRisk {
        case .feedbackLoop(let name):
            return "Blocked: \(name) would feed Orbisonic output back into an input loopback. Choose a safe \(purpose.lowerTitle) output or leave it not set."
        case .virtualOutput(let name):
            return "Output is currently the virtual device \(name). Verify it is the intended \(purpose.lowerTitle) target."
        case .safe:
            return "Output route is safe."
        case .unavailable:
            return "No \(purpose.lowerTitle) output route is available."
        }
    }

    @discardableResult
    private func applyOutputRouteIfAvailable(
        _ route: OutputRouteInfo,
        purpose: OutputPurpose,
        label: String,
        applyAsynchronously: Bool = false
    ) -> Bool {
        let stateBefore = debugPlaybackStateSnapshot()
        let previousDevice = outputRoute.deviceName
        guard route.isAvailable else {
            statusMessage = "\(purpose.title) output not set."
            logOutputRoutingDebug(
                output: purpose.title,
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: statusMessage
            )
            return false
        }

        guard route.isSelectableOutputTarget else {
            let message = outputFeedbackMessage(for: route, purpose: purpose)
            statusMessage = message
            lastError = message
            logOutputRoutingDebug(
                output: purpose.title,
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: message
            )
            return false
        }

        if routesMatch(outputRoute, route) {
            outputRoute = route
            configureMonitorMeters()
            syncRendererAudioRouting()
            statusMessage = "\(purpose.title) output set to \(label)."
            AppLogger.shared.notice(
                category: "route",
                "\(purpose.title) output label=\(label) already active; keeping current audio graph."
            )
            logOutputRoutingDebug(
                output: purpose.title,
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false
            )
            return true
        }

        if isPlaying || isTestTonePlaying || isDiagnosticSequencePlaying {
            stop()
        }

        do {
            if applyAsynchronously {
                outputRoute = route
                configureMonitorMeters()
                syncRendererAudioRouting()
                statusMessage = "\(purpose.title) output set to \(label)."
                AppLogger.shared.notice(
                    category: "route",
                    "Selected \(purpose.lowerTitle) output label=\(label) device=\(route.deviceName) uid=\(route.uid) channels=\(route.outputChannelCount) sampleRate=\(formatSampleRate(route.nominalSampleRate)) (async apply)"
                )
                logOutputRoutingDebug(
                    output: purpose.title,
                    previousDevice: previousDevice,
                    newDevice: route.deviceName,
                    playbackStateBefore: stateBefore,
                    graphRebuild: true
                )
                beginAsyncOutputDeviceApply(deviceID: route.deviceID, deviceName: route.deviceName)
                return true
            }
            try engine.setOutputDevice(route.deviceID)
            outputRoute = route
            configureMonitorMeters()
            syncRendererAudioRouting()
            statusMessage = "\(purpose.title) output set to \(label)."
            AppLogger.shared.notice(
                category: "route",
                "Selected \(purpose.lowerTitle) output label=\(label) device=\(route.deviceName) uid=\(route.uid) channels=\(route.outputChannelCount) sampleRate=\(formatSampleRate(route.nominalSampleRate))"
            )
            logOutputRoutingDebug(
                output: purpose.title,
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: true
            )
            return true
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not select \(label) for \(purpose.lowerTitle)."
            AppLogger.shared.error(category: "route", "\(purpose.title) output selection failed: \(error.localizedDescription)")
            logOutputRoutingDebug(
                output: purpose.title,
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: true,
                error: error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    private func applyMonitorOutputRouteIfAvailable(
        _ route: OutputRouteInfo,
        previousDevice: String,
        label: String
    ) -> Bool {
        let stateBefore = debugPlaybackStateSnapshot()
        guard route.isAvailable else {
            statusMessage = "Output 1 Monitor output not set."
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: statusMessage
            )
            return false
        }

        guard route.isSelectableOutputTarget else {
            let message = outputFeedbackMessage(for: route, purpose: .monitor)
            statusMessage = message
            lastError = message
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false,
                error: message
            )
            return false
        }

        if !shouldPreserveRendererOutputDuringMonitorChange, routesMatch(outputRoute, route) {
            outputRoute = route
            configureMonitorMeters()
            syncRendererAudioRouting()
            statusMessage = "Output 1 Monitor output set to \(label)."
            AppLogger.shared.notice(
                category: "route",
                "Output 1 Monitor output label=\(label) already active; keeping current audio graph."
            )
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false
            )
            return true
        }

        if shouldPreserveRendererOutputDuringMonitorChange {
            var graphRebuild = false
            var routeApplyError: String?
            if !routesMatch(outputRoute, rendererOutputRoute) {
                do {
                    graphRebuild = try engine.setOutputDevicePreservingPlayback(rendererOutputRoute.deviceID)
                    outputRoute = rendererOutputRoute
                    configureMonitorMeters()
                    syncRendererAudioRouting()
                } catch {
                    routeApplyError = error.localizedDescription
                    lastError = error.localizedDescription
                    statusMessage = "Could not preserve Output 2 Renderer while selecting \(label) for Output 1 Monitor."
                    AppLogger.shared.error(category: "route", statusMessage)
                }
            }

            if routeApplyError == nil {
                statusMessage = "Output 1 Monitor set to \(label). Output 2 Renderer remains \(rendererOutputRoute.deviceName)."
                AppLogger.shared.notice(
                    category: "route",
                    "Selected monitor output label=\(label) device=\(route.deviceName) uid=\(route.uid) while preserving renderer output=\(rendererOutputRoute.deviceName)"
                )
            }

            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: graphRebuild,
                error: routeApplyError
            )
            return routeApplyError == nil
        }

        do {
            let graphRebuild = try engine.setOutputDevicePreservingPlayback(route.deviceID)
            outputRoute = route
            configureMonitorMeters()
            syncRendererAudioRouting()
            statusMessage = "Output 1 Monitor output set to \(label)."
            AppLogger.shared.notice(
                category: "route",
                "Selected monitor output label=\(label) device=\(route.deviceName) uid=\(route.uid) channels=\(route.outputChannelCount) sampleRate=\(formatSampleRate(route.nominalSampleRate))"
            )
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: graphRebuild
            )
            return true
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not select \(label) for Output 1 Monitor."
            AppLogger.shared.error(category: "route", "Output 1 Monitor selection failed: \(error.localizedDescription)")
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: route.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: true,
                error: error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    private func activateRendererOutputIfMonitorWasActive(previousMonitorRoute: OutputRouteInfo) -> Bool {
        guard rendererOutputRoute.isAvailable,
              routesMatch(outputRoute, previousMonitorRoute)
        else {
            return false
        }

        do {
            let graphRebuild = try engine.setOutputDevicePreservingPlayback(rendererOutputRoute.deviceID)
            outputRoute = rendererOutputRoute
            configureMonitorMeters()
            syncRendererAudioRouting()
            return graphRebuild
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not preserve Output 2 Renderer after disabling Output 1 Monitor."
            AppLogger.shared.error(category: "route", statusMessage)
            return true
        }
    }

    private var shouldPreserveRendererOutputDuringMonitorChange: Bool {
        rendererOutputSelection != .none && rendererOutputRoute.isAvailable
    }

    private func routesMatch(_ lhs: OutputRouteInfo, _ rhs: OutputRouteInfo) -> Bool {
        lhs.matchesAudioDevice(rhs)
    }

    private func resolvedMonitorOutputRoute(
        from routes: [OutputRouteInfo],
        systemOutput: OutputRouteInfo
    ) -> OutputRouteInfo {
        OutputRouteSelectionPolicy.monitorRoute(
            from: routes,
            selection: monitorOutputSelection,
            systemOutput: systemOutput
        )
    }

    private func resolvedRendererOutputRoute(
        from routes: [OutputRouteInfo],
        systemOutput: OutputRouteInfo
    ) -> OutputRouteInfo {
        OutputRouteSelectionPolicy.rendererRoute(
            from: routes,
            selection: rendererOutputSelection,
            systemOutput: systemOutput
        )
    }

    private func refreshedActiveOutputRoute(from routes: [OutputRouteInfo]) -> OutputRouteInfo {
        if outputRoute.isAvailable,
           let refreshedRoute = routes.first(where: { $0.uid == outputRoute.uid || $0.deviceID == outputRoute.deviceID }) {
            return refreshedRoute
        }

        if rendererOutputRoute.isAvailable {
            return rendererOutputRoute
        }

        if monitorOutputRoute.isAvailable {
            return monitorOutputRoute
        }

        return .unavailable
    }

    @discardableResult
    private func prepareOutputForMusicPlayback() -> Bool {
        refreshRoutesIfNeeded(force: true)

        if rendererOutputSelection != .none {
            return ensureOutputForAction(.renderer)
        }

        if monitorOutputRoute.isAvailable {
            return applyOutputRouteIfAvailable(monitorOutputRoute, purpose: .monitor, label: monitorOutputRoute.deviceName)
        }

        let fallbackRoute = outputRoute.isAvailable ? outputRoute : systemOutputRoute
        if fallbackRoute.isAvailable {
            guard fallbackRoute.isSelectableOutputTarget else {
                let message = outputFeedbackMessage(for: fallbackRoute, purpose: .renderer)
                statusMessage = message
                lastError = message
                AppLogger.shared.error(category: "route", message)
                return false
            }

            outputRoute = fallbackRoute
            syncRendererAudioRouting()
            return true
        }

        AppLogger.shared.notice(
            category: "route",
            "Music playback starting without an explicit renderer output; using the current legacy output route."
        )
        return true
    }

    @discardableResult
    private func ensureOutputForAction(_ purpose: OutputPurpose) -> Bool {
        refreshRoutesIfNeeded(force: true)

        let selection = purpose == .monitor ? monitorOutputSelection : rendererOutputSelection
        if selection == .none {
            let message = "Select a \(purpose.lowerTitle) output before starting this action."
            statusMessage = message
            lastError = message
            AppLogger.shared.error(category: "route", message)
            return false
        }

        let route = purpose == .monitor ? monitorOutputRoute : rendererOutputRoute
        guard route.isAvailable else {
            let message = "No \(purpose.lowerTitle) output route is available."
            statusMessage = message
            lastError = message
            AppLogger.shared.error(category: "route", message)
            return false
        }

        return applyOutputRouteIfAvailable(route, purpose: purpose, label: route.deviceName)
    }

    private func resolvedSelectedInputRoute(
        from routes: [InputRouteInfo],
        systemInput: InputRouteInfo
    ) -> InputRouteInfo {
        if let expectedLoopback = sourceMode.expectedLoopback,
           let sourceRoute = routes.first(where: { $0.uid == expectedLoopback.deviceUID }) {
            return sourceRoute
        }

        if let selectedInputDeviceUID,
           let persistedRoute = routes.first(where: { $0.uid == selectedInputDeviceUID }) {
            return persistedRoute
        }

        if inputRoute.isAvailable,
           let existingRoute = routes.first(where: { $0.uid == inputRoute.uid || $0.deviceID == inputRoute.deviceID }) {
            return existingRoute
        }

        if systemInput.isAvailable,
           let route = routes.first(where: { $0.uid == systemInput.uid || $0.deviceID == systemInput.deviceID }) {
            return route
        }

        return routes.first ?? .unavailable
    }

    private func applyLiveChannelDefaults(for route: InputRouteInfo) {
        activeLiveChannelCount = LiveChannelCountPolicy.preferredCount(
            sourceMode: sourceMode,
            availableInputChannels: route.inputChannelCount,
            activeCount: activeLiveChannelCount
        )
    }

    private func handlePlaybackEnded() {
        let stateBefore = debugPlaybackStateSnapshot()
        guard isPlaying else {
            logTransportDebug(
                command: "playback-ended",
                allowed: false,
                handler: "handlePlaybackEnded:ignoredWhenNotPlaying",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: "ignored because local playback is not playing"
            )
            return
        }

        if localGaplessQueueEndAwaitingPlaybackEnded {
            finishLocalGaplessQueueAfterPlaybackEnded(stateBefore: stateBefore)
            return
        }

        if isLocalGaplessEngineQueueActive {
            logTransportDebug(
                command: "playback-ended",
                allowed: false,
                handler: "handlePlaybackEnded:ignoredForLocalGaplessQueue",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: "ignored because local gapless scheduler owns queue advancement"
            )
            return
        }

        if playNextLocalMusicTrackAfterNaturalEnd() {
            logTransportDebug(
                command: "playback-ended",
                allowed: true,
                handler: "handlePlaybackEnded:naturalAdvance",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot()
            )
            return
        }

        isPlaying = false
        meterStore.reset()
        monitorMeterStore.reset()
        rendererMeterStore.reset()
        reevaluateAutomaticRendererMode(reason: "playback ended")
        statusMessage = "Playback finished."
        logTransportDebug(
            command: "playback-ended",
            allowed: true,
            handler: "handlePlaybackEnded:finish",
            stateBefore: stateBefore,
            stateAfter: debugPlaybackStateSnapshot()
        )
    }

    private func finishLocalGaplessQueueAfterPlaybackEnded(stateBefore: String) {
        isPlaying = false
        if duration > 0 {
            currentTime = duration
            scrubProgress = 1
        }
        meterStore.reset()
        monitorMeterStore.reset()
        rendererMeterStore.reset()
        reevaluateAutomaticRendererMode(reason: "local gapless queue ended")
        statusMessage = "Playback finished."
        resetLocalGaplessHandoffState(reason: "queue ended")
        logTransportDebug(
            command: "playback-ended",
            allowed: true,
            handler: "handlePlaybackEnded:localGaplessQueueEnd",
            stateBefore: stateBefore,
            stateAfter: debugPlaybackStateSnapshot()
        )
    }

    private func playNextLocalMusicTrackAfterNaturalEnd() -> Bool {
        guard sourceMode == .filePlayback,
              !isLocalGaplessEngineQueueActive,
              !localGaplessQueueEndAwaitingPlaybackEnded
        else { return false }

        if let sessionQueueIndex, sessionQueue.indices.contains(sessionQueueIndex + 1) {
            return playQueueIndex(sessionQueueIndex + 1, isNaturalAdvance: true)
        }

        guard let currentID = currentFileURL?.path else { return false }
        let tracks = visibleLocalMusicTracks
        guard let currentIndex = tracks.firstIndex(where: { $0.id == currentID }),
              tracks.indices.contains(currentIndex + 1)
        else {
            return false
        }

        startSessionQueue(
            from: tracks,
            startTrackID: tracks[currentIndex + 1].id,
            shuffle: false,
            autoplay: true,
            isNaturalAdvance: true
        )
        return true
    }

    private func localMusicComparator(lhs: LocalMusicTrack, rhs: LocalMusicTrack) -> Bool {
        switch localMusicSortMode {
        case .name:
            return compareLocalMusic(lhs, rhs, primary: \.sortName, secondary: \.sortArtist, tertiary: \.sortAlbum)
        case .artist:
            return compareLocalMusic(lhs, rhs, primary: \.sortArtist, secondary: \.sortAlbum, tertiary: \.sortName)
        case .album:
            return compareLocalMusicForAlbum(lhs, rhs)
        }
    }

    private func compareLocalMusicForAlbum(_ lhs: LocalMusicTrack, _ rhs: LocalMusicTrack) -> Bool {
        if let result = localMusicStringSortResult(lhs.sortAlbumOrFolder, rhs.sortAlbumOrFolder) {
            return result
        }

        if lhs.sortDiscNumber != rhs.sortDiscNumber {
            return lhs.sortDiscNumber < rhs.sortDiscNumber
        }

        switch (lhs.effectiveTrackNumber, rhs.effectiveTrackNumber) {
        case let (lhsTrack?, rhsTrack?) where lhsTrack != rhsTrack:
            return lhsTrack < rhsTrack
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if let result = localMusicStringSortResult(lhs.sortFilePath, rhs.sortFilePath) {
            return result
        }

        return compareLocalMusic(lhs, rhs, primary: \.sortName, secondary: \.sortArtist, tertiary: \.sortAlbum)
    }

    private func compareLocalMusic(
        _ lhs: LocalMusicTrack,
        _ rhs: LocalMusicTrack,
        primary: KeyPath<LocalMusicTrack, String>,
        secondary: KeyPath<LocalMusicTrack, String>,
        tertiary: KeyPath<LocalMusicTrack, String>
    ) -> Bool {
        for keyPath in [primary, secondary, tertiary] {
            if let result = localMusicStringSortResult(lhs[keyPath: keyPath], rhs[keyPath: keyPath]) {
                return result
            }
        }

        return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
    }

    private func localMusicStringSortResult(_ lhsValue: String, _ rhsValue: String) -> Bool? {
        let lhsBlank = lhsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rhsBlank = rhsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if lhsBlank != rhsBlank {
            return !lhsBlank
        }
        let comparison = lhsValue.localizedStandardCompare(rhsValue)
        if comparison == .orderedAscending { return true }
        if comparison == .orderedDescending { return false }
        return nil
    }

    private func refreshTransport() {
        refreshRoutesIfNeeded()
        maintainPersistentHelperServices()

        if sourceMode == .roon {
            refreshRoonNowPlayingIfNeeded()
            repairBlackHoleSampleRateIfNeeded()
        }

        refreshSpotifyNowPlayingIfNeeded(reason: "transport refresh")

        let engineDuration = engine.duration()
        if sourceMode == .atmosDRP {
            dolbyReferencePlayerController.refreshMetadata()
            if let trackDuration = currentAtmosDRPTrack?.duration, trackDuration > 0 {
                duration = trackDuration
            }
            if let session = dolbyReferencePlayerSnapshot.session, duration > 0 {
                let nextTime = session.elapsedPlaybackTime()
                let nextProgress = session.progress(duration: duration)
                if abs(nextTime - currentTime) >= (1.0 / 30.0) {
                    currentTime = nextTime
                }
                if abs(nextProgress - scrubProgress) >= 0.003 {
                    scrubProgress = nextProgress
                }
            }
        } else if abs(engineDuration - duration) >= 0.001 {
            duration = engineDuration
        }

        if sourceMode.isLiveInput, isPlaying {
            let nextTime = sourceMode == .atmosDRP ? currentTime : engine.currentTime()
            if abs(nextTime - currentTime) >= (1.0 / 30.0) {
                currentTime = nextTime
            }

            let inputLevels = engine.inputMeterLevels()
            let levels = inputLevels.map(\.displayLevel)
            meterStore.update(with: inputLevels, isActive: VUMeterActivityModel.hasRawSignal(inputLevels))
            updateMonitorMeters()
            updateRendererMeters()

            let wholeSecond = Int(nextTime.rounded(.down))
            updateLiveBufferStatus(elapsedSecond: wholeSecond)

            let peak = levels.max() ?? 0
            updateLiveSignalStatus(peak: peak, elapsedSecond: wholeSecond)

            if wholeSecond >= 0, wholeSecond != lastLiveMeterLogSecond, wholeSecond % 2 == 0 {
                lastLiveMeterLogSecond = wholeSecond
                let levelText = levels
                    .prefix(8)
                    .map { String(format: "%.2f", $0) }
                    .joined(separator: ",")
                AppLogger.shared.debug(
                    category: "live-input",
                    "Live meter time=\(formattedCurrentTime()) peak=\(String(format: "%.2f", peak)) levels=[\(levelText)] output=\(outputRoute.deviceName)"
                )
            }
            return
        }

        guard engineDuration > 0, isPlaying else { return }

        if !isScrubbing {
            let nextTime = engine.currentTime()
            let nextProgress = engineDuration > 0 ? nextTime / engineDuration : 0

            if abs(nextTime - currentTime) >= (1.0 / 30.0) {
                currentTime = nextTime
            }

            if abs(nextProgress - scrubProgress) >= 0.003 {
                scrubProgress = nextProgress
            }

            let wholeSecond = Int(nextTime.rounded(.down))
            if wholeSecond >= 0, wholeSecond != lastHeartbeatSecond, wholeSecond % 2 == 0 {
                lastHeartbeatSecond = wholeSecond
                AppLogger.shared.debug(
                    category: "transport",
                    "Heartbeat time=\(formattedCurrentTime()) / \(formattedDuration()) progress=\(String(format: "%.3f", nextProgress)) playing=\(isPlaying)"
                )
            }
        }

        let inputLevels = engine.inputMeterLevels()
        meterStore.update(with: inputLevels, isActive: VUMeterActivityModel.hasRawSignal(inputLevels))
        updateMonitorMeters()
        updateRendererMeters()
    }

    private func refreshRoutesIfNeeded(force: Bool = false) {
        guard !Self.isRunningUnitTests else { return }

        let now = Date()
        guard force || now.timeIntervalSince(lastRouteRefreshTime) >= 1.0 else { return }
        guard !isRouteRefreshInFlight else {
            if force {
                hasPendingForcedRouteRefresh = true
            }
            return
        }

        lastRouteRefreshTime = now
        isRouteRefreshInFlight = true
        routeRefreshTask?.cancel()
        routeRefreshTask = Task.detached(priority: .utility) {
            let snapshot = RouteRefreshSnapshot(
                systemOutputRoute: OutputRouteMonitor.currentRoute(),
                availableOutputRoutes: OutputRouteMonitor.availableOutputRoutes(),
                availableInputRoutes: OutputRouteMonitor.availableInputRoutes(),
                systemInputRoute: OutputRouteMonitor.currentInputRoute()
            )

            await MainActor.run { [weak self] in
                self?.applyRouteRefreshSnapshot(snapshot)
            }
        }
    }

    /// Apply a refreshed output device without blocking the MainActor. The
    /// expensive CoreAudio syscall runs on the engine's serial queue while the
    /// UI stays responsive; `activity` surfaces the switch to both UIs.
    private func beginAsyncOutputDeviceApply(deviceID: AudioDeviceID, deviceName: String) {
        outputDeviceApplyInFlightID = deviceID
        activity = PlaybackActivity(phase: .switchingOutput, detail: deviceName)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.outputDeviceApplyInFlightID = nil
                if self.activity.phase == .switchingOutput { self.activity = .idle }
            }
            do {
                try await self.engine.setOutputDeviceAsync(deviceID)
                self.lastAppliedOutputDeviceID = deviceID
            } catch {
                AppLogger.shared.warning(
                    category: "route",
                    "Could not apply refreshed output device (async): \(error.localizedDescription)"
                )
            }
        }
    }

    private func applyRouteRefreshSnapshot(_ snapshot: RouteRefreshSnapshot) {
        isRouteRefreshInFlight = false
        defer {
            if hasPendingForcedRouteRefresh {
                hasPendingForcedRouteRefresh = false
                refreshRoutesIfNeeded(force: true)
            }
        }

        let nextSystemOutputRoute = snapshot.systemOutputRoute
        if nextSystemOutputRoute != systemOutputRoute {
            let stateBefore = debugPlaybackStateSnapshot()
            let previousDevice = systemOutputRoute.deviceName
            systemOutputRoute = nextSystemOutputRoute
            AppLogger.shared.notice(
                category: "route",
                "System output route changed device=\(nextSystemOutputRoute.deviceName) transport=\(nextSystemOutputRoute.transportName) channels=\(nextSystemOutputRoute.outputChannelCount) target=\(nextSystemOutputRoute.targetName)"
            )
            logOutputRoutingDebug(
                output: "System Output",
                previousDevice: previousDevice,
                newDevice: nextSystemOutputRoute.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false
            )
        }

        let nextAvailableOutputRoutes = snapshot.availableOutputRoutes
        if nextAvailableOutputRoutes != availableOutputRoutes {
            availableOutputRoutes = nextAvailableOutputRoutes
            let outputNames = nextAvailableOutputRoutes.map(\.deviceName).joined(separator: ", ")
            AppLogger.shared.notice(
                category: "route",
                "Available output routes changed count=\(nextAvailableOutputRoutes.count) devices=[\(outputNames)]"
            )
        }

        if shouldNormalizeStartupMonitorOutputSelection {
            shouldNormalizeStartupMonitorOutputSelection = false
            let normalizedSelection = OutputRouteSelectionPolicy.startupMonitorSelection(
                from: nextAvailableOutputRoutes,
                storedSelection: monitorOutputSelection,
                systemOutput: nextSystemOutputRoute
            )
            if normalizedSelection != monitorOutputSelection {
                AppLogger.shared.notice(
                    category: "route",
                    "Startup monitor output selection normalized from \(monitorOutputSelection.storedValue) to \(normalizedSelection.storedValue)"
                )
                monitorOutputSelection = normalizedSelection
                persistMonitorOutputSelection()
            }
        }

        let nextMonitorOutputRoute = resolvedMonitorOutputRoute(
            from: nextAvailableOutputRoutes,
            systemOutput: nextSystemOutputRoute
        )
        if nextMonitorOutputRoute != monitorOutputRoute {
            let stateBefore = debugPlaybackStateSnapshot()
            let previousDevice = monitorOutputRoute.deviceName
            monitorOutputRoute = nextMonitorOutputRoute
            configureMonitorMeters()
            AppLogger.shared.notice(
                category: "route",
                "Output 1 Monitor route changed device=\(nextMonitorOutputRoute.deviceName) transport=\(nextMonitorOutputRoute.transportName) channels=\(nextMonitorOutputRoute.outputChannelCount) target=\(nextMonitorOutputRoute.targetName)"
            )
            logOutputRoutingDebug(
                output: "Output 1 Monitor",
                previousDevice: previousDevice,
                newDevice: nextMonitorOutputRoute.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: false
            )
        }

        let nextRendererOutputRoute = resolvedRendererOutputRoute(
            from: nextAvailableOutputRoutes,
            systemOutput: nextSystemOutputRoute
        )
        if nextRendererOutputRoute != rendererOutputRoute {
            let stateBefore = debugPlaybackStateSnapshot()
            let previousDevice = rendererOutputRoute.deviceName
            rendererOutputRoute = nextRendererOutputRoute
            configureMonitorMeters()
            configureRendererMeters()
            syncRendererAudioRouting()
            reevaluatePureSphericalLosslessStateForCurrentFile()
            AppLogger.shared.notice(
                category: "route",
                "Output 2 Renderer route changed device=\(nextRendererOutputRoute.deviceName) transport=\(nextRendererOutputRoute.transportName) channels=\(nextRendererOutputRoute.outputChannelCount) target=\(nextRendererOutputRoute.targetName)"
            )
            logOutputRoutingDebug(
                output: "Output 2 Renderer",
                previousDevice: previousDevice,
                newDevice: nextRendererOutputRoute.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: true
            )
        }

        let refreshedActiveRoute = refreshedActiveOutputRoute(from: nextAvailableOutputRoutes)
        if refreshedActiveRoute != outputRoute {
            let stateBefore = debugPlaybackStateSnapshot()
            let previousDevice = outputRoute.deviceName
            outputRoute = refreshedActiveRoute
            configureMonitorMeters()

            let routeApplyError: String? = nil
            var didApplyOutputDevice = false
            let applyPlan = planOutputDeviceApply(
                refreshedDeviceID: refreshedActiveRoute.deviceID,
                isAvailable: refreshedActiveRoute.isAvailable,
                isBusy: isPlaying || isTestTonePlaying || isDiagnosticSequencePlaying,
                currentlyAppliedDeviceID: lastAppliedOutputDeviceID,
                inFlightDeviceID: outputDeviceApplyInFlightID
            )
            if case let .apply(deviceID) = applyPlan {
                didApplyOutputDevice = true
                beginAsyncOutputDeviceApply(deviceID: deviceID, deviceName: refreshedActiveRoute.deviceName)
            }

            AppLogger.shared.notice(
                category: "route",
                "Active output route changed device=\(refreshedActiveRoute.deviceName) transport=\(refreshedActiveRoute.transportName) channels=\(refreshedActiveRoute.outputChannelCount) target=\(refreshedActiveRoute.targetName)"
            )

            if isPlaying {
                statusMessage = "Playing through \(routeDisplayName)."
            } else if let metadata = sourceMetadata {
                statusMessage = "Loaded \(metadata.fileName). Current route: \(routeDisplayName)."
            } else if rendererOutputRoute.isAvailable {
                statusMessage = "Load a surround file. Current Output 2 Renderer: \(rendererOutputRoute.deviceName)."
            } else if monitorOutputRoute.isAvailable {
                statusMessage = "Load a surround file. Current Output 1 Monitor: \(monitorOutputRoute.deviceName)."
            } else {
                statusMessage = "Load a surround file. Output 1 Monitor and Output 2 Renderer are not set."
            }
            logOutputRoutingDebug(
                output: "Active Output",
                previousDevice: previousDevice,
                newDevice: refreshedActiveRoute.deviceName,
                playbackStateBefore: stateBefore,
                graphRebuild: didApplyOutputDevice,
                error: routeApplyError
            )
        }

        let nextAvailableInputRoutes = snapshot.availableInputRoutes
        if nextAvailableInputRoutes != availableInputRoutes {
            availableInputRoutes = nextAvailableInputRoutes
            let inputNames = nextAvailableInputRoutes.map(\.deviceName).joined(separator: ", ")
            AppLogger.shared.notice(
                category: "route",
                "Available Orbisonic input routes changed count=\(nextAvailableInputRoutes.count) devices=[\(inputNames)]"
            )
        }

        let nextSystemInputRoute = snapshot.systemInputRoute
        if nextSystemInputRoute != systemInputRoute {
            systemInputRoute = nextSystemInputRoute
            AppLogger.shared.notice(
                category: "route",
                "System input route changed device=\(nextSystemInputRoute.deviceName) transport=\(nextSystemInputRoute.transportName) channels=\(nextSystemInputRoute.inputChannelCount) sampleRate=\(formatSampleRate(nextSystemInputRoute.nominalSampleRate)) blackHole=\(nextSystemInputRoute.isBlackHole)"
            )
        }

        let nextInputRoute = resolvedSelectedInputRoute(
            from: nextAvailableInputRoutes,
            systemInput: nextSystemInputRoute
        )
        if nextInputRoute != inputRoute {
            let previousInputRoute = inputRoute
            inputRoute = nextInputRoute
            applyLiveChannelDefaults(for: nextInputRoute)
            AppLogger.shared.notice(
                category: "route",
                "Orbisonic input route changed device=\(nextInputRoute.deviceName) transport=\(nextInputRoute.transportName) channels=\(nextInputRoute.inputChannelCount) sampleRate=\(formatSampleRate(nextInputRoute.nominalSampleRate)) blackHole=\(nextInputRoute.isBlackHole)"
            )

            if sourceMode == .spotify, nextInputRoute.isSpotifyLoopback {
                refreshSpotifyConnectServerIfNeeded(reason: "spotify input route changed")
            }

            if sourceMode.isLiveInput, isPlaying, previousInputRoute.deviceID != nextInputRoute.deviceID {
                if !sourceMode.acceptsInputRoute(nextInputRoute) {
                    stop()
                    statusMessage = "Live input stopped because \(sourceMode.expectedLoopback?.displayName ?? "the selected Orbisonic input") is unavailable."
                } else if nextInputRoute.isAvailable {
                    startLiveInputForCurrentRoute(reason: "selected input route changed")
                } else {
                    stop()
                    statusMessage = "Live input stopped because the selected Orbisonic input is unavailable."
                }
            }
        }

        if sourceMode.isLiveInput, isPlaying, outputRoute.routeRisk.blocksLiveMonitoring {
            stop()
            let message = "Live input stopped because macOS output changed to a loopback input. Set output to Output 1 Monitor or Output 2 Renderer, then start the route again."
            AppLogger.shared.error(category: "route", message)
            statusMessage = message
            lastError = message
        }

        if sourceMode.isLiveInput {
            logInputSourceStatusIfNeeded(reason: "route refresh")
        }

        refreshAppleSpatialHeadphoneMonitorStatus(updateStatusMessage: false)
    }

    private func publishTuning() {
        engine.updateTuning(currentTuning())
    }

    private func loadRendererPresets() {
        reloadRendererPresets(selectCurrent: false)
    }

    private func restorePersistedRendererOptions() {
        guard let data = UserDefaults.standard.data(forKey: Self.rendererOptionsKey),
              let options = try? JSONDecoder().decode(FeyRendererOptions.self, from: data)
        else { return }

        rendererPreset = rendererPreset.replacingOptions(options.clamped)
        syncRendererControlsFromPreset(rendererPreset)
        refreshRendererScene()
        rendererPresetIsDirty = true
        rendererPresetStatus = "Loaded persisted FEY renderer tuning."
        AppLogger.shared.notice(category: "renderer", "Loaded persisted renderer tuning from UserDefaults.")
    }

    private func applyRendererPreset(_ preset: RendererPreset, markDirty: Bool) {
        rendererPreset = preset.normalizedForCurrentSchema
        rendererPresetIsDirty = markDirty
        syncRendererControlsFromPreset(rendererPreset)
        refreshRendererScene()
    }

    private func syncRendererControlsFromPreset(_ preset: RendererPreset) {
        suppressRendererPublish = true
        rendererSeamSupportGain = preset.options.seamSupportGain
        rendererUpperBiasDbPerUnitZ = preset.options.upperBiasDbPerUnitZ
        rendererStereoRearFill = preset.options.stereoRearFill
        rendererCenterSideSupportGain = preset.options.centerSideSupportGain
        rendererAdjacentBleed = preset.options.adjacentBleed
        rendererMaxSingleSpeakerPowerShare = preset.options.maxSingleSpeakerPowerShare
        rendererRenderedOutputTrimDb = preset.options.renderedMainTrimDb
        rendererLfeTrimDb = preset.options.lfeTrimDb
        rendererAuroLowerUpperBiasDbPerUnitZ = preset.options.defaultUpperBiasDbPerUnitZ
        rendererAuroHeightUpperBiasDbPerUnitZ = preset.options.heightUpperBiasDbPerUnitZ
        rendererAuroHeightMaxSingleSpeakerPowerShare = preset.options.heightMaxSingleSpeakerPowerShare
        rendererAuroTopMaxSingleSpeakerPowerShare = preset.options.topMaxSingleSpeakerPowerShare
        rendererFiveOneChannelOrder = preset.options.fiveOneChannelOrder
        suppressRendererPublish = false
    }

    private func publishRendererOptions() {
        guard !suppressRendererPublish else { return }

        let options = FeyRendererOptions(
            coreGain: rendererPreset.options.coreGain,
            seamSupportGain: rendererSeamSupportGain,
            upperBiasDbPerUnitZ: rendererUpperBiasDbPerUnitZ,
            stereoRearFill: rendererStereoRearFill,
            centerSideSupportGain: rendererCenterSideSupportGain,
            adjacentBleed: rendererAdjacentBleed,
            maxSingleSpeakerPowerShare: rendererMaxSingleSpeakerPowerShare,
            renderedOutputTrimDb: rendererRenderedOutputTrimDb,
            directOutputTrimDb: rendererPreset.options.directOutputTrimDb,
            fiveOneChannelOrder: rendererFiveOneChannelOrder,
            renderedMainTrimDb: rendererRenderedOutputTrimDb,
            lfeTrimDb: rendererLfeTrimDb,
            defaultMaxSingleSpeakerPowerShare: rendererMaxSingleSpeakerPowerShare,
            heightMaxSingleSpeakerPowerShare: rendererAuroHeightMaxSingleSpeakerPowerShare,
            topMaxSingleSpeakerPowerShare: rendererAuroTopMaxSingleSpeakerPowerShare,
            defaultUpperBiasDbPerUnitZ: rendererAuroLowerUpperBiasDbPerUnitZ,
            heightUpperBiasDbPerUnitZ: rendererAuroHeightUpperBiasDbPerUnitZ
        ).clamped

        rendererPreset = rendererPreset.replacingOptions(options)
        rendererPresetIsDirty = true
        rendererPresetStatus = "FEY renderer tuning changed."
        persistRendererOptions(options)
        syncRendererControlsFromPreset(rendererPreset)
        refreshRendererScene()
    }

    private func persistRendererOptions(_ options: FeyRendererOptions) {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: Self.rendererOptionsKey)
        }
        AppLogger.shared.info(
            category: "renderer",
            "Renderer tuning persisted seam=\(String(format: "%.3f", options.seamSupportGain)) upperBias=\(String(format: "%.3f", options.upperBiasDbPerUnitZ)) rearFill=\(String(format: "%.3f", options.stereoRearFill)) trim=\(String(format: "%.3f", options.renderedOutputTrimDb))"
        )
    }

    private func refreshRendererScene() {
        rendererScene = rendererScene(forRequestedMode: rendererRenderMode)
        syncRendererAudioRouting()
        configureMonitorMeters()
        configureRendererMeters()
    }

    private func rendererScene(forRequestedMode requestedMode: RendererRenderMode) -> RendererSceneModel {
        RendererMatrixBuilder.sceneModel(
            for: currentRendererLayout,
            preset: rendererPreset,
            renderMode: effectiveRendererRenderMode(forRequestedMode: requestedMode)
        )
    }

    // Builds the scene for a freshly loaded file from ITS layout, not the
    // currentRendererLayout (which still reflects loadedChannels from the
    // previous track at commit time). Passed into engine.loadPreparedFile so
    // the single graph rebuild uses the matching matrix instead of stalling
    // in the stereo-monitor fallback on a channel-count mismatch.
    private func committedRendererScene(for loaded: LoadedAudioFile) -> RendererSceneModel {
        let layout = SurroundLayout(
            name: loaded.metadata.layoutName.trimmedNilIfBlank ?? "\(loaded.layout.channelCount)-Channel Input",
            channels: loaded.layout.channels
        )
        return committedRendererScene(for: layout)
    }

    private func committedRendererScene(for layout: SurroundLayout) -> RendererSceneModel {
        let mode = RendererModePolicy.effectiveRequestedMode(
            requestedMode: .automatic,
            inputChannelCount: layout.channelCount,
            alwaysMono: rendererAlwaysMono,
            twoChannelPreference: rendererTwoChannelPreference
        )
        return RendererMatrixBuilder.sceneModel(
            for: layout,
            preset: rendererPreset,
            renderMode: mode
        )
    }

    private func effectiveRendererRenderMode(forRequestedMode requestedMode: RendererRenderMode) -> RendererRenderMode {
        RendererModePolicy.effectiveRequestedMode(
            requestedMode: requestedMode,
            inputChannelCount: currentRendererLayout?.channelCount,
            alwaysMono: rendererAlwaysMono,
            twoChannelPreference: rendererTwoChannelPreference
        )
    }

    private func rendererModeStatusMessage(requestedMode: RendererRenderMode) -> String {
        if let message = rendererScene.validationMessages.last,
           rendererScene.renderMode != rendererScene.requestedRenderMode {
            return message
        }

        if rendererAlwaysMono {
            return "Renderer mode set to Always Mono. Using \(rendererScene.renderMode.displayName)."
        }

        if requestedMode == .automatic,
           currentRendererLayout?.channelCount == 2 {
            return "Renderer Auto uses \(rendererTwoChannelPreference.displayName) for two-channel sources."
        }

        return "Renderer mode set to \(requestedMode.displayName)."
    }

    private func resetRendererRequestToAutomatic(reason: String) {
        guard rendererRenderMode != .automatic else {
            refreshRendererScene()
            return
        }

        rendererRenderMode = .automatic
        persistRendererRenderMode()
        refreshRendererScene()
        AppLogger.shared.info(category: "renderer", "Renderer request reset to Auto reason=\(reason)")
    }

    private func reevaluateAutomaticRendererMode(reason: String) {
        refreshRendererScene()
        if rendererRenderMode == .automatic {
            AppLogger.shared.info(
                category: "renderer",
                "Re-evaluated automatic renderer mode reason=\(reason) resolved=\(rendererScene.renderMode.rawValue) inputChannels=\(rendererScene.matrix.inputCount)"
            )
        }
    }

    private var rendererOutputChannelRequirement: Int {
        rendererOutputChannelRequirement(for: rendererScene)
    }

    private func rendererOutputChannelRequirement(for scene: RendererSceneModel) -> Int {
        if scene.renderMode == .direct30 {
            return FeyStaticBedRenderer.fullRangeOutputs
        }

        if scene.matrix.outputCount > 0 {
            return scene.matrix.outputCount
        }

        return rendererPreset.outputTopology.fullRangeCount + rendererPreset.outputTopology.lfeCount
    }

    private func syncRendererAudioRouting() {
        engine.updateRenderer(
            mode: rendererScene.renderMode,
            scene: rendererScene
        )
    }

    private func configureMonitorMeters() {
        monitorMeterStore.configureIfNeeded(channels: SurroundLayoutDetector.fallbackLayout(for: monitorChannelWalkCount).channels)
    }

    private func updateMonitorMeters(from sourceLevels: [Float] = []) {
        _ = sourceLevels
        let channelCount = monitorChannelWalkCount
        let meterLevels = engine.monitorMeterChannelLevels(channelCount: channelCount)
        monitorMeterStore.configureIfNeeded(channels: SurroundLayoutDetector.fallbackLayout(for: channelCount).channels)
        monitorMeterStore.update(with: meterLevels, isActive: VUMeterActivityModel.hasRawSignal(meterLevels))
    }

    private func configureRendererMeters() {
        rendererMeterStore.configureIfNeeded(channels: rendererMeterChannels())
    }

    func applyLocalMonitorDiagnosticMeterLevels(index: Int) {
        let channelCount = monitorChannelWalkCount
        monitorMeterStore.configureIfNeeded(channels: SurroundLayoutDetector.fallbackLayout(for: channelCount).channels)
        monitorMeterStore.update(with: activeLevel(index: index, count: channelCount))
        rendererMeterStore.reset()
    }

    func applyRendererDiagnosticMeterLevels(index: Int, monitorDownmixActive: Bool) {
        let channels = rendererMeterChannels()
        let rendererLevels = activeLevel(index: index, count: channels.count)
        rendererMeterStore.configureIfNeeded(channels: channels)
        rendererMeterStore.update(with: rendererLevels)

        if monitorDownmixActive {
            monitorMeterStore.configureIfNeeded(channels: SurroundLayoutDetector.fallbackLayout(for: monitorChannelWalkCount).channels)
            monitorMeterStore.update(
                with: DiagnosticMonitorDownmixMeterModel.levels(
                    from: rendererLevels,
                    monitorChannelCount: monitorChannelWalkCount
                )
            )
        } else {
            monitorMeterStore.reset()
        }
    }

    private func updateRendererMeters(from sourceLevels: [Float] = []) {
        _ = sourceLevels
        let channels = rendererMeterChannels()
        guard !channels.isEmpty else { return }

        rendererMeterStore.configureIfNeeded(channels: channels)
        let meterLevels = engine.sonicSphereMeterLevels(channelCount: channels.count)
        let isActive = engine.sonicSphereMeterIsActive()
        sonicSphereMeterActive = isActive
        rendererMeterStore.update(with: meterLevels, isActive: isActive)
    }

    private func updateRenderedMeterStore(
        _ store: ChannelMeterStore,
        channels: [SurroundChannel],
        scene: RendererSceneModel,
        sourceLevels: [Float]
    ) {
        store.configureIfNeeded(channels: channels)

        store.update(with: RendererMeterDisplayModel.levels(for: scene, sourceLevels: sourceLevels))
    }

    private func rendererMeterChannels() -> [SurroundChannel] {
        rendererMeterChannels(for: rendererScene)
    }

    private func rendererMeterChannels(for scene: RendererSceneModel) -> [SurroundChannel] {
        RendererMeterDisplayModel.channels(for: scene)
    }

    private func padded(_ levels: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if levels.count == count { return levels }
        if levels.count > count { return Array(levels.prefix(count)) }
        return levels + Array(repeating: 0, count: count - levels.count)
    }

    private func activeLevel(index: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return (0..<count).map { $0 == index ? 0.86 : 0 }
    }

    private var currentRendererLayout: SurroundLayout? {
        guard !loadedChannels.isEmpty else { return nil }
        return SurroundLayout(
            name: sourceMetadata?.layoutName ?? "\(loadedChannels.count)-Channel Input",
            channels: loadedChannels
        )
    }

    private func updateLiveBufferStatus(elapsedSecond: Int) {
        guard let bufferStatus = engine.liveInputStatus() else {
            livePipeStatus = nil
            liveBufferStatus = "No live buffer."
            return
        }

        livePipeStatus = bufferStatus
        if bufferStatus.underflowCount > lastLiveUnderflowCount {
            lastLiveUnderflowAt = Date()
            lastLiveUnderflowCount = bufferStatus.underflowCount
        }
        liveBufferStatus = bufferStatus.displayText(sampleRate: sourceMetadata?.sampleRate ?? inputRoute.nominalSampleRate)

        guard elapsedSecond >= 0,
              elapsedSecond != lastLiveBufferLogSecond,
              elapsedSecond % 2 == 0
        else { return }

        lastLiveBufferLogSecond = elapsedSecond
        AppLogger.shared.debug(
            category: "live-input",
            "Live buffer \(liveBufferStatus) underflows=\(bufferStatus.underflowCount) underflowFrames=\(bufferStatus.underflowFrames) droppedFrames=\(bufferStatus.overflowDropFrames)"
        )
    }

    private func updateLiveSignalStatus(peak: Float, elapsedSecond: Int) {
        let signalPresent = peak >= Self.liveSignalThreshold

        if signalPresent {
            lastLiveSignalDetectedSecond = elapsedSecond
            setLiveAudioSignalState(
                .receiving,
                silenceDuration: 0,
                reason: "audio signal receiving",
                peak: peak
            )
            liveSignalStatus = "Signal present from \(liveInputSignalName)."
            if !liveMonitorState.isMuted {
                liveMonitorState = .monitoring
            }
            if lastLiveSignalPresent != true && !liveMonitorState.isMuted {
                statusMessage = "Playing through Orbisonic."
                AppLogger.shared.notice(
                    category: "live-input",
                    "Live signal detected peak=\(String(format: "%.2f", peak)) input=\(inputRoute.deviceName) output=\(outputRoute.deviceName)"
                )
            }
            lastLiveSignalPresent = true
            return
        }

        if elapsedSecond < Self.liveSignalStartupGraceSeconds {
            setLiveAudioSignalState(
                .unknown,
                silenceDuration: nil,
                reason: "audio signal startup grace",
                peak: peak
            )
            liveSignalStatus = "Waiting for signal from \(liveInputSignalName)."
            return
        }

        let silenceDuration = lastLiveSignalDetectedSecond.map { max(0, elapsedSecond - $0) } ?? elapsedSecond
        let nextSignalState: LiveAudioSignalState
        if lastLiveSignalDetectedSecond == nil {
            nextSignalState = .noSignal
        } else if silenceDuration < Self.liveSignalBriefSilenceSeconds {
            nextSignalState = .briefSilence
        } else if silenceDuration < Self.liveSignalNoSignalSeconds {
            nextSignalState = .silentPassage
        } else {
            nextSignalState = .noSignal
        }

        setLiveAudioSignalState(
            nextSignalState,
            silenceDuration: silenceDuration,
            reason: "audio signal \(nextSignalState.rawValue)",
            peak: peak
        )
        liveSignalStatus = liveSignalStatusText(for: nextSignalState, silenceDuration: silenceDuration)

        if !liveMonitorState.isMuted {
            liveMonitorState = nextSignalState == .noSignal ? .silent : .monitoring
        }

        if nextSignalState == .noSignal, lastLiveSignalPresent != false {
            statusMessage = liveSignalStatus
            lastLiveSignalPresent = false
        }

        if nextSignalState == .noSignal,
           elapsedSecond != lastLiveSilenceWarningSecond,
           elapsedSecond % 5 == 0 {
            lastLiveSilenceWarningSecond = elapsedSecond
            let diagnosis = liveLoopbackDiagnostics.logSummary
            AppLogger.shared.warning(
                category: "live-input",
                "Selected input is silent elapsed=\(elapsedSecond)s peak=\(String(format: "%.2f", peak)) input=\(inputRoute.deviceName) inputRate=\(formatSampleRate(inputRoute.nominalSampleRate)) roonRate=\(roonNowPlaying?.outputSampleRate.map(formatSampleRate) ?? "unknown") output=\(outputRoute.deviceName) diagnosis=\"\(diagnosis)\""
            )
        }
    }

    private func setLiveAudioSignalState(
        _ state: LiveAudioSignalState,
        silenceDuration: Int?,
        reason: String,
        peak: Float
    ) {
        let previousState = liveAudioSignalState
        liveAudioSignalState = state
        liveAudioSignalSilenceDuration = silenceDuration

        guard previousState != state else { return }

        AppLogger.shared.debug(
            category: "live-input",
            "Live signal state \(previousState.rawValue)->\(state.rawValue) silenceDuration=\(silenceDuration.map { "\($0)s" } ?? "unknown") peak=\(String(format: "%.4f", peak)) source=\(sourceMode.rawValue) input=\(inputRoute.deviceName)"
        )
        logInputSourceStatusIfNeeded(reason: reason)
    }

    private func liveSignalStatusText(for signalState: LiveAudioSignalState, silenceDuration: Int) -> String {
        switch signalState {
        case .receiving:
            return "Signal present from \(liveInputSignalName)."
        case .briefSilence:
            return "\(liveInputSignalName) is briefly silent."
        case .silentPassage:
            return "\(liveInputSignalName) is in a silent passage (\(silenceDuration)s)."
        case .noSignal:
            if sourceMode == .roon, let mismatchText = roonLoopbackSampleRateMismatchText {
                return "\(liveInputSignalName) has no signal. \(mismatchText)"
            }
            if sourceMode == .roon, roonPlaybackIsPausedForSignalStatus {
                return "\(liveInputSignalName) has no signal because Roon is paused."
            }
            if sourceMode == .roon, roonPlaybackIsActiveForSignalStatus {
                return "\(liveInputSignalName) has no signal while Roon is playing."
            }
            if sourceMode == .roon {
                return "\(liveInputSignalName) has no signal. Make sure Roon is playing to Orbisonic."
            }
            if sourceMode == .spotify {
                return "\(liveInputSignalName) has no signal. Open Spotify, choose Orbisonic from Devices / Spotify Connect, then start playback."
            }
            if sourceMode == .atmosDRP {
                return "\(liveInputSignalName) has no signal. Start Atmos DRP playback from Orbisonic."
            }
            return "\(liveInputSignalName) has no signal. Select Orbisonic Aux Cable as the output device in the source app, then start playback."
        case .unknown:
            return "Waiting for signal from \(liveInputSignalName)."
        }
    }

    private var roonPlaybackIsActiveForSignalStatus: Bool {
        if let state = roonBridgeSnapshot.selectedZone?.state.lowercased() {
            return state == "playing" || state == "loading"
        }
        if let state = roonNowPlaying?.state.lowercased() {
            return state == "playing" || state == "loading"
        }
        return false
    }

    private var roonPlaybackIsPausedForSignalStatus: Bool {
        if roonBridgeSnapshot.selectedZone?.state.caseInsensitiveCompare("paused") == .orderedSame {
            return true
        }
        return roonNowPlaying?.state.caseInsensitiveCompare("PAUSED") == .orderedSame
    }

    private var liveLoopbackPlayerActivityText: String {
        switch sourceMode {
        case .roon:
            if roonPlaybackIsActiveForSignalStatus {
                return "Roon playback: playing."
            }
            if roonPlaybackIsPausedForSignalStatus {
                return "Roon playback: paused."
            }
            if roonBridgeSnapshot.isReadyForTransport {
                return "Roon bridge: paired, playback state unknown."
            }
            return "Roon playback: unknown."
        case .spotify:
            if spotifyHasReceivingAudioForStatus {
                return "Spotify playback: receiving audio."
            }
            if let nowPlaying = spotifyNowPlayingForActiveStatus {
                return nowPlaying.isPlaying
                    ? "Spotify playback: playing."
                    : "Spotify playback: paused."
            }
            if spotifyReceiverStatus.isRunning {
                return "Spotify receiver: running, no captured audio yet."
            }
            return "Spotify receiver: \(spotifyReceiverStatus.message)."
        case .aux:
            return "Aux source: no transport metadata; verify the source app is routed to Orbisonic Aux Cable."
        case .atmosDRP:
            switch dolbyReferencePlayerSnapshot.state {
            case .playing:
                return "Atmos DRP playback: playing."
            case .paused:
                return "Atmos DRP playback: paused."
            case .starting:
                return "Atmos DRP playback: starting."
            case .stopping:
                return "Atmos DRP playback: stopping."
            case .failed:
                return dolbyReferencePlayerSnapshot.lastError ?? "Atmos DRP playback: failed."
            case .idle, .stopped:
                return "Atmos DRP playback: stopped."
            }
        case .off, .filePlayback, .testTone:
            return "No external live playback source selected."
        }
    }

    private func repairBlackHoleSampleRateIfNeeded(force: Bool = false) {
        guard sourceMode == .roon,
              inputRoute.isBlackHole,
              let targetSampleRate = roonLoopbackSampleRateMismatch
        else { return }

        let now = Date()
        guard force || now.timeIntervalSince(lastLegacyLoopbackSampleRateRepairTime) >= 8 else {
            return
        }

        lastLegacyLoopbackSampleRateRepairTime = now
        let wasPlaying = isPlaying
        if wasPlaying {
            engine.stop()
            isPlaying = false
        }

        let changed = BlackHoleRouteRepair.prepareInputDeviceForCapture(
            inputRoute,
            preferredSampleRate: targetSampleRate
        )
        refreshRoutesIfNeeded(force: true)

        if changed {
            let message = "Aligned BlackHole to \(formatSampleRate(targetSampleRate)); restarting the Roon pipe."
            statusMessage = message
            lastRecoveryEvent = DiagnosticEvent(message: message, timestamp: Date())
        } else {
            let message = "Checked BlackHole sample-rate mismatch; manual Audio MIDI Setup alignment may be required."
            statusMessage = "Legacy loopback is \(formatSampleRate(inputRoute.nominalSampleRate)) while Roon is \(formatSampleRate(targetSampleRate)). Set the loopback to \(formatSampleRate(targetSampleRate)) in Audio MIDI Setup if capture stays silent."
            lastRecoveryEvent = DiagnosticEvent(message: message, timestamp: Date())
        }

        if wasPlaying {
            startLiveInputForCurrentRoute(reason: "BlackHole sample-rate alignment")
        }
    }

    private func refreshRoonNowPlayingIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastRoonNowPlayingRefreshTime) >= Self.roonLogRefreshInterval else { return }
        guard !isRoonLogRefreshInFlight else { return }
        lastRoonNowPlayingRefreshTime = now

        guard sourceMode == .roon else { return }
        isRoonLogRefreshInFlight = true
        let reader = roonNowPlayingReader

        Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                reader.readLatestSnapshot()
            }.value

            guard let self else { return }
            defer { isRoonLogRefreshInFlight = false }
            guard sourceMode == .roon else { return }

            applyRoonLogSnapshot(snapshot)
        }
    }

    private func applyRoonLogSnapshot(_ snapshot: RoonLogSnapshot?) {
        guard let snapshot else {
            roonNowPlayingStatus = roonBridgeSnapshot.isReadyForTransport
                ? "Roon bridge paired. Signal-path log has not updated yet."
                : "No Roon playback line found in RoonServer log yet."
            logInputSourceStatusIfNeeded(reason: "roon metadata unavailable")
            return
        }

        defer {
            logInputSourceStatusIfNeeded(reason: "roon metadata refreshed")
        }

        if let next = snapshot.nowPlaying {
            if next != roonNowPlaying {
                roonNowPlaying = next
                AppLogger.shared.notice(
                    category: "roon-metadata",
                    "Now playing zone=\(next.zoneName) state=\(next.state) title=\(next.titleLine) format=\(next.qualityFormat) progress=\(next.positionText)/\(next.durationText)"
                )
            }

            roonNowPlayingStatus = next.updatedText
        } else if roonBridgeSnapshot.isReadyForTransport {
            roonNowPlayingStatus = "Roon bridge paired. Waiting for signal-path log details."
        } else {
            roonNowPlayingStatus = "No Roon playback line found in RoonServer log yet."
        }

        guard let signalPath = snapshot.signalPath, signalPath != roonSignalPath else {
            return
        }

        roonSignalPath = signalPath
        let level: AppLogLevel = signalPath.isDownmixingToStereo ? .warning : .notice
        AppLogger.shared.log(
            level,
            category: "roon-metadata",
            "Signal path sourceChannels=\(signalPath.sourceChannelText) sourceFormat=\(signalPath.sourceFormat) channelMapping=\(signalPath.channelMapping) device=\(signalPath.device) output=\(signalPath.output)"
        )

        if signalPath.isDownmixingToStereo {
            statusMessage = "Roon is downmixing quad to stereo before Orbisonic. Change the selected Roon output channel layout to multichannel."
        }
    }

    private func refreshRoonBridgeIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastRoonBridgeRefreshTime) >= Self.roonBridgeRefreshInterval else { return }
        guard !isRoonBridgeRefreshInFlight else { return }
        lastRoonBridgeRefreshTime = now
        isRoonBridgeRefreshInFlight = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRoonBridgeRefreshInFlight = false }

            do {
                let snapshot = try await roonBridgeClient.refreshStartingIfNeeded()
                applyRoonBridgeSnapshot(snapshot)
            } catch {
                applyRoonBridgeError(error)
            }
        }
    }

    private func startPersistentHelperServices(reason: String, force: Bool = false) {
        guard !Self.isRunningUnitTests else { return }
        refreshRoonBridgeIfNeeded(force: force)
        refreshSpotifyConnectServerIfNeeded(reason: reason, force: force)
    }

    private func maintainPersistentHelperServices() {
        startPersistentHelperServices(reason: "periodic service check")
    }

    private func spotifyTrackIdentity(_ state: SpotifyNowPlaying?) -> String? {
        guard let state else { return nil }
        if let uri = state.uri?.trimmedNilIfBlank {
            return uri
        }

        return [
            state.displayTitle,
            state.artistText,
            state.durationMs.map(String.init) ?? "-"
        ].joined(separator: "|")
    }

    private func clearSpotifyVisibleState(reason: String) {
        spotifyPlaybackStatusDebounceTask?.cancel()
        spotifyPlaybackStatusDebounceTask = nil
        if spotifyVisibleNowPlaying != nil {
            spotifyVisibleNowPlaying = nil
            logSpotifyStatusDebug(
                rawState: spotifyNowPlaying,
                debouncedState: spotifyVisibleNowPlaying,
                reasonForUpdate: reason
            )
            logInputSourceStatusIfNeeded(reason: "spotify visible state cleared: \(reason)")
        }
    }

    private func updateSpotifyVisibleState(
        from rawState: SpotifyNowPlaying?,
        reason: String,
        forceImmediate: Bool = false
    ) {
        guard sourceMode == .spotify else {
            clearSpotifyVisibleState(reason: "\(reason):inactive source")
            return
        }

        let currentVisible = spotifyVisibleNowPlaying
        let trackChanged = spotifyTrackIdentity(currentVisible) != spotifyTrackIdentity(rawState)
        let playbackChanged = currentVisible?.isPlaying != rawState?.isPlaying
        let shouldDebounce = currentVisible != nil && !trackChanged && playbackChanged && !forceImmediate

        spotifyPlaybackStatusDebounceTask?.cancel()
        spotifyPlaybackStatusDebounceTask = nil

        guard shouldDebounce else {
            if spotifyVisibleNowPlaying != rawState {
                spotifyVisibleNowPlaying = rawState
            }
            logSpotifyStatusDebug(
                rawState: rawState,
                debouncedState: spotifyVisibleNowPlaying,
                reasonForUpdate: forceImmediate ? "\(reason):immediate" : reason
            )
            logInputSourceStatusIfNeeded(
                reason: "spotify now playing \(forceImmediate ? "\(reason):immediate" : reason)"
            )
            return
        }

        logSpotifyStatusDebug(
            rawState: rawState,
            debouncedState: currentVisible,
            reasonForUpdate: "\(reason):debounce pending"
        )
        spotifyPlaybackStatusDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.spotifyPlaybackStatusDebounceNanoseconds)
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, self.sourceMode == .spotify else { return }
                self.spotifyVisibleNowPlaying = rawState
                self.logSpotifyStatusDebug(
                    rawState: self.spotifyNowPlaying,
                    debouncedState: self.spotifyVisibleNowPlaying,
                    reasonForUpdate: "\(reason):debounced"
                )
                self.logInputSourceStatusIfNeeded(reason: "spotify now playing \(reason):debounced")
            }
        }
    }

    private func updateSpotifyNowPlaying(
        _ next: SpotifyNowPlaying?,
        reason: String,
        forceVisible: Bool = false
    ) {
        spotifyNowPlaying = next
        guard sourceMode == .spotify else {
            clearSpotifyVisibleState(reason: "\(reason):inactive source")
            logSpotifyStatusDebug(
                rawState: next,
                debouncedState: spotifyVisibleNowPlaying,
                reasonForUpdate: "\(reason):inactive source"
            )
            return
        }
        updateSpotifyVisibleState(from: next, reason: reason, forceImmediate: forceVisible)
    }

    private func refreshSpotifyNowPlayingIfNeeded(force: Bool = false, reason: String = "periodic refresh") {
        let now = Date()
        guard force || now.timeIntervalSince(lastSpotifyNowPlayingRefreshTime) >= Self.spotifyNowPlayingRefreshInterval else { return }
        lastSpotifyNowPlayingRefreshTime = now

        let next = spotifyReceiverClient.readNowPlaying()
        if next != spotifyNowPlaying {
            updateSpotifyNowPlaying(next, reason: reason, forceVisible: force && sourceMode == .spotify)
        } else if force {
            updateSpotifyVisibleState(from: next, reason: reason, forceImmediate: sourceMode == .spotify)
        }

        if next == nil, spotifyReceiverStatus.isRunning {
            refreshSpotifyConnectServerIfNeeded(reason: "stale now playing")
        }
    }

    private func refreshSpotifyConnectServerIfNeeded(reason: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSpotifyConnectRefreshTime) >= Self.spotifyConnectRestartDebounce else { return }
        lastSpotifyConnectRefreshTime = now

        spotifyReceiverStatus = spotifyReceiverClient.start()
        AppLogger.shared.notice(
            category: "spotify-receiver",
            "Refreshed Spotify Connect server reason=\(reason) state=\(spotifyReceiverStatus.state.rawValue)"
        )
        logInputSourceStatusIfNeeded(reason: "spotify receiver refreshed: \(reason)")
    }

    func toggleSpotifyTransport() {
        sendSpotifyControl(.playPause)
    }

    func playPreviousSpotifyTrack() {
        sendSpotifyControl(.previous)
    }

    func playNextSpotifyTrack() {
        sendSpotifyControl(.next)
    }

    func seekSpotifyBy(seconds delta: Int) {
        guard let nowPlaying = spotifyNowPlaying,
              let current = nowPlaying.positionMs
        else { return }

        let duration = nowPlaying.durationMs ?? current
        let next = UInt32(min(max(Int(current) + delta * 1_000, 0), Int(duration)))
        sendSpotifyControl(.seek(positionMs: next))
    }

    private func spotifyControlDebugName(_ control: SpotifyReceiverControl) -> String {
        switch control {
        case .playPause:
            return "playPause"
        case .previous:
            return "previous"
        case .next:
            return "next"
        case .seek(let positionMs):
            return "seek:\(positionMs)"
        case .setVolume(let percent):
            return "setVolume:\(percent)"
        }
    }

    private func sendSpotifyControl(_ control: SpotifyReceiverControl) {
        let stateBefore = debugPlaybackStateSnapshot()
        guard sourceMode == .spotify else {
            logTransportDebug(
                command: spotifyControlDebugName(control),
                allowed: false,
                handler: "sendSpotifyControl",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: "source is \(sourceMode.rawValue)"
            )
            return
        }
        if spotifyReceiverClient.send(control) {
            refreshSpotifyNowPlayingIfNeeded(force: true, reason: "spotify control sent")
            statusMessage = "Sent Spotify Connect control."
            logTransportDebug(
                command: spotifyControlDebugName(control),
                allowed: true,
                handler: "sendSpotifyControl",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot()
            )
        } else {
            statusMessage = "Spotify Connect control is not available in this build or the receiver is not active."
            refreshSpotifyConnectServerIfNeeded(reason: "control failed", force: true)
            logTransportDebug(
                command: spotifyControlDebugName(control),
                allowed: true,
                handler: "sendSpotifyControl",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: "spotify receiver control unavailable"
            )
        }
    }

    private func sendRoonTransport(_ control: RoonBridgeControl) {
        let stateBefore = debugPlaybackStateSnapshot()
        guard sourceMode == .roon else {
            logTransportDebug(
                command: control.rawValue,
                allowed: false,
                handler: "sendRoonTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: "source is \(sourceMode.rawValue)"
            )
            return
        }
        guard !isRoonTransportCommandInFlight else {
            logTransportDebug(
                command: control.rawValue,
                allowed: false,
                handler: "sendRoonTransport",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: "roon command already in flight"
            )
            return
        }
        isRoonTransportCommandInFlight = true
        statusMessage = "Sending \(control.rawValue) to Roon..."

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRoonTransportCommandInFlight = false }

            do {
                let response = try await roonBridgeClient.sendStartingIfNeeded(control)
                if let snapshot = response.state {
                    applyRoonBridgeSnapshot(snapshot)
                } else {
                    refreshRoonBridgeIfNeeded(force: true)
                }
                statusMessage = response.message ?? "Sent \(control.rawValue) to Roon."
                AppLogger.shared.notice(category: "roon-bridge", "Sent transport control=\(control.rawValue)")
                logTransportDebug(
                    command: control.rawValue,
                    allowed: true,
                    handler: "sendRoonTransport",
                    stateBefore: stateBefore,
                    stateAfter: debugPlaybackStateSnapshot()
                )
            } catch {
                applyRoonBridgeError(error)
                statusMessage = error.localizedDescription
                lastError = error.localizedDescription
                AppLogger.shared.error(category: "roon-bridge", "Transport control failed control=\(control.rawValue) error=\(error.localizedDescription)")
                logTransportDebug(
                    command: control.rawValue,
                    allowed: true,
                    handler: "sendRoonTransport",
                    stateBefore: stateBefore,
                    stateAfter: debugPlaybackStateSnapshot(),
                    error: error.localizedDescription
                )
            }
        }
    }

    private func applyRoonBridgeSnapshot(_ snapshot: RoonBridgeSnapshot) {
        if snapshot != roonBridgeSnapshot {
            roonBridgeSnapshot = snapshot
            updateRoonArtwork(for: snapshot, reason: "bridge snapshot")
            let logStatus = [
                snapshot.bridge.state,
                snapshot.selectedZoneId ?? "no-zone",
                snapshot.statusText,
                snapshot.selectedZone?.titleText ?? ""
            ].joined(separator: "|")

            if logStatus != lastLoggedRoonBridgeStatus {
                lastLoggedRoonBridgeStatus = logStatus
                AppLogger.shared.notice(
                    category: "roon-bridge",
                    "State=\(snapshot.bridge.state) status=\(snapshot.statusText)"
                )
            }
        } else {
            updateRoonArtwork(for: snapshot, reason: "bridge snapshot unchanged")
        }

        logInputSourceStatusIfNeeded(reason: "roon bridge refreshed")
    }

    private func updateRoonArtwork(for snapshot: RoonBridgeSnapshot, reason: String) {
        guard let request = snapshot.selectedZone?.nowPlaying?.artworkRequest else {
            roonArtworkFetchTask?.cancel()
            roonArtworkFetchTask = nil
            roonArtworkRequestedKey = nil
            let signature = [
                snapshot.selectedZoneId ?? "no-zone",
                snapshot.selectedZone?.titleText ?? "no-title",
                snapshot.selectedZone?.subtitleText ?? "no-subtitle"
            ].joined(separator: "|")
            if signature != lastLoggedRoonArtworkMissingSignature {
                lastLoggedRoonArtworkMissingSignature = signature
                AppLogger.shared.debug(category: "roon-artwork", "No Roon artwork key available reason=\(reason)")
            }
            return
        }

        lastLoggedRoonArtworkMissingSignature = nil

        if let cachedURL = roonArtworkCache.cachedURL(for: request.stableKey) {
            roonArtworkFetchTask?.cancel()
            roonArtworkFetchTask = nil
            roonArtworkRequestedKey = request.stableKey
            roonArtworkRetryAfter[request.stableKey] = nil
            if roonArtworkURL != cachedURL {
                roonArtworkURL = cachedURL
                AppLogger.shared.notice(
                    category: "roon-artwork",
                    "Loaded cached Roon artwork title=\(request.title) key=\(request.stableKey)"
                )
            }
            return
        }

        if let retryAfter = roonArtworkRetryAfter[request.stableKey], retryAfter > Date() {
            return
        }

        if roonArtworkRequestedKey == request.stableKey, roonArtworkFetchTask != nil {
            return
        }

        if roonArtworkFailedKeys.contains(request.stableKey) {
            AppLogger.shared.debug(category: "roon-artwork", "Skipping previously failed Roon artwork key=\(request.stableKey)")
            return
        }

        if snapshot.bridge.supportsImage == false || snapshot.bridge.imageServiceAvailable == false {
            roonArtworkRetryAfter[request.stableKey] = Date().addingTimeInterval(Self.roonArtworkRetryCooldown)
            let signature = [
                request.stableKey,
                snapshot.bridge.version ?? "unknown-version",
                snapshot.bridge.supportsImage.map(String.init) ?? "unknown-support",
                snapshot.bridge.imageServiceAvailable.map(String.init) ?? "unknown-service"
            ].joined(separator: "|")
            if signature != lastLoggedRoonArtworkCapabilitySignature {
                lastLoggedRoonArtworkCapabilitySignature = signature
                AppLogger.shared.warning(
                    category: "roon-artwork",
                    "Roon bridge cannot serve artwork title=\(request.title) key=\(request.stableKey) bridgeVersion=\(snapshot.bridge.version ?? "unknown") supportsImage=\(snapshot.bridge.supportsImage.map(String.init) ?? "unknown") imageServiceAvailable=\(snapshot.bridge.imageServiceAvailable.map(String.init) ?? "unknown")"
                )
            }
            return
        }

        roonArtworkFetchTask?.cancel()
        roonArtworkRequestedKey = request.stableKey
        roonArtworkFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await roonBridgeClient.fetchImageDataStartingIfNeeded(for: request.imageKey)
                guard !Task.isCancelled else { return }
                let cachedURL = try roonArtworkCache.store(data, for: request.stableKey)
                guard roonArtworkRequestedKey == request.stableKey else { return }
                roonArtworkURL = cachedURL
                roonArtworkFetchTask = nil
                roonArtworkFailedKeys.remove(request.stableKey)
                roonArtworkRetryAfter[request.stableKey] = nil
                AppLogger.shared.notice(
                    category: "roon-artwork",
                    "Fetched Roon artwork title=\(request.title) key=\(request.stableKey) bytes=\(data.count)"
                )
            } catch {
                guard !Task.isCancelled else { return }
                if roonArtworkRequestedKey == request.stableKey {
                    roonArtworkFetchTask = nil
                    if roonArtworkFetchFailureShouldRetry(error) {
                        roonArtworkRetryAfter[request.stableKey] = Date().addingTimeInterval(Self.roonArtworkRetryCooldown)
                    } else {
                        roonArtworkFailedKeys.insert(request.stableKey)
                    }
                }
                AppLogger.shared.warning(
                    category: "roon-artwork",
                    "Roon artwork fetch failed title=\(request.title) key=\(request.stableKey) retryable=\(roonArtworkFetchFailureShouldRetry(error)) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func roonArtworkFetchFailureShouldRetry(_ error: Error) -> Bool {
        if let bridgeError = error as? RoonBridgeClientError {
            return bridgeError.isRetryableArtworkFetchFailure
        }
        return error is URLError
    }

    private func applyRoonBridgeError(_ error: Error) {
        let bridgeState: String
        if case RoonBridgeClientError.missingDependencies = error {
            bridgeState = "missing_dependencies"
        } else if case RoonBridgeClientError.missingNodeRuntime = error {
            bridgeState = "missing_node"
        } else {
            bridgeState = "offline"
        }

        let snapshot = RoonBridgeSnapshot(
            ok: false,
            updatedAt: nil,
            bridge: RoonBridgeInfo(
                state: bridgeState,
                message: error.localizedDescription,
                zoneHint: "Orbisonic Roon Input"
            ),
            core: nil,
            selectedZoneId: nil,
            selectedZone: nil,
            zones: []
        )

        if snapshot != roonBridgeSnapshot {
            roonBridgeSnapshot = snapshot
            AppLogger.shared.warning(category: "roon-bridge", error.localizedDescription)
        }
        logInputSourceStatusIfNeeded(reason: "roon bridge error", force: true)
    }

    private func applyPreset(_ preset: SpatialPreset, pushToEngine: Bool = true) {
        let defaults = preset.defaults
        suppressTuningPublish = true
        frontAngle = defaults.frontAngle
        rearAngle = defaults.rearAngle
        suppressTuningPublish = false

        if pushToEngine {
            publishTuning()
        }
    }

    private static func timestamp(_ value: TimeInterval) -> String {
        let totalSeconds = max(Int(value.rounded(.down)), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

}

private extension SpatialPreset {
    static let defaultPreset: SpatialPreset = .immersiveWrap
}
