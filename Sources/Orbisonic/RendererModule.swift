import Foundation

struct RendererVector3: Codable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = RendererVector3(x: 0, y: 0, z: 0)

    var length: Double {
        sqrt(x * x + y * y + z * z)
    }

    var normalized: RendererVector3 {
        let magnitude = length
        guard magnitude > 0 else { return .zero }
        return RendererVector3(x: x / magnitude, y: y / magnitude, z: z / magnitude)
    }

    func distance(to other: RendererVector3) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    static func cartesian(azimuth: Double, elevation: Double, radius: Double) -> RendererVector3 {
        let azimuthRadians = azimuth * .pi / 180
        let elevationRadians = elevation * .pi / 180
        let x = -sin(azimuthRadians) * cos(elevationRadians) * radius
        let y = sin(elevationRadians) * radius
        let z = -cos(azimuthRadians) * cos(elevationRadians) * radius
        return RendererVector3(x: x, y: y, z: z)
    }
}

enum RendererOutputTopologyKind: String, Codable, CaseIterable, Identifiable {
    case sonicSphere

    var id: String { rawValue }
}

struct RendererOutputTopology: Codable, Hashable {
    var kind: RendererOutputTopologyKind
    var fullRangeCount: Int
    var lfeCount: Int

    var outputCount: Int {
        fullRangeCount + lfeCount
    }

    static let fey30Point1 = RendererOutputTopology(
        kind: .sonicSphere,
        fullRangeCount: FeyStaticBedRenderer.fullRangeOutputs,
        lfeCount: 1
    )
}

enum RendererRenderMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case mono
    case stereo
    case binaural = "binaural_180"
    case quad
    case surround51
    case auro80 = "auro_8_0"
    case auro91 = "auro_9_1"
    case auro101 = "auro_10_1"
    case auro111714h = "auro_11_1_7_1_4h"
    case auro111515hT = "auro_11_1_5_1_5h_t"
    case auro121 = "auro_12_1"
    case auro131 = "auro_13_1"
    case direct30
    case direct31
    case directPassthrough = "direct_passthrough"

    static let allCases: [RendererRenderMode] = [
        .automatic,
        .mono,
        .stereo,
        .binaural,
        .quad,
        .surround51,
        .auro80,
        .auro91,
        .auro101,
        .auro111714h,
        .auro111515hT,
        .auro121,
        .auro131
    ]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            "Auto"
        case .mono:
            "Mono"
        case .stereo:
            "Stereo 90"
        case .binaural:
            "Binaural 180"
        case .quad:
            "Quad"
        case .surround51:
            "5.1"
        case .auro80:
            "Auro 8.0"
        case .auro91:
            "Auro 9.1"
        case .auro101:
            "Auro 10.1"
        case .auro111714h:
            "Auro 11.1 7+4H"
        case .auro111515hT:
            "Auro 11.1 5+5H+T"
        case .auro121:
            "Auro 12.1"
        case .auro131:
            "Auro 13.1"
        case .direct30:
            "Direct 30"
        case .direct31:
            "Direct 30.1"
        case .directPassthrough:
            "Direct Passthrough"
        }
    }

    var statusName: String {
        switch self {
        case .surround51:
            "5.1 Static Bed"
        case .auro80:
            "Auro 8.0 Static Bed"
        case .auro91:
            "Auro 9.1 Static Bed"
        case .auro101:
            "Auro 10.1 Static Bed"
        case .auro111714h:
            "Auro 11.1 7.1+4H Static Bed"
        case .auro111515hT:
            "Auro 11.1 5.1+5H+T Static Bed"
        case .auro121:
            "Auro 12.1 Static Bed"
        case .auro131:
            "Auro 13.1 Static Bed"
        case .direct30, .direct31:
            "\(displayName) Bypass"
        case .directPassthrough:
            "Direct Passthrough"
        case .automatic:
            displayName
        default:
            "\(displayName) Static Bed"
        }
    }

    var expectedInputCount: Int? {
        switch self {
        case .automatic:
            nil
        case .mono:
            1
        case .stereo, .binaural:
            2
        case .quad:
            4
        case .surround51:
            6
        case .auro80:
            8
        case .auro91:
            10
        case .auro101:
            11
        case .auro111714h, .auro111515hT:
            12
        case .auro121:
            13
        case .auro131:
            14
        case .direct30:
            30
        case .direct31:
            31
        case .directPassthrough:
            nil
        }
    }

    var isRenderedBed: Bool {
        switch self {
        case .mono, .stereo, .binaural, .quad, .surround51,
             .auro80, .auro91, .auro101, .auro111714h, .auro111515hT, .auro121, .auro131:
            true
        case .automatic, .direct30, .direct31, .directPassthrough:
            false
        }
    }

    var isAuroBed: Bool {
        switch self {
        case .auro80, .auro91, .auro101, .auro111714h, .auro111515hT, .auro121, .auro131:
            true
        default:
            false
        }
    }

    var isBypass: Bool {
        self == .direct30 || self == .direct31 || self == .directPassthrough
    }

    static let supportedInputCounts = [1, 2, 4, 6, 8, 10, 11, 12, 13, 14, 30, 31]

    static func automaticMode(forInputCount inputCount: Int) -> RendererRenderMode? {
        switch inputCount {
        case 1:
            .mono
        case 2:
            .stereo
        case 4:
            .quad
        case 6:
            .surround51
        case 8:
            .auro80
        case 10:
            .auro91
        case 11:
            .auro101
        case 12:
            .auro111714h
        case 13:
            .auro121
        case 14:
            .auro131
        case 30:
            .direct30
        case 31:
            .direct31
        default:
            OrbisonicAudioLimits.supportsSourceChannelCount(inputCount) ? .directPassthrough : nil
        }
    }

    func resolved(forInputCount inputCount: Int) -> RendererRenderMode? {
        if self == .automatic {
            return Self.automaticMode(forInputCount: inputCount)
        }

        if self == .mono {
            return OrbisonicAudioLimits.supportsSourceChannelCount(inputCount) ? self : nil
        }

        return expectedInputCount == inputCount ? self : nil
    }
}

enum RendererTwoChannelPreference: String, Codable, CaseIterable, Identifiable {
    case stereo
    case binaural = "binaural_180"

    static let allCases: [RendererTwoChannelPreference] = [.stereo, .binaural]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stereo:
            "Stereo 90"
        case .binaural:
            "Binaural 180"
        }
    }

    var renderMode: RendererRenderMode {
        switch self {
        case .stereo:
            .stereo
        case .binaural:
            .binaural
        }
    }
}

enum RendererModePolicy {
    static func effectiveRequestedMode(
        requestedMode: RendererRenderMode,
        inputChannelCount: Int?,
        alwaysMono: Bool,
        twoChannelPreference: RendererTwoChannelPreference
    ) -> RendererRenderMode {
        if alwaysMono,
           let inputChannelCount,
           OrbisonicAudioLimits.supportsSourceChannelCount(inputChannelCount) {
            return .mono
        }

        if requestedMode == .automatic,
           inputChannelCount == 2 {
            return twoChannelPreference.renderMode
        }

        return requestedMode
    }
}

enum FeyFiveOneChannelOrder: String, Codable, CaseIterable, Identifiable {
    case film = "L R C LFE Ls Rs"
    case proTools = "L C R Ls Rs LFE"
    case surroundsBeforeCenter = "L R Ls Rs C LFE"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var left: Int {
        switch self {
        case .film, .proTools, .surroundsBeforeCenter:
            0
        }
    }

    var right: Int {
        switch self {
        case .film, .surroundsBeforeCenter:
            1
        case .proTools:
            2
        }
    }

    var center: Int {
        switch self {
        case .film:
            2
        case .proTools:
            1
        case .surroundsBeforeCenter:
            4
        }
    }

    var lfe: Int {
        switch self {
        case .film:
            3
        case .proTools, .surroundsBeforeCenter:
            5
        }
    }

    var leftSurround: Int {
        switch self {
        case .film:
            4
        case .proTools:
            3
        case .surroundsBeforeCenter:
            2
        }
    }

    var rightSurround: Int {
        switch self {
        case .film:
            5
        case .proTools:
            4
        case .surroundsBeforeCenter:
            3
        }
    }
}

struct FeyInputLayout: Hashable, Identifiable {
    let mode: RendererRenderMode
    let channelLabels: [String]
    let lfeChannelIndexes: Set<Int>

    var id: String { mode.rawValue }
    var inputChannelCount: Int { channelLabels.count }

    var summary: String {
        channelLabels.enumerated().map { "\($0.offset) \($0.element)" }.joined(separator: " • ")
    }
}

struct FeyWeightedVectorOptions: Hashable {
    var upperBiasDbPerUnitZ: Double
    var maxSingleSpeakerPowerShare: Double
}

struct FeyRendererOptions: Codable, Hashable {
    var coreGain: Double
    var seamSupportGain: Double
    var upperBiasDbPerUnitZ: Double
    var stereoRearFill: Double
    var centerSideSupportGain: Double
    var adjacentBleed: Double
    var maxSingleSpeakerPowerShare: Double
    var renderedOutputTrimDb: Double
    var directOutputTrimDb: Double
    var fiveOneChannelOrder: FeyFiveOneChannelOrder
    var renderedMainTrimDb: Double
    var lfeTrimDb: Double
    var defaultMaxSingleSpeakerPowerShare: Double
    var heightMaxSingleSpeakerPowerShare: Double
    var topMaxSingleSpeakerPowerShare: Double
    var defaultUpperBiasDbPerUnitZ: Double
    var heightUpperBiasDbPerUnitZ: Double

    static let `default` = FeyRendererOptions(
        coreGain: 1.0,
        seamSupportGain: 0.55,
        upperBiasDbPerUnitZ: 2.0,
        stereoRearFill: 0.12,
        centerSideSupportGain: 0.35,
        adjacentBleed: 0.03,
        maxSingleSpeakerPowerShare: 0.22,
        renderedOutputTrimDb: -3.0,
        directOutputTrimDb: 0.0,
        fiveOneChannelOrder: .film,
        renderedMainTrimDb: -3.0,
        lfeTrimDb: 0.0,
        defaultMaxSingleSpeakerPowerShare: 0.22,
        heightMaxSingleSpeakerPowerShare: 0.24,
        topMaxSingleSpeakerPowerShare: 0.22,
        defaultUpperBiasDbPerUnitZ: 1.0,
        heightUpperBiasDbPerUnitZ: 1.5
    )

    init(
        coreGain: Double,
        seamSupportGain: Double,
        upperBiasDbPerUnitZ: Double,
        stereoRearFill: Double,
        centerSideSupportGain: Double,
        adjacentBleed: Double,
        maxSingleSpeakerPowerShare: Double,
        renderedOutputTrimDb: Double,
        directOutputTrimDb: Double,
        fiveOneChannelOrder: FeyFiveOneChannelOrder,
        renderedMainTrimDb: Double? = nil,
        lfeTrimDb: Double = 0.0,
        defaultMaxSingleSpeakerPowerShare: Double? = nil,
        heightMaxSingleSpeakerPowerShare: Double = 0.24,
        topMaxSingleSpeakerPowerShare: Double? = nil,
        defaultUpperBiasDbPerUnitZ: Double = 1.0,
        heightUpperBiasDbPerUnitZ: Double = 1.5
    ) {
        self.coreGain = coreGain
        self.seamSupportGain = seamSupportGain
        self.upperBiasDbPerUnitZ = upperBiasDbPerUnitZ
        self.stereoRearFill = stereoRearFill
        self.centerSideSupportGain = centerSideSupportGain
        self.adjacentBleed = adjacentBleed
        self.maxSingleSpeakerPowerShare = maxSingleSpeakerPowerShare
        self.renderedOutputTrimDb = renderedOutputTrimDb
        self.directOutputTrimDb = directOutputTrimDb
        self.fiveOneChannelOrder = fiveOneChannelOrder
        self.renderedMainTrimDb = renderedMainTrimDb ?? renderedOutputTrimDb
        self.lfeTrimDb = lfeTrimDb
        self.defaultMaxSingleSpeakerPowerShare = defaultMaxSingleSpeakerPowerShare ?? maxSingleSpeakerPowerShare
        self.heightMaxSingleSpeakerPowerShare = heightMaxSingleSpeakerPowerShare
        self.topMaxSingleSpeakerPowerShare = topMaxSingleSpeakerPowerShare ?? maxSingleSpeakerPowerShare
        self.defaultUpperBiasDbPerUnitZ = defaultUpperBiasDbPerUnitZ
        self.heightUpperBiasDbPerUnitZ = heightUpperBiasDbPerUnitZ
    }

    private enum CodingKeys: String, CodingKey {
        case coreGain
        case seamSupportGain
        case upperBiasDbPerUnitZ
        case stereoRearFill
        case centerSideSupportGain
        case adjacentBleed
        case maxSingleSpeakerPowerShare
        case renderedOutputTrimDb
        case directOutputTrimDb
        case fiveOneChannelOrder
        case renderedMainTrimDb
        case lfeTrimDb
        case defaultMaxSingleSpeakerPowerShare
        case heightMaxSingleSpeakerPowerShare
        case topMaxSingleSpeakerPowerShare
        case defaultUpperBiasDbPerUnitZ
        case heightUpperBiasDbPerUnitZ
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        coreGain = try container.decodeIfPresent(Double.self, forKey: .coreGain) ?? defaults.coreGain
        seamSupportGain = try container.decodeIfPresent(Double.self, forKey: .seamSupportGain) ?? defaults.seamSupportGain
        upperBiasDbPerUnitZ = try container.decodeIfPresent(Double.self, forKey: .upperBiasDbPerUnitZ) ?? defaults.upperBiasDbPerUnitZ
        stereoRearFill = try container.decodeIfPresent(Double.self, forKey: .stereoRearFill) ?? defaults.stereoRearFill
        centerSideSupportGain = try container.decodeIfPresent(Double.self, forKey: .centerSideSupportGain) ?? defaults.centerSideSupportGain
        adjacentBleed = try container.decodeIfPresent(Double.self, forKey: .adjacentBleed) ?? defaults.adjacentBleed
        maxSingleSpeakerPowerShare = try container.decodeIfPresent(Double.self, forKey: .maxSingleSpeakerPowerShare) ?? defaults.maxSingleSpeakerPowerShare
        renderedOutputTrimDb = try container.decodeIfPresent(Double.self, forKey: .renderedOutputTrimDb) ?? defaults.renderedOutputTrimDb
        directOutputTrimDb = try container.decodeIfPresent(Double.self, forKey: .directOutputTrimDb) ?? defaults.directOutputTrimDb
        fiveOneChannelOrder = try container.decodeIfPresent(FeyFiveOneChannelOrder.self, forKey: .fiveOneChannelOrder) ?? defaults.fiveOneChannelOrder
        renderedMainTrimDb = try container.decodeIfPresent(Double.self, forKey: .renderedMainTrimDb) ?? renderedOutputTrimDb
        lfeTrimDb = try container.decodeIfPresent(Double.self, forKey: .lfeTrimDb) ?? defaults.lfeTrimDb
        defaultMaxSingleSpeakerPowerShare = try container.decodeIfPresent(Double.self, forKey: .defaultMaxSingleSpeakerPowerShare) ?? maxSingleSpeakerPowerShare
        heightMaxSingleSpeakerPowerShare = try container.decodeIfPresent(Double.self, forKey: .heightMaxSingleSpeakerPowerShare) ?? defaults.heightMaxSingleSpeakerPowerShare
        topMaxSingleSpeakerPowerShare = try container.decodeIfPresent(Double.self, forKey: .topMaxSingleSpeakerPowerShare) ?? maxSingleSpeakerPowerShare
        defaultUpperBiasDbPerUnitZ = try container.decodeIfPresent(Double.self, forKey: .defaultUpperBiasDbPerUnitZ) ?? defaults.defaultUpperBiasDbPerUnitZ
        heightUpperBiasDbPerUnitZ = try container.decodeIfPresent(Double.self, forKey: .heightUpperBiasDbPerUnitZ) ?? defaults.heightUpperBiasDbPerUnitZ
    }

    var clamped: FeyRendererOptions {
        FeyRendererOptions(
            coreGain: max(coreGain, 0),
            seamSupportGain: seamSupportGain.clamped(to: 0...1),
            upperBiasDbPerUnitZ: upperBiasDbPerUnitZ.clamped(to: -3...4),
            stereoRearFill: stereoRearFill.clamped(to: 0...0.35),
            centerSideSupportGain: centerSideSupportGain.clamped(to: 0...0.7),
            adjacentBleed: adjacentBleed.clamped(to: 0...0.12),
            maxSingleSpeakerPowerShare: maxSingleSpeakerPowerShare.clamped(to: 0.08...0.35),
            renderedOutputTrimDb: renderedOutputTrimDb.clamped(to: -12...0),
            directOutputTrimDb: directOutputTrimDb,
            fiveOneChannelOrder: fiveOneChannelOrder,
            renderedMainTrimDb: renderedMainTrimDb.clamped(to: -12...0),
            lfeTrimDb: lfeTrimDb.clamped(to: -12...6),
            defaultMaxSingleSpeakerPowerShare: defaultMaxSingleSpeakerPowerShare.clamped(to: 0.08...0.35),
            heightMaxSingleSpeakerPowerShare: heightMaxSingleSpeakerPowerShare.clamped(to: 0.08...0.35),
            topMaxSingleSpeakerPowerShare: topMaxSingleSpeakerPowerShare.clamped(to: 0.08...0.35),
            defaultUpperBiasDbPerUnitZ: defaultUpperBiasDbPerUnitZ.clamped(to: -3...4),
            heightUpperBiasDbPerUnitZ: heightUpperBiasDbPerUnitZ.clamped(to: -3...4)
        )
    }
}

struct RendererPreset: Codable, Identifiable, Hashable {
    var schemaVersion: Int
    var id: String
    var name: String
    var description: String
    var outputTopology: RendererOutputTopology
    var options: FeyRendererOptions

    static let currentSchemaVersion = 3

    static let sonicSphere30Point1 = RendererPreset(
        schemaVersion: currentSchemaVersion,
        id: "fey-static-bed-30-1-default",
        name: "Sonic Sphere 30.1 Spatial",
        description: "Sonic Sphere 30.1 renderer for mono, stereo, quad, 5.1, and Auro-style decoded PCM beds. 30/31-channel sources bypass rendering.",
        outputTopology: .fey30Point1,
        options: .default
    )

    var normalizedForCurrentSchema: RendererPreset {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.outputTopology = .fey30Point1
        copy.options = options.clamped
        return copy
    }

    func replacingOptions(_ nextOptions: FeyRendererOptions) -> RendererPreset {
        var copy = self
        copy.options = nextOptions.clamped
        copy.schemaVersion = Self.currentSchemaVersion
        copy.outputTopology = .fey30Point1
        return copy
    }
}

struct RendererOutputSpeaker: Identifiable, Hashable {
    let index: Int
    let speakerId: Int?
    let isLFE: Bool
    let position: RendererVector3

    var id: String {
        if let speakerId {
            return "speaker-\(speakerId)"
        }
        return "lfe-\(index)"
    }

    var displayName: String {
        if let speakerId {
            return "Speaker \(speakerId)"
        }
        return "Sub / LFE"
    }

    var shortLabel: String {
        if let speakerId {
            return "\(speakerId)"
        }
        return "LFE"
    }
}

struct RendererInputSpeaker: Identifiable, Hashable {
    let channel: SurroundChannel
    let position: RendererVector3

    var id: String { channel.id }
    var displayName: String { channel.displayName }
    var shortLabel: String { channel.shortLabel }
}

struct RendererSceneModel: Hashable {
    var preset: RendererPreset
    var requestedRenderMode: RendererRenderMode
    var renderMode: RendererRenderMode
    var inputSpeakers: [RendererInputSpeaker]
    var outputSpeakers: [RendererOutputSpeaker]
    var matrix: RendererMatrix
    var validationMessages: [String]

    var isSupported: Bool {
        matrix.inputCount > 0 || inputSpeakers.isEmpty
    }

    var isBypass: Bool {
        matrix.isBypass
    }

    static let empty = RendererSceneModel(
        preset: .sonicSphere30Point1,
        requestedRenderMode: .automatic,
        renderMode: .automatic,
        inputSpeakers: [],
        outputSpeakers: SonicSphereTopology.outputSpeakers(for: .sonicSphere30Point1),
        matrix: .empty,
        validationMessages: []
    )
}

struct RendererMatrix: Hashable {
    var gains: [[Double]]
    var untrimmedGains: [[Double]]
    var outputMajorGains: [[Double]]
    var untrimmedOutputMajorGains: [[Double]]
    var lfeInputIndexes: Set<Int>
    var isBypass: Bool

    static let empty = RendererMatrix(gains: [], untrimmedGains: [], isBypass: false)

    init(
        gains: [[Double]],
        untrimmedGains: [[Double]]? = nil,
        outputMajorGains: [[Double]]? = nil,
        untrimmedOutputMajorGains: [[Double]]? = nil,
        lfeInputIndexes: Set<Int> = [],
        isBypass: Bool = false
    ) {
        self.gains = gains
        self.untrimmedGains = untrimmedGains ?? gains
        self.outputMajorGains = outputMajorGains ?? Self.transpose(gains)
        self.untrimmedOutputMajorGains = untrimmedOutputMajorGains ?? Self.transpose(untrimmedGains ?? gains)
        self.lfeInputIndexes = lfeInputIndexes
        self.isBypass = isBypass
    }

    var inputCount: Int {
        gains.count
    }

    var outputCount: Int {
        gains.first?.count ?? 0
    }

    func strongestOutputs(forInputAt inputIndex: Int, limit: Int = 3) -> [(index: Int, gain: Double)] {
        guard gains.indices.contains(inputIndex) else { return [] }
        return gains[inputIndex]
            .enumerated()
            .filter { $0.element > 0.0001 }
            .sorted { $0.element > $1.element }
            .prefix(limit)
            .map { (index: $0.offset, gain: $0.element) }
    }

    static func fromOutputMajor(
        gains outputMajorGains: [[Double]],
        untrimmedOutputMajorGains: [[Double]]? = nil,
        lfeInputIndexes: Set<Int> = [],
        isBypass: Bool = false
    ) -> RendererMatrix {
        let inputMajor = transpose(outputMajorGains)
        let untrimmedOutputMajor = untrimmedOutputMajorGains ?? outputMajorGains
        return RendererMatrix(
            gains: inputMajor,
            untrimmedGains: transpose(untrimmedOutputMajor),
            outputMajorGains: outputMajorGains,
            untrimmedOutputMajorGains: untrimmedOutputMajor,
            lfeInputIndexes: lfeInputIndexes,
            isBypass: isBypass
        )
    }

    private static func transpose(_ rows: [[Double]]) -> [[Double]] {
        guard let columnCount = rows.first?.count, columnCount > 0 else { return [] }
        var columns = Array(
            repeating: Array(repeating: 0.0, count: rows.count),
            count: columnCount
        )

        for rowIndex in 0..<rows.count {
            for columnIndex in 0..<min(columnCount, rows[rowIndex].count) {
                columns[columnIndex][rowIndex] = rows[rowIndex][columnIndex]
            }
        }

        return columns
    }
}

enum SonicSphereAudioRenderer {
    static func render(inputChannels: [[Float]], matrix: RendererMatrix) -> [[Float]] {
        guard matrix.inputCount > 0,
              matrix.outputCount > 0,
              inputChannels.count == matrix.inputCount,
              let frameCount = inputChannels.first?.count,
              inputChannels.allSatisfy({ $0.count == frameCount })
        else {
            return []
        }

        var outputs = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: matrix.outputCount
        )

        for inputIndex in 0..<matrix.inputCount {
            let input = inputChannels[inputIndex]
            for outputIndex in 0..<matrix.outputCount {
                let gain = Float(matrix.gains[inputIndex][outputIndex])
                guard abs(gain) > 0.000_001 else { continue }

                for frame in 0..<frameCount {
                    outputs[outputIndex][frame] += input[frame] * gain
                }
            }
        }

        return outputs
    }
}

enum RendererMeterLevelModel {
    static func outputLevels(sourceLevels: [Float], matrix: RendererMatrix) -> [Float] {
        guard matrix.inputCount > 0,
              matrix.outputCount > 0,
              sourceLevels.count == matrix.inputCount
        else {
            return Array(repeating: 0, count: matrix.outputCount)
        }

        var nextLevels = Array(repeating: Float(0), count: matrix.outputCount)

        for inputIndex in 0..<matrix.inputCount {
            let inputLevel = sourceLevels[inputIndex]
            guard inputLevel > 0 else { continue }

            for outputIndex in 0..<matrix.outputCount {
                let gain = Float(abs(matrix.gains[inputIndex][outputIndex]))
                let weightedLevel = inputLevel * gain
                nextLevels[outputIndex] += weightedLevel * weightedLevel
            }
        }

        return nextLevels.map { min(sqrtf($0), 1) }
    }

    static func monoPreviewSourceLevel(from sourceLevels: [Float]) -> Float {
        let activeLevels = sourceLevels.filter { $0 > 0 }
        guard !activeLevels.isEmpty else { return 0 }

        let meanSquare = activeLevels.reduce(Float(0)) { $0 + ($1 * $1) } / Float(activeLevels.count)
        return min(sqrtf(meanSquare), 1)
    }

    static func monoPreviewOutputLevels(sourceLevels: [Float], matrix: RendererMatrix) -> [Float] {
        let monoLevel = monoPreviewSourceLevel(from: sourceLevels)
        let matrixInputLevels = Array(repeating: monoLevel, count: max(matrix.inputCount, 1))
        return outputLevels(sourceLevels: matrixInputLevels, matrix: matrix)
    }
}

struct FeySpeaker: Codable, Hashable {
    let speakerId: Int
    let x: Double
    let y: Double
    let z: Double

    var position: RendererVector3 {
        RendererVector3(x: x, y: y, z: z)
    }

    var outputIndex: Int {
        speakerId - 1
    }
}

struct FeyLobes: Hashable {
    var fl: [Double]
    var fr: [Double]
    var binauralLeft: [Double]
    var binauralRight: [Double]
    var rl: [Double]
    var rr: [Double]
    var frontCenter: [Double]
    var mono: [Double]
    var lLower: [Double]
    var rLower: [Double]
    var cLower: [Double]
    var lsLower51: [Double]
    var rsLower51: [Double]
    var rearCenterLower: [Double]
    var lsLower71: [Double]
    var rsLower71: [Double]
    var lbLower: [Double]
    var rbLower: [Double]
    var hl: [Double]
    var hr: [Double]
    var hc: [Double]
    var hls: [Double]
    var hrs: [Double]
    var top: [Double]
}

enum SonicSphereTopology {
    static func outputSpeakers(for preset: RendererPreset, includeLFE: Bool = true) -> [RendererOutputSpeaker] {
        let renderer = FeyStaticBedRenderer(options: preset.options)
        var speakers = renderer.getLayout().map { speaker in
            RendererOutputSpeaker(
                index: speaker.outputIndex,
                speakerId: speaker.speakerId,
                isLFE: false,
                position: speaker.position
            )
        }

        if includeLFE {
            speakers.append(RendererOutputSpeaker(
                index: FeyStaticBedRenderer.subOutputIndex,
                speakerId: nil,
                isLFE: true,
                position: RendererVector3(x: 0, y: -1.12, z: 0)
            ))
        }

        return speakers
    }
}

enum RendererInputLayoutGeometry {
    static func inputSpeakers(for layout: SurroundLayout, mode: RendererRenderMode?) -> [RendererInputSpeaker] {
        if let mode,
           mode.isAuroBed,
           let inputLayout = FeyStaticBedRenderer.inputLayout(for: mode),
           inputLayout.inputChannelCount == layout.channelCount {
            return inputLayout.channelLabels.enumerated().map { index, label in
                let channel = SurroundChannel(index: index, role: auroRole(for: label, index: index))
                return RendererInputSpeaker(
                    channel: channel,
                    position: position(for: channel, in: layout, mode: mode)
                )
            }
        }

        return layout.channels.map { channel in
            RendererInputSpeaker(
                channel: channel,
                position: position(for: channel, in: layout, mode: mode)
            )
        }
    }

    private static func auroRole(for label: String, index: Int) -> SurroundChannelRole {
        switch label {
        case "L": .frontLeft
        case "R": .frontRight
        case "C": .center
        case "LFE": .lfe
        case "Ls": .sideLeft
        case "Rs": .sideRight
        case "Lb": .rearLeft
        case "Rb": .rearRight
        case "HL": .topFrontLeft
        case "HC": .topFrontCenter
        case "HR": .topFrontRight
        case "HLs": .topRearLeft
        case "HRs": .topRearRight
        case "T": .topMiddleCenter
        default: .discrete(index)
        }
    }

    private static func position(
        for channel: SurroundChannel,
        in layout: SurroundLayout,
        mode: RendererRenderMode?
    ) -> RendererVector3 {
        if mode?.isBypass == true {
            let speaker = FeyStaticBedRenderer.getSpeakerById(channel.index + 1)
            return speaker?.position ?? discretePosition(index: channel.index, count: layout.channelCount)
        }

        switch channel.role {
        case .frontLeft:
            return RendererVector3(x: -0.72, y: 0.72, z: 0.18)
        case .frontRight:
            return RendererVector3(x: 0.72, y: 0.72, z: 0.18)
        case .center:
            return RendererVector3(x: 0, y: 0.9, z: 0.2)
        case .lfe, .lfe2:
            return RendererVector3(x: 0, y: -1.12, z: -0.2)
        case .sideLeft, .rearLeft:
            return RendererVector3(x: -0.72, y: -0.72, z: 0.18)
        case .sideRight, .rearRight:
            return RendererVector3(x: 0.72, y: -0.72, z: 0.18)
        case .rearCenter:
            return RendererVector3(x: 0, y: -0.9, z: 0.18)
        default:
            return discretePosition(index: channel.index, count: layout.channelCount)
        }
    }

    private static func discretePosition(index: Int, count: Int) -> RendererVector3 {
        let safeCount = max(count, 1)
        let angle = (Double(index) / Double(safeCount)) * 2.0 * Double.pi
        return RendererVector3(x: cos(angle) * 0.82, y: sin(angle) * 0.82, z: 0.15)
    }
}

enum RendererMatrixBuilder {
    static func sceneModel(
        for layout: SurroundLayout?,
        preset: RendererPreset,
        renderMode requestedMode: RendererRenderMode = .automatic
    ) -> RendererSceneModel {
        let preset = preset.normalizedForCurrentSchema
        guard let layout else {
            let outputs = SonicSphereTopology.outputSpeakers(for: preset)
            return RendererSceneModel(
                preset: preset,
                requestedRenderMode: requestedMode,
                renderMode: .automatic,
                inputSpeakers: [],
                outputSpeakers: outputs,
                matrix: .empty,
                validationMessages: []
            )
        }

        let requestedResolvedMode = requestedMode.resolved(forInputCount: layout.channelCount)
        let resolvedMode = requestedResolvedMode ?? RendererRenderMode.automaticMode(forInputCount: layout.channelCount)
        let outputs = SonicSphereTopology.outputSpeakers(for: preset)
        let inputs = RendererInputLayoutGeometry.inputSpeakers(for: layout, mode: resolvedMode)
        let renderer = FeyStaticBedRenderer(options: preset.options)
        var validationMessages = renderer.validationMessages()

        if requestedResolvedMode == nil, requestedMode != .automatic, let resolvedMode {
            validationMessages.append("\(requestedMode.displayName) unavailable for \(layout.name). Using \(resolvedMode.displayName).")
        }

        guard let resolvedMode else {
            validationMessages.append("Unsupported source channel count \(layout.channelCount) for \(requestedMode.displayName).")
            return RendererSceneModel(
                preset: preset,
                requestedRenderMode: requestedMode,
                renderMode: requestedMode,
                inputSpeakers: inputs,
                outputSpeakers: outputs,
                matrix: .empty,
                validationMessages: validationMessages
            )
        }

        let matrix = resolvedMode == .mono
            ? renderer.buildMonoDownmixMatrix(inputCount: layout.channelCount)
            : renderer.buildMatrix(mode: resolvedMode, sourceLayout: layout)
        validationMessages.append(contentsOf: renderer.validationMessages(for: matrix, mode: resolvedMode))
        return RendererSceneModel(
            preset: preset,
            requestedRenderMode: requestedMode,
            renderMode: resolvedMode,
            inputSpeakers: inputs,
            outputSpeakers: outputs,
            matrix: matrix,
            validationMessages: validationMessages
        )
    }
}

/// Static channel-bed renderer for already-decoded PCM beds into the FEY 30.1 sphere.
/// This does not decode Auro-Codec-in-FLAC, render object metadata, steer adaptively, or add DSP effects.
/// Auro channel orders below are layout-specific, not generic DAW/SMPTE orders: 7.1-based Auro uses
/// Lb/Rb before Ls/Rs, and layouts with T place Top before the height channels.
final class FeyStaticBedRenderer {
    static let fullRangeOutputs = 30
    static let totalOutputs = 31
    static let subOutputIndex = 30

    static let feySpeakers: [FeySpeaker] = [
        FeySpeaker(speakerId: 1, x: 0.00, y: 0.60, z: -0.90),
        FeySpeaker(speakerId: 2, x: 0.60, y: 0.20, z: -0.90),
        FeySpeaker(speakerId: 3, x: 0.36, y: -0.49, z: -0.90),
        FeySpeaker(speakerId: 4, x: -0.36, y: -0.49, z: -0.90),
        FeySpeaker(speakerId: 5, x: -0.60, y: 0.20, z: -0.90),
        FeySpeaker(speakerId: 6, x: -0.60, y: 0.69, z: -0.60),
        FeySpeaker(speakerId: 7, x: 0.60, y: 0.69, z: -0.60),
        FeySpeaker(speakerId: 8, x: 0.80, y: -0.26, z: -0.60),
        FeySpeaker(speakerId: 9, x: 0.00, y: -0.80, z: -0.60),
        FeySpeaker(speakerId: 10, x: -0.80, y: -0.26, z: -0.60),
        FeySpeaker(speakerId: 11, x: -1.00, y: 0.33, z: -0.25),
        FeySpeaker(speakerId: 12, x: 0.00, y: 1.00, z: -0.25),
        FeySpeaker(speakerId: 13, x: 1.00, y: 0.33, z: -0.25),
        FeySpeaker(speakerId: 14, x: 0.73, y: -1.00, z: -0.25),
        FeySpeaker(speakerId: 15, x: -0.73, y: -1.00, z: -0.25),
        FeySpeaker(speakerId: 16, x: -1.00, y: -0.33, z: 0.25),
        FeySpeaker(speakerId: 17, x: -0.72, y: 1.00, z: 0.25),
        FeySpeaker(speakerId: 18, x: 0.72, y: 1.00, z: 0.25),
        FeySpeaker(speakerId: 19, x: 1.00, y: -0.33, z: 0.25),
        FeySpeaker(speakerId: 20, x: 0.00, y: -1.00, z: 0.25),
        FeySpeaker(speakerId: 21, x: -0.50, y: -0.69, z: 0.60),
        FeySpeaker(speakerId: 22, x: -0.80, y: 0.25, z: 0.60),
        FeySpeaker(speakerId: 23, x: 0.00, y: 0.80, z: 0.60),
        FeySpeaker(speakerId: 24, x: 0.80, y: 0.26, z: 0.60),
        FeySpeaker(speakerId: 25, x: 0.50, y: -0.69, z: 0.60),
        FeySpeaker(speakerId: 26, x: 0.00, y: -0.60, z: 0.90),
        FeySpeaker(speakerId: 27, x: -0.60, y: -0.20, z: 0.90),
        FeySpeaker(speakerId: 28, x: -0.50, y: 0.69, z: 0.90),
        FeySpeaker(speakerId: 29, x: 0.50, y: 0.69, z: 0.90),
        FeySpeaker(speakerId: 30, x: 0.60, y: -0.20, z: 0.90)
    ]

    private static let flCore = [5, 6, 11, 17, 22, 28]
    private static let frCore = [2, 7, 13, 18, 24, 29]
    private static let rlCore = [4, 10, 15, 16, 21, 27]
    private static let rrCore = [3, 8, 14, 19, 25, 30]
    private static let frontSupport = [1, 12, 23]
    private static let rearSupport = [9, 20, 26]
    private static let topUpperBiasDbPerUnitZ = 0.0

    private static let lLowerWeights = [
        5: 1.00, 6: 1.00, 11: 1.00, 17: 0.75, 22: 0.35, 28: 0.15,
        1: 0.45, 12: 0.35, 23: 0.15
    ]
    private static let rLowerWeights = [
        2: 1.00, 7: 1.00, 13: 1.00, 18: 0.75, 24: 0.35, 29: 0.15,
        1: 0.45, 12: 0.35, 23: 0.15
    ]
    private static let cLowerWeights = [
        1: 1.00, 12: 1.00, 23: 0.35,
        5: 0.25, 6: 0.25, 11: 0.25, 17: 0.20,
        2: 0.25, 7: 0.25, 13: 0.25, 18: 0.20
    ]
    private static let lsLower51Weights = [
        4: 0.60, 10: 1.00, 15: 0.75, 16: 1.00, 21: 0.45, 27: 0.15,
        9: 0.35, 20: 0.35, 26: 0.12
    ]
    private static let rsLower51Weights = [
        3: 0.60, 8: 1.00, 14: 0.75, 19: 1.00, 25: 0.45, 30: 0.15,
        9: 0.35, 20: 0.35, 26: 0.12
    ]
    private static let rearCenterLowerWeights = [
        9: 1.00, 20: 0.80, 26: 0.25,
        15: 0.30, 14: 0.30, 21: 0.20, 25: 0.20
    ]
    private static let hlWeights = [
        17: 0.60, 22: 1.00, 28: 0.85,
        11: 0.25, 12: 0.15, 23: 0.35
    ]
    private static let hrWeights = [
        18: 0.60, 24: 1.00, 29: 0.85,
        13: 0.25, 12: 0.15, 23: 0.35
    ]
    private static let hcWeights = [
        23: 1.00,
        17: 0.35, 18: 0.35,
        28: 0.25, 29: 0.25,
        12: 0.25
    ]
    private static let hlsWeights = [
        16: 0.45, 21: 1.00, 27: 0.85,
        15: 0.15, 20: 0.25, 26: 0.35
    ]
    private static let hrsWeights = [
        19: 0.45, 25: 1.00, 30: 0.85,
        14: 0.15, 20: 0.25, 26: 0.35
    ]
    private static let topWeights = [
        26: 1.00, 27: 1.00, 28: 1.00, 29: 1.00, 30: 1.00,
        21: 0.35, 22: 0.35, 23: 0.35, 24: 0.35, 25: 0.35
    ]

    private let options: FeyRendererOptions
    private let lobes: FeyLobes
    private var matrixCache: [RendererRenderMode: RendererMatrix] = [:]

    private var zeroFullRangeColumn: [Double] {
        Array(repeating: 0.0, count: Self.fullRangeOutputs)
    }

    init(options: FeyRendererOptions = .default) {
        self.options = options.clamped
        let baseFL = Self.buildLobe(coreSpeakerIds: Self.flCore, supportSpeakerIds: Self.frontSupport, options: self.options)
        let baseFR = Self.buildLobe(coreSpeakerIds: Self.frCore, supportSpeakerIds: Self.frontSupport, options: self.options)
        let baseRL = Self.buildLobe(coreSpeakerIds: Self.rlCore, supportSpeakerIds: Self.rearSupport, options: self.options)
        let baseRR = Self.buildLobe(coreSpeakerIds: Self.rrCore, supportSpeakerIds: Self.rearSupport, options: self.options)
        let bled = Self.applyAdjacentQuadBleed(
            fl: baseFL,
            fr: baseFR,
            rl: baseRL,
            rr: baseRR,
            adjacentBleed: self.options.adjacentBleed
        )
        let lowerVectorOptions = FeyWeightedVectorOptions(
            upperBiasDbPerUnitZ: self.options.defaultUpperBiasDbPerUnitZ,
            maxSingleSpeakerPowerShare: self.options.defaultMaxSingleSpeakerPowerShare
        )
        let heightVectorOptions = FeyWeightedVectorOptions(
            upperBiasDbPerUnitZ: self.options.heightUpperBiasDbPerUnitZ,
            maxSingleSpeakerPowerShare: self.options.heightMaxSingleSpeakerPowerShare
        )
        let topVectorOptions = FeyWeightedVectorOptions(
            upperBiasDbPerUnitZ: Self.topUpperBiasDbPerUnitZ,
            maxSingleSpeakerPowerShare: self.options.topMaxSingleSpeakerPowerShare
        )
        let lLower = Self.buildWeightedVector(weightMap: Self.lLowerWeights, options: lowerVectorOptions)
        let rLower = Self.buildWeightedVector(weightMap: Self.rLowerWeights, options: lowerVectorOptions)
        let lsLower51 = Self.buildWeightedVector(weightMap: Self.lsLower51Weights, options: lowerVectorOptions)
        let rsLower51 = Self.buildWeightedVector(weightMap: Self.rsLower51Weights, options: lowerVectorOptions)
        let rearCenterLower = Self.buildWeightedVector(weightMap: Self.rearCenterLowerWeights, options: lowerVectorOptions)

        self.lobes = FeyLobes(
            fl: bled.fl,
            fr: bled.fr,
            binauralLeft: Self.buildHemisphereVector(west: true, options: lowerVectorOptions),
            binauralRight: Self.buildHemisphereVector(west: false, options: lowerVectorOptions),
            rl: bled.rl,
            rr: bled.rr,
            frontCenter: Self.buildFrontCenterVector(options: self.options),
            mono: Self.buildMonoVector(options: self.options),
            lLower: lLower,
            rLower: rLower,
            cLower: Self.buildWeightedVector(weightMap: Self.cLowerWeights, options: lowerVectorOptions),
            lsLower51: lsLower51,
            rsLower51: rsLower51,
            rearCenterLower: rearCenterLower,
            lsLower71: Self.mixVectors(
                [(0.25, lLower), (0.75, lsLower51)],
                maxSingleSpeakerPowerShare: self.options.defaultMaxSingleSpeakerPowerShare
            ),
            rsLower71: Self.mixVectors(
                [(0.25, rLower), (0.75, rsLower51)],
                maxSingleSpeakerPowerShare: self.options.defaultMaxSingleSpeakerPowerShare
            ),
            lbLower: Self.mixVectors(
                [(0.90, lsLower51), (0.10, rearCenterLower)],
                maxSingleSpeakerPowerShare: self.options.defaultMaxSingleSpeakerPowerShare
            ),
            rbLower: Self.mixVectors(
                [(0.90, rsLower51), (0.10, rearCenterLower)],
                maxSingleSpeakerPowerShare: self.options.defaultMaxSingleSpeakerPowerShare
            ),
            hl: Self.buildWeightedVector(weightMap: Self.hlWeights, options: heightVectorOptions),
            hr: Self.buildWeightedVector(weightMap: Self.hrWeights, options: heightVectorOptions),
            hc: Self.buildWeightedVector(weightMap: Self.hcWeights, options: heightVectorOptions),
            hls: Self.buildWeightedVector(weightMap: Self.hlsWeights, options: heightVectorOptions),
            hrs: Self.buildWeightedVector(weightMap: Self.hrsWeights, options: heightVectorOptions),
            top: Self.buildWeightedVector(weightMap: Self.topWeights, options: topVectorOptions)
        )
    }

    func render(inputFrame: [Float], mode: RendererRenderMode) -> [Float] {
        render(inputFrame: inputFrame, layoutId: mode)
    }

    func render(inputFrame: [Float], layoutId: RendererRenderMode) -> [Float] {
        let matrix = buildMatrix(layoutId: layoutId)
        guard inputFrame.count == matrix.inputCount else {
            return Array(repeating: 0, count: Self.totalOutputs)
        }

        var output = Array(repeating: Float(0), count: matrix.outputCount)
        for inputIndex in 0..<matrix.inputCount {
            let sample = inputFrame[inputIndex]
            guard sample != 0 else { continue }
            for outputIndex in 0..<matrix.outputCount {
                let gain = Float(matrix.gains[inputIndex][outputIndex])
                guard gain != 0 else { continue }
                output[outputIndex] += sample * gain
            }
        }
        return output
    }

    func buildMatrix(mode: RendererRenderMode) -> RendererMatrix {
        buildMatrix(layoutId: mode)
    }

    func buildMatrix(mode: RendererRenderMode, sourceLayout: SurroundLayout) -> RendererMatrix {
        if mode == .surround51,
           let matrix = buildSurround51Matrix(channels: sourceLayout.channels) {
            return matrix
        }

        if mode == .directPassthrough {
            return Self.bypassMatrix(inputCount: sourceLayout.channelCount)
        }

        return buildMatrix(mode: mode)
    }

    func buildMonoDownmixMatrix(inputCount: Int) -> RendererMatrix {
        guard OrbisonicAudioLimits.supportsSourceChannelCount(inputCount) else {
            return .empty
        }

        return monoDownmixMatrix(inputCount: inputCount)
    }

    func buildMatrix(layoutId: RendererRenderMode) -> RendererMatrix {
        if let cached = matrixCache[layoutId] {
            return cached
        }

        let matrix = makeMatrix(layoutId: layoutId)
        matrixCache[layoutId] = matrix
        return matrix
    }

    private func makeMatrix(layoutId: RendererRenderMode) -> RendererMatrix {
        switch layoutId {
        case .mono:
            return renderedMatrix(fullRangeColumns: [lobes.mono], lfeInputIndexes: [])
        case .stereo:
            let left = Self.mixVectors([
                (1 - options.stereoRearFill, lobes.fl),
                (options.stereoRearFill, lobes.rl)
            ])
            let right = Self.mixVectors([
                (1 - options.stereoRearFill, lobes.fr),
                (options.stereoRearFill, lobes.rr)
            ])
            return renderedMatrix(fullRangeColumns: [left, right], lfeInputIndexes: [])
        case .binaural:
            return renderedMatrix(fullRangeColumns: [lobes.binauralLeft, lobes.binauralRight], lfeInputIndexes: [])
        case .quad:
            return renderedMatrix(fullRangeColumns: [lobes.fl, lobes.fr, lobes.rl, lobes.rr], lfeInputIndexes: [])
        case .surround51:
            let order = options.fiveOneChannelOrder
            var columns = Array(
                repeating: Array(repeating: 0.0, count: Self.fullRangeOutputs),
                count: 6
            )
            columns[order.left] = lobes.fl
            columns[order.right] = lobes.fr
            columns[order.center] = lobes.frontCenter
            columns[order.leftSurround] = lobes.rl
            columns[order.rightSurround] = lobes.rr

            return renderedMatrix(fullRangeColumns: columns, lfeInputIndexes: [order.lfe])
        case .auro80:
            return renderedMatrix(fullRangeColumns: [
                lobes.lLower, lobes.rLower, lobes.lsLower51, lobes.rsLower51,
                lobes.hl, lobes.hr, lobes.hls, lobes.hrs
            ], lfeInputIndexes: [])
        case .auro91:
            return renderedMatrix(fullRangeColumns: [
                lobes.lLower, lobes.rLower, lobes.cLower, zeroFullRangeColumn,
                lobes.lsLower51, lobes.rsLower51, lobes.hl, lobes.hr, lobes.hls, lobes.hrs
            ], lfeInputIndexes: [3])
        case .auro101:
            return renderedMatrix(fullRangeColumns: [
                lobes.lLower, lobes.rLower, lobes.cLower, zeroFullRangeColumn,
                lobes.lsLower51, lobes.rsLower51, lobes.top, lobes.hl, lobes.hr, lobes.hls, lobes.hrs
            ], lfeInputIndexes: [3])
        case .auro111714h:
            return renderedMatrix(fullRangeColumns: [
                lobes.lLower, lobes.rLower, lobes.cLower, zeroFullRangeColumn,
                lobes.lbLower, lobes.rbLower, lobes.lsLower71, lobes.rsLower71,
                lobes.hl, lobes.hr, lobes.hls, lobes.hrs
            ], lfeInputIndexes: [3])
        case .auro111515hT:
            return renderedMatrix(fullRangeColumns: [
                lobes.lLower, lobes.rLower, lobes.cLower, zeroFullRangeColumn,
                lobes.lsLower51, lobes.rsLower51, lobes.top, lobes.hl, lobes.hc, lobes.hr, lobes.hls, lobes.hrs
            ], lfeInputIndexes: [3])
        case .auro121:
            return renderedMatrix(fullRangeColumns: [
                lobes.lLower, lobes.rLower, lobes.cLower, zeroFullRangeColumn,
                lobes.lbLower, lobes.rbLower, lobes.lsLower71, lobes.rsLower71,
                lobes.hl, lobes.hc, lobes.hr, lobes.hls, lobes.hrs
            ], lfeInputIndexes: [3])
        case .auro131:
            return renderedMatrix(fullRangeColumns: [
                lobes.lLower, lobes.rLower, lobes.cLower, zeroFullRangeColumn,
                lobes.lbLower, lobes.rbLower, lobes.lsLower71, lobes.rsLower71,
                lobes.top, lobes.hl, lobes.hc, lobes.hr, lobes.hls, lobes.hrs
            ], lfeInputIndexes: [3])
        case .direct30:
            return Self.bypassMatrix(inputCount: 30)
        case .direct31:
            return Self.bypassMatrix(inputCount: 31)
        case .directPassthrough:
            return .empty
        case .automatic:
            return .empty
        }
    }

    private func buildSurround51Matrix(channels: [SurroundChannel]) -> RendererMatrix? {
        guard channels.count == 6 else { return nil }

        var columns = Array(
            repeating: Array(repeating: 0.0, count: Self.fullRangeOutputs),
            count: channels.count
        )
        var lfeInputIndexes: Set<Int> = []
        var mappedFullRangeInputs = 0

        for channel in channels {
            guard channels.indices.contains(channel.index) else { return nil }
            switch channel.role {
            case .frontLeft:
                columns[channel.index] = lobes.fl
                mappedFullRangeInputs += 1
            case .frontRight:
                columns[channel.index] = lobes.fr
                mappedFullRangeInputs += 1
            case .center:
                columns[channel.index] = lobes.frontCenter
                mappedFullRangeInputs += 1
            case .sideLeft, .rearLeft:
                columns[channel.index] = lobes.rl
                mappedFullRangeInputs += 1
            case .sideRight, .rearRight:
                columns[channel.index] = lobes.rr
                mappedFullRangeInputs += 1
            case .lfe, .lfe2:
                lfeInputIndexes.insert(channel.index)
            default:
                return nil
            }
        }

        guard mappedFullRangeInputs == 5, lfeInputIndexes.count == 1 else { return nil }
        return renderedMatrix(fullRangeColumns: columns, lfeInputIndexes: lfeInputIndexes)
    }

    func getSupportedLayouts() -> [RendererRenderMode] {
        RendererRenderMode.allCases.filter { $0 != .automatic }
    }

    func getInputLayout(layoutId: RendererRenderMode) -> FeyInputLayout? {
        Self.inputLayout(for: layoutId, fiveOneChannelOrder: options.fiveOneChannelOrder)
    }

    func getLayout() -> [FeySpeaker] {
        Self.feySpeakers
    }

    func getLobes() -> FeyLobes {
        lobes
    }

    func getSpeakerById(_ speakerId: Int) -> FeySpeaker? {
        Self.getSpeakerById(speakerId)
    }

    func validateLayout(_ layoutId: RendererRenderMode) -> [String] {
        var messages = validationMessages()
        let matrix = buildMatrix(layoutId: layoutId)
        messages.append(contentsOf: validationMessages(for: matrix, mode: layoutId))
        return messages
    }

    static func dbToLinear(_ db: Double) -> Double {
        pow(10, db / 20)
    }

    static func getSpeakerById(_ speakerId: Int) -> FeySpeaker? {
        feySpeakers.first { $0.speakerId == speakerId }
    }

    static func speakerOutputIndex(_ speakerId: Int) -> Int {
        speakerId - 1
    }

    static func inputLayout(
        for mode: RendererRenderMode,
        fiveOneChannelOrder: FeyFiveOneChannelOrder = .film
    ) -> FeyInputLayout? {
        switch mode {
        case .automatic:
            return nil
        case .mono:
            return FeyInputLayout(mode: mode, channelLabels: ["M"], lfeChannelIndexes: [])
        case .stereo:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R"], lfeChannelIndexes: [])
        case .binaural:
            return FeyInputLayout(mode: mode, channelLabels: ["L180", "R180"], lfeChannelIndexes: [])
        case .quad:
            return FeyInputLayout(mode: mode, channelLabels: ["FL", "FR", "RL", "RR"], lfeChannelIndexes: [])
        case .surround51:
            var labels = Array(repeating: "", count: 6)
            labels[fiveOneChannelOrder.left] = "L"
            labels[fiveOneChannelOrder.right] = "R"
            labels[fiveOneChannelOrder.center] = "C"
            labels[fiveOneChannelOrder.lfe] = "LFE"
            labels[fiveOneChannelOrder.leftSurround] = "Ls"
            labels[fiveOneChannelOrder.rightSurround] = "Rs"
            return FeyInputLayout(mode: mode, channelLabels: labels, lfeChannelIndexes: [fiveOneChannelOrder.lfe])
        case .auro80:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R", "Ls", "Rs", "HL", "HR", "HLs", "HRs"], lfeChannelIndexes: [])
        case .auro91:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R", "C", "LFE", "Ls", "Rs", "HL", "HR", "HLs", "HRs"], lfeChannelIndexes: [3])
        case .auro101:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R", "C", "LFE", "Ls", "Rs", "T", "HL", "HR", "HLs", "HRs"], lfeChannelIndexes: [3])
        case .auro111714h:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R", "C", "LFE", "Lb", "Rb", "Ls", "Rs", "HL", "HR", "HLs", "HRs"], lfeChannelIndexes: [3])
        case .auro111515hT:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R", "C", "LFE", "Ls", "Rs", "T", "HL", "HC", "HR", "HLs", "HRs"], lfeChannelIndexes: [3])
        case .auro121:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R", "C", "LFE", "Lb", "Rb", "Ls", "Rs", "HL", "HC", "HR", "HLs", "HRs"], lfeChannelIndexes: [3])
        case .auro131:
            return FeyInputLayout(mode: mode, channelLabels: ["L", "R", "C", "LFE", "Lb", "Rb", "Ls", "Rs", "T", "HL", "HC", "HR", "HLs", "HRs"], lfeChannelIndexes: [3])
        case .direct30:
            return FeyInputLayout(mode: mode, channelLabels: (1...30).map { "Speaker \($0)" }, lfeChannelIndexes: [])
        case .direct31:
            return FeyInputLayout(mode: mode, channelLabels: (1...30).map { "Speaker \($0)" } + ["LFE"], lfeChannelIndexes: [30])
        case .directPassthrough:
            return nil
        }
    }

    static func heightBiasGain(_ speaker: FeySpeaker, upperBiasDbPerUnitZ: Double) -> Double {
        dbToLinear(upperBiasDbPerUnitZ * speaker.z)
    }

    static func normalizePower(_ vector: [Double]) -> [Double] {
        let power = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard power > 0 else { return vector }
        return vector.map { $0 / power }
    }

    static func capAndNormalizePower(_ vector: [Double], maxSingleSpeakerPowerShare: Double) -> [Double] {
        let cap = sqrt(maxSingleSpeakerPowerShare)
        var result = normalizePower(vector)

        for _ in 0..<4 {
            var clipped = false
            result = result.map { gain in
                if gain > cap {
                    clipped = true
                    return cap
                }
                return gain
            }

            result = normalizePower(result)
            if !clipped { break }
        }

        return normalizePower(result)
    }

    static func buildLobe(
        coreSpeakerIds: [Int],
        supportSpeakerIds: [Int],
        options: FeyRendererOptions = .default
    ) -> [Double] {
        let options = options.clamped
        var vector = Array(repeating: 0.0, count: fullRangeOutputs)

        for speakerId in coreSpeakerIds {
            guard let speaker = getSpeakerById(speakerId) else { continue }
            vector[speakerOutputIndex(speakerId)] += options.coreGain * heightBiasGain(
                speaker,
                upperBiasDbPerUnitZ: options.upperBiasDbPerUnitZ
            )
        }

        for speakerId in supportSpeakerIds {
            guard let speaker = getSpeakerById(speakerId) else { continue }
            vector[speakerOutputIndex(speakerId)] += options.seamSupportGain * heightBiasGain(
                speaker,
                upperBiasDbPerUnitZ: options.upperBiasDbPerUnitZ
            )
        }

        return capAndNormalizePower(vector, maxSingleSpeakerPowerShare: options.maxSingleSpeakerPowerShare)
    }

    static func buildWeightedVector(weightMap: [Int: Double], options: FeyWeightedVectorOptions) -> [Double] {
        var vector = Array(repeating: 0.0, count: fullRangeOutputs)

        for (speakerId, baseGain) in weightMap {
            guard baseGain >= 0, let speaker = getSpeakerById(speakerId) else { continue }
            vector[speakerOutputIndex(speakerId)] += baseGain * heightBiasGain(
                speaker,
                upperBiasDbPerUnitZ: options.upperBiasDbPerUnitZ
            )
        }

        return capAndNormalizePower(vector, maxSingleSpeakerPowerShare: options.maxSingleSpeakerPowerShare)
    }

    static func mixVectors(
        _ weightedVectors: [(weight: Double, vector: [Double])],
        maxSingleSpeakerPowerShare: Double? = nil
    ) -> [Double] {
        var result = Array(repeating: 0.0, count: fullRangeOutputs)
        for weightedVector in weightedVectors {
            for index in 0..<min(result.count, weightedVector.vector.count) {
                result[index] += weightedVector.weight * weightedVector.vector[index]
            }
        }

        if let maxSingleSpeakerPowerShare {
            return capAndNormalizePower(result, maxSingleSpeakerPowerShare: maxSingleSpeakerPowerShare)
        }

        return normalizePower(result)
    }

    static func applyAdjacentQuadBleed(
        fl: [Double],
        fr: [Double],
        rl: [Double],
        rr: [Double],
        adjacentBleed: Double
    ) -> (fl: [Double], fr: [Double], rl: [Double], rr: [Double]) {
        let b = adjacentBleed.clamped(to: 0...1)
        return (
            fl: mixVectors([(1 - b, fl), (b / 2, fr), (b / 2, rl)]),
            fr: mixVectors([(1 - b, fr), (b / 2, fl), (b / 2, rr)]),
            rl: mixVectors([(1 - b, rl), (b / 2, fl), (b / 2, rr)]),
            rr: mixVectors([(1 - b, rr), (b / 2, fr), (b / 2, rl)])
        )
    }

    func validationMessages() -> [String] {
        var messages: [String] = []
        let speakerIDs = Self.feySpeakers.map(\.speakerId)
        if Set(speakerIDs).count != speakerIDs.count {
            messages.append("FEY speaker IDs are not unique.")
        }

        let outputIndexes = Self.feySpeakers.map(\.outputIndex)
        if Set(outputIndexes).count != outputIndexes.count {
            messages.append("FEY speaker output indexes are not unique.")
        }

        let lobeIDs = Self.flCore + Self.frCore + Self.rlCore + Self.rrCore + Self.frontSupport + Self.rearSupport
            + Array(Self.lLowerWeights.keys)
            + Array(Self.rLowerWeights.keys)
            + Array(Self.cLowerWeights.keys)
            + Array(Self.lsLower51Weights.keys)
            + Array(Self.rsLower51Weights.keys)
            + Array(Self.rearCenterLowerWeights.keys)
            + Array(Self.hlWeights.keys)
            + Array(Self.hrWeights.keys)
            + Array(Self.hcWeights.keys)
            + Array(Self.hlsWeights.keys)
            + Array(Self.hrsWeights.keys)
            + Array(Self.topWeights.keys)
        let missing = lobeIDs.filter { Self.getSpeakerById($0) == nil }
        if !missing.isEmpty {
            messages.append("FEY lobe speaker IDs are missing: \(missing.map(String.init).joined(separator: ", ")).")
        }

        if Self.feySpeakers.count != Self.fullRangeOutputs {
            messages.append("FEY layout expected \(Self.fullRangeOutputs) full-range speakers.")
        }

        return messages
    }

    func validationMessages(for matrix: RendererMatrix, mode: RendererRenderMode) -> [String] {
        var messages: [String] = []

        let expectedOutputCount = Self.totalOutputs
        if matrix.outputCount != expectedOutputCount {
            messages.append("Renderer output must have exactly \(expectedOutputCount) channels.")
        }

        if mode == .mono {
            if !OrbisonicAudioLimits.supportsSourceChannelCount(matrix.inputCount) {
                messages.append("Mono requires 1 to \(OrbisonicAudioLimits.maxSourceChannelCount) input channels.")
            }
        } else if let expectedInputCount = mode.expectedInputCount, matrix.inputCount != expectedInputCount {
            messages.append("\(mode.displayName) requires \(expectedInputCount) input channels.")
        }

        let flattenedGains = matrix.gains.flatMap { $0 }
        if flattenedGains.contains(where: { !$0.isFinite }) {
            messages.append("Renderer matrix generated a non-finite gain.")
        }

        let hasNegativeGain = flattenedGains.contains { $0 < -0.000_001 }
        if hasNegativeGain {
            messages.append("Renderer matrix generated a negative gain.")
        }

        if mode == .direct30 {
            for inputIndex in 0..<min(matrix.inputCount, Self.fullRangeOutputs) {
                for outputIndex in 0..<min(matrix.outputCount, Self.fullRangeOutputs) {
                    let expected = inputIndex == outputIndex ? 1.0 : 0.0
                    if abs(matrix.gains[inputIndex][outputIndex] - expected) > 0.000_1 {
                        messages.append("Direct 30 must be an identity map for full-range outputs.")
                        break
                    }
                }
            }
        }

        for lfeInputIndex in matrix.lfeInputIndexes where matrix.gains.indices.contains(lfeInputIndex) {
            let row = matrix.gains[lfeInputIndex]
            let fullRangePower = row.prefix(Self.fullRangeOutputs).reduce(0) { $0 + abs($1) }
            if fullRangePower > 0.000_1 || row.indices.contains(Self.subOutputIndex) == false || row[Self.subOutputIndex] <= 0 {
                messages.append("LFE input \(lfeInputIndex) must route only to output \(Self.subOutputIndex).")
            }
        }

        if mode.isRenderedBed && !(mode == .mono && matrix.inputCount > 1) {
            for inputIndex in 0..<matrix.untrimmedGains.count {
                let row = matrix.untrimmedGains[inputIndex]
                let fullRangePower = sqrt(row.prefix(Self.fullRangeOutputs).reduce(0) { $0 + $1 * $1 })
                let isLFERow = matrix.lfeInputIndexes.contains(inputIndex)
                if !isLFERow, abs(fullRangePower - 1.0) > 0.000_1 {
                    messages.append("Renderer matrix column \(inputIndex) is not power-normalized.")
                }
            }
        }

        return messages
    }

    private static func buildMonoVector(options _: FeyRendererOptions) -> [Double] {
        let gain = 1.0 / sqrt(Double(fullRangeOutputs))
        return Array(repeating: gain, count: fullRangeOutputs)
    }

    private static func buildHemisphereVector(west: Bool, options: FeyWeightedVectorOptions) -> [Double] {
        var weightMap: [Int: Double] = [:]
        for speaker in feySpeakers {
            if west, speaker.x < -0.001 {
                weightMap[speaker.speakerId] = 1.0
            } else if !west, speaker.x > 0.001 {
                weightMap[speaker.speakerId] = 1.0
            } else if abs(speaker.x) <= 0.001 {
                weightMap[speaker.speakerId] = 0.32
            }
        }

        return buildWeightedVector(weightMap: weightMap, options: options)
    }

    private static func buildFrontCenterVector(options: FeyRendererOptions) -> [Double] {
        let options = options.clamped
        var vector = Array(repeating: 0.0, count: fullRangeOutputs)
        for speakerId in frontSupport {
            guard let speaker = getSpeakerById(speakerId) else { continue }
            vector[speakerOutputIndex(speakerId)] += options.coreGain * heightBiasGain(
                speaker,
                upperBiasDbPerUnitZ: options.upperBiasDbPerUnitZ
            )
        }

        for speakerId in flCore + frCore {
            guard let speaker = getSpeakerById(speakerId) else { continue }
            vector[speakerOutputIndex(speakerId)] += options.centerSideSupportGain * heightBiasGain(
                speaker,
                upperBiasDbPerUnitZ: options.upperBiasDbPerUnitZ
            )
        }

        return capAndNormalizePower(vector, maxSingleSpeakerPowerShare: options.maxSingleSpeakerPowerShare)
    }

    private func monoDownmixMatrix(inputCount: Int) -> RendererMatrix {
        let mainTrim = Self.dbToLinear(options.renderedMainTrimDb)
        let inputGain = 1.0 / Double(inputCount)
        var outputMajor = Array(
            repeating: Array(repeating: 0.0, count: inputCount),
            count: Self.totalOutputs
        )
        var untrimmedOutputMajor = outputMajor

        for outputIndex in 0..<Self.fullRangeOutputs {
            let outputGain = lobes.mono[outputIndex] * inputGain
            for inputIndex in 0..<inputCount {
                untrimmedOutputMajor[outputIndex][inputIndex] = outputGain
                outputMajor[outputIndex][inputIndex] = outputGain * mainTrim
            }
        }

        return RendererMatrix.fromOutputMajor(
            gains: outputMajor,
            untrimmedOutputMajorGains: untrimmedOutputMajor,
            lfeInputIndexes: [],
            isBypass: false
        )
    }

    private func renderedMatrix(fullRangeColumns: [[Double]], lfeInputIndexes: Set<Int>) -> RendererMatrix {
        let mainTrim = Self.dbToLinear(options.renderedMainTrimDb)
        let lfeTrim = Self.dbToLinear(options.lfeTrimDb)
        let inputCount = fullRangeColumns.count
        var outputMajor = Array(
            repeating: Array(repeating: 0.0, count: inputCount),
            count: Self.totalOutputs
        )
        var untrimmedOutputMajor = outputMajor

        for inputIndex in 0..<inputCount {
            if lfeInputIndexes.contains(inputIndex) {
                outputMajor[Self.subOutputIndex][inputIndex] = lfeTrim
                untrimmedOutputMajor[Self.subOutputIndex][inputIndex] = lfeTrim
                continue
            }

            let column = fullRangeColumns[inputIndex]
            for outputIndex in 0..<min(column.count, Self.fullRangeOutputs) {
                untrimmedOutputMajor[outputIndex][inputIndex] = column[outputIndex]
                outputMajor[outputIndex][inputIndex] = column[outputIndex] * mainTrim
            }
        }

        // Future bass management can low-pass a mono sum into output 30 and high-pass the 30 main outputs,
        // but that is outside this static matrix renderer.
        return RendererMatrix.fromOutputMajor(
            gains: outputMajor,
            untrimmedOutputMajorGains: untrimmedOutputMajor,
            lfeInputIndexes: lfeInputIndexes,
            isBypass: false
        )
    }

    private static func bypassMatrix(inputCount: Int) -> RendererMatrix {
        guard inputCount >= 1 else {
            return .empty
        }

        // Map the first min(inputCount, 31) source channels 1:1 to the 31 outputs.
        // Sources wider than the sphere drop their extra channels; when there are at
        // least 31, the 31st source channel feeds the LFE/sub output (index 30).
        var outputMajor = Array(
            repeating: Array(repeating: 0.0, count: inputCount),
            count: Self.totalOutputs
        )
        for index in 0..<min(inputCount, Self.totalOutputs) {
            outputMajor[index][index] = 1.0
        }

        let lfeInputIndexes: Set<Int> = inputCount >= Self.totalOutputs ? [Self.subOutputIndex] : []
        return RendererMatrix.fromOutputMajor(
            gains: outputMajor,
            lfeInputIndexes: lfeInputIndexes,
            isBypass: true
        )
    }
}

struct RendererPresetStore {
    let fileManager: FileManager
    let directoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directoryURL = support
                .appendingPathComponent("Orbisonic", isDirectory: true)
                .appendingPathComponent("Renderer Presets", isDirectory: true)
        }
    }

    func loadPresets() throws -> [RendererPreset] {
        try ensureDirectoryAndDefaultPreset()

        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("json") == .orderedSame }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        let presets = files.compactMap { url -> RendererPreset? in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode(RendererPreset.self, from: data),
                  decoded.schemaVersion >= 2,
                  decoded.schemaVersion <= RendererPreset.currentSchemaVersion
            else {
                return nil
            }

            return decoded.normalizedForCurrentSchema
        }

        if presets.isEmpty {
            return [.sonicSphere30Point1]
        }

        return presets.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    func save(_ preset: RendererPreset) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let preset = preset.normalizedForCurrentSchema
        let url = directoryURL.appendingPathComponent(Self.fileName(for: preset), isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        try data.write(to: url, options: .atomic)
        return url
    }

    func ensureDirectoryAndDefaultPreset() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let defaultURL = directoryURL.appendingPathComponent(Self.fileName(for: .sonicSphere30Point1))
        if !fileManager.fileExists(atPath: defaultURL.path) {
            try save(.sonicSphere30Point1)
        }
    }

    static func fileName(for preset: RendererPreset) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = preset.id.map { character in
            character.unicodeScalars.allSatisfy { allowed.contains($0) } ? character : "-"
        }
        let stem = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(stem.isEmpty ? "renderer-preset" : stem).json"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
