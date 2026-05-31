import AppKit
import SceneKit
import SwiftUI

enum StageTab: String, CaseIterable, Identifiable {
    case input = "Input"
    case renderer = "Renderer"
    case output = "Output"
    case analyzerVU = "VU"
    case localMusic = "Local Music"
    case diagnostics = "Diagnostics"
    case settings = "Settings"

    var id: String { rawValue }
}

private enum LocalMusicPanel: String, CaseIterable, Identifiable {
    case music = "Music"
    case playlists = "Playlists"
    case queue = "Session Queue"

    var id: String { rawValue }
}

private enum PlayerTransportKind: String, CaseIterable, Identifiable {
    case back
    case play
    case pause
    case stop
    case forward

    static let allCases: [PlayerTransportKind] = [.back, .play, .pause, .forward]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: "Back"
        case .play: "Play"
        case .pause: "Pause"
        case .stop: "Stop"
        case .forward: "Forward"
        }
    }

    var systemImage: String {
        switch self {
        case .back: "backward.fill"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .stop: "stop.fill"
        case .forward: "forward.fill"
        }
    }
}

enum AppBuildInfo {
    private static var infoDictionary: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    static var version: String {
        infoDictionary["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var buildNumber: String {
        infoDictionary["CFBundleVersion"] as? String ?? "dev"
    }

    static var gitCommit: String {
        infoDictionary["OrbisonicGitCommit"] as? String ?? "not embedded"
    }

    static var gitBranch: String {
        infoDictionary["OrbisonicGitBranch"] as? String ?? ""
    }

    static var gitRefName: String {
        if let refName = infoDictionary["OrbisonicGitRefName"] as? String,
           !refName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return refName
        }
        if !gitBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return gitBranch
        }
        return "unknown"
    }

    static var gitRefKind: String {
        if let refKind = infoDictionary["OrbisonicGitRefKind"] as? String,
           !refKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return refKind
        }
        if !gitBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "branch"
        }
        return "ref"
    }

    static var buildStatusText: String {
        statusText(
            version: version,
            buildNumber: buildNumber,
            gitRefKind: gitRefKind,
            gitRefName: gitRefName,
            gitCommit: gitCommit
        )
    }

    static func statusText(
        version: String,
        buildNumber: String,
        gitRefKind: String,
        gitRefName: String,
        gitCommit: String
    ) -> String {
        let refKind = gitRefKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let refName = gitRefName.trimmingCharacters(in: .whitespacesAndNewlines)
        let refText = refName.isEmpty ? "ref unknown" : "\(refKind.isEmpty ? "ref" : refKind) \(refName)"
        return "v\(version) build \(buildNumber) · \(refText) · \(shortCommit(gitCommit))"
    }

    private static func shortCommit(_ gitCommit: String) -> String {
        let trimmed = gitCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed.isEmpty ? "not embedded" : trimmed }

        let dirtySuffix = trimmed.hasSuffix("-dirty") ? "-dirty" : ""
        let hash = dirtySuffix.isEmpty ? trimmed : String(trimmed.dropLast(dirtySuffix.count))
        return "\(hash.prefix(7))\(dirtySuffix)"
    }

    static var buildDate: String {
        guard let executableURL = Bundle.main.executableURL,
              let modifiedAt = try? FileManager.default
                .attributesOfItem(atPath: executableURL.path)[.modificationDate] as? Date
        else {
            return "not available"
        }

        return Self.dateFormatter.string(from: modifiedAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private enum VUMeterVisualStyle: String, CaseIterable, Identifiable {
    case squarePulse = "Square Pulse"
    case squareFlicker = "Square Flicker"
    case hexPulse = "Hex Pulse"
    case hexFlicker = "Hex Flicker"
    case verticalBars = "Vertical Bars"

    var id: String { rawValue }

    var shapeLabel: String {
        switch self {
        case .squarePulse, .squareFlicker: "Squares"
        case .hexPulse, .hexFlicker: "Hexagons"
        case .verticalBars: "Bars"
        }
    }

    var motionLabel: String {
        switch self {
        case .squarePulse, .hexPulse: "Pulse"
        case .squareFlicker, .hexFlicker: "Flicker"
        case .verticalBars: "Classic"
        }
    }

    var isHex: Bool {
        switch self {
        case .hexPulse, .hexFlicker: true
        case .squarePulse, .squareFlicker, .verticalBars: false
        }
    }

    var isFlicker: Bool {
        switch self {
        case .squareFlicker, .hexFlicker: true
        case .squarePulse, .hexPulse, .verticalBars: false
        }
    }

    var isBars: Bool {
        self == .verticalBars
    }
}

private enum VUMeterColorMode: String, CaseIterable, Identifiable {
    case systemGreen = "System Green"
    case white = "White"
    case sparkle = "Sparkle"
    case classic = "Classic"

    var id: String { rawValue }
}

private enum AudioMotionVUStyle: String, CaseIterable, Identifiable {
    case classicSpectrum = "Classic Spectrum"
    case ledBars = "LED Bars"
    case prismGlow = "Prism Glow"
    case radial = "Radial"
    case mirror = "Mirror"

    var id: String { rawValue }
}

private enum RendererViewportMode: String {
    case plan = "Plan"
    case isometric = "Isometric"

    var cameraPose: (yaw: CGFloat, pitch: CGFloat, distance: CGFloat) {
        switch self {
        case .plan:
            (0, CGFloat.pi / 2 - 0.045, 4.55)
        case .isometric:
            (-0.72, 0.42, 4.25)
        }
    }
}

private struct PlayerDetailRow: Identifiable {
    let title: String
    let value: String
    var hasTopDivider = false

    var id: String { "\(title)-\(hasTopDivider ? "divided" : "plain")" }
}

private enum PlayerRailLayout {
    static let sidebarWidth: CGFloat = 360
    static let artworkSize: CGFloat = 284
    static let detailRowLimit = 4
    static let detailRowHeight: CGFloat = 18
    static let detailRowSpacing: CGFloat = 8
    static let detailLabelWidth: CGFloat = 72
    static let detailContentHeight =
        detailRowHeight * CGFloat(detailRowLimit) +
        detailRowSpacing * CGFloat(detailRowLimit - 1)
}

private struct OutputLaneNaturalHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct EqualHeightPanelRow<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        EqualHeightPanelRowLayout(spacing: spacing) {
            content
        }
    }
}

private struct EqualHeightPanelRowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let totalSpacing = CGFloat(max(subviews.count - 1, 0)) * spacing
        let columnWidth: CGFloat
        let resolvedWidth: CGFloat

        if let proposedWidth = proposal.width {
            resolvedWidth = proposedWidth
            columnWidth = max(0, (proposedWidth - totalSpacing) / CGFloat(subviews.count))
        } else {
            columnWidth = subviews
                .map { $0.sizeThatFits(.unspecified).width }
                .max() ?? 0
            resolvedWidth = columnWidth * CGFloat(subviews.count) + totalSpacing
        }

        let maxNaturalHeight = subviews
            .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
            .max() ?? 0

        return CGSize(width: resolvedWidth, height: maxNaturalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let totalSpacing = CGFloat(max(subviews.count - 1, 0)) * spacing
        let columnWidth = max(0, (bounds.width - totalSpacing) / CGFloat(subviews.count))

        for index in subviews.indices {
            let x = bounds.minX + CGFloat(index) * (columnWidth + spacing)
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
            )
        }
    }
}

private struct StatusChipBackground: View {
    let fillColor: Color
    let strokeColor: Color
    let isLoading: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
            .fill(fillColor)
            .overlay {
                if isLoading {
                    TimelineView(.animation) { timeline in
                        LoadingCrosshatchStripePattern(phase: timeline.date.timeIntervalSinceReferenceDate)
                            .clipShape(RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }
}

private struct LoadingCrosshatchStripePattern: View {
    let phase: TimeInterval

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 9
            let travel = CGFloat(phase.truncatingRemainder(dividingBy: 1.2) / 1.2) * spacing
            drawStripes(
                in: &context,
                size: size,
                spacing: spacing,
                offset: travel,
                slope: 1,
                color: Color.white.opacity(0.30)
            )
            drawStripes(
                in: &context,
                size: size,
                spacing: spacing * 1.4,
                offset: -travel * 0.7,
                slope: -1,
                color: Color.black.opacity(0.12)
            )
        }
    }

    private func drawStripes(
        in context: inout GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        offset: CGFloat,
        slope: CGFloat,
        color: Color
    ) {
        var path = Path()
        let diagonal = size.width + size.height
        var start = -diagonal + offset
        while start < diagonal * 1.6 {
            let startPoint = CGPoint(x: start, y: slope > 0 ? size.height : 0)
            let endPoint = CGPoint(x: start + size.height, y: slope > 0 ? 0 : size.height)
            path.move(to: startPoint)
            path.addLine(to: endPoint)
            start += spacing
        }
        context.stroke(path, with: .color(color), lineWidth: 1)
    }
}

struct PlayerDetailRowContent: Equatable {
    let title: String
    let value: String
    var hasTopDivider = false
}

enum LocalFilePlayerRowsModel {
    static func rows(metadata: AudioSourceMetadata) -> [PlayerDetailRowContent] {
        [
            PlayerDetailRowContent(title: "Format", value: formatText(for: metadata)),
            PlayerDetailRowContent(title: "Channels", value: channelCountText(metadata.channelCount)),
            PlayerDetailRowContent(
                title: "Layout",
                value: layoutText(
                    count: metadata.channelCount,
                    layoutName: metadata.layoutName,
                    formatNote: metadata.formatNote
                )
            ),
            PlayerDetailRowContent(title: "Length", value: metadata.durationText)
        ]
    }

    static func rows(track: LocalMusicTrack) -> [PlayerDetailRowContent] {
        [
            PlayerDetailRowContent(title: "Format", value: localTrackFormatText(for: track)),
            PlayerDetailRowContent(title: "Channels", value: channelCountText(track.channelCount)),
            PlayerDetailRowContent(title: "Layout", value: layoutText(count: track.channelCount, layoutName: track.layoutName)),
            PlayerDetailRowContent(title: "Length", value: track.durationText)
        ]
    }

    private static func formatText(for metadata: AudioSourceMetadata) -> String {
        if metadata.containerName.localizedCaseInsensitiveContains("Matroska"),
           !metadata.codecName.isEmpty {
            return metadata.codecName.localizedCaseInsensitiveContains("Matroska")
                ? metadata.codecName
                : "Matroska \(metadata.codecName)"
        }

        return metadata.codecName.isEmpty ? metadata.containerName : metadata.codecName
    }

    private static func localTrackFormatText(for track: LocalMusicTrack) -> String {
        let container = track.url.pathExtension.uppercased()
        return container.isEmpty ? "Audio file" : container
    }

    static func rendererAtmosNote(_ note: String?) -> String? {
        guard let note = note?.trimmedNilIfBlank else { return nil }
        if isAtmosObjectMetadataNote(note) {
            return "Atmos bed decoded; object metadata not rendered"
        }
        return nil
    }

    private static func channelCountText(_ count: Int) -> String {
        count > 0 ? "\(count)" : "-"
    }

    static func layoutText(count: Int, layoutName: String, formatNote: String? = nil) -> String {
        guard count > 0 else { return "-" }
        let base = layoutName.trimmedNilIfBlank ?? "\(count).0"
        guard isAtmosObjectMetadataNote(formatNote) else { return base }
        guard !base.localizedCaseInsensitiveContains("Atmos") else { return base }
        return "Atmos \(atmosBedLayoutText(count: count, layoutName: base))"
    }

    private static func isAtmosObjectMetadataNote(_ note: String?) -> Bool {
        guard let note = note?.trimmedNilIfBlank else { return false }
        return note.localizedCaseInsensitiveContains("Dolby Atmos metadata present") &&
            note.localizedCaseInsensitiveContains("object rendering")
    }

    private static func atmosBedLayoutText(count: Int, layoutName: String) -> String {
        let lowercased = layoutName.lowercased()
        for layout in ["9.1.6", "7.1.4", "7.1.2", "7.1", "5.1.4", "5.1.2", "5.1"] where lowercased.contains(layout) {
            return layout
        }

        switch count {
        case 6:
            return "5.1"
        case 8:
            return "7.1"
        case 12:
            return "7.1.4"
        case 16:
            return "9.1.6"
        default:
            return layoutName
        }
    }
}

enum RoonPlayerRowsModel {
    static func rows(nowPlaying: RoonNowPlaying?, signalPath: RoonSignalPath?) -> [PlayerDetailRowContent] {
        guard let nowPlaying else { return [] }

        var rows = [
            PlayerDetailRowContent(title: "Format", value: nowPlaying.tidyFormatText)
        ]
        if let channelsText = channelsText(for: signalPath?.sourceChannelCount) {
            rows.append(PlayerDetailRowContent(title: "Channels", value: channelsText))
        }
        rows.append(PlayerDetailRowContent(title: "Length", value: nowPlaying.durationText))
        return rows
    }

    static func channelsText(for sourceChannelCount: Int?) -> String? {
        guard let sourceChannelCount, sourceChannelCount > 0 else { return nil }

        switch sourceChannelCount {
        case 1:
            return "Mono"
        case 2:
            return "Stereo"
        case 4:
            return "Quad"
        case 6:
            return "5.1"
        case 8:
            return "7.1"
        default:
            return "\(sourceChannelCount) ch"
        }
    }
}

private struct VUMeterAppearance {
    let elementScale: Double
    let maxSizeRatio: Double
    let outlineWeight: Double
    let labelGapScale: Double
    let colorMode: VUMeterColorMode

    static let `default` = VUMeterAppearance(
        elementScale: 1,
        maxSizeRatio: 3,
        outlineWeight: 1,
        labelGapScale: 1,
        colorMode: .systemGreen
    )

    var resolvedElementScale: Double {
        min(max(elementScale, 0.6), 9.0)
    }

    var resolvedMaxSizeRatio: Double {
        min(max(maxSizeRatio, 1), 20)
    }

    var resolvedOutlineWeight: CGFloat {
        CGFloat(min(max(outlineWeight, 0.5), 3))
    }

    var resolvedLabelGapScale: CGFloat {
        CGFloat(min(max(labelGapScale, 0.45), 1.35))
    }

    var resolvedPanelFillScale: CGFloat {
        let normalized = log(resolvedElementScale / 0.6) / log(9.0 / 0.6)
        return CGFloat(0.35 + min(max(normalized, 0), 1) * 0.65)
    }
}

private enum VUMeterControlScale {
    static let sliderRange: ClosedRange<Double> = -10...10
    static let elementScaleCenter = 6.733140080428954
    static let maxSizeRatioCenter = 14.66689430312875
    static let outlineWeightCenter = 1.339100201072386
    static let labelGapScaleCenter = 1.0

    static func clampedOffset(_ value: Double) -> Double {
        min(max(value, sliderRange.lowerBound), sliderRange.upperBound)
    }

    static func elementScale(offset: Double) -> Double {
        let multiplier = pow(2.0, clampedOffset(offset) / 10.0 * 0.65)
        return min(max(elementScaleCenter * multiplier, 0.6), 9.0)
    }

    static func maxSizeRatio(offset: Double) -> Double {
        let multiplier = pow(2.0, clampedOffset(offset) / 10.0 * 0.45)
        return min(max(maxSizeRatioCenter * multiplier, 1.0), 20.0)
    }

    static func outlineWeight(offset: Double) -> Double {
        min(max(outlineWeightCenter + clampedOffset(offset) * 0.085, 0.5), 3.0)
    }

    static func labelGapScale(offset: Double) -> Double {
        let offset = clampedOffset(offset)
        if offset < 0 {
            return labelGapScaleCenter + offset / 10.0 * 0.55
        }
        return labelGapScaleCenter + offset / 10.0 * 0.35
    }
}

struct VUMeterVerticalBarLayout {
    static func frames(count: Int, rect: CGRect) -> [CGRect] {
        let count = max(1, count)
        let denseLayout = count > 8
        let baseGap = denseLayout
            ? min(CGFloat(5), max(CGFloat(1.5), rect.width * 0.006))
            : min(CGFloat(10), max(CGFloat(3), rect.width * 0.012))
        let maxGap = count > 1 ? (rect.width * 0.35) / CGFloat(count - 1) : 0
        let gap = count > 1 ? min(baseGap, maxGap) : 0
        let availableWidth = max(CGFloat(1), rect.width - gap * CGFloat(max(count - 1, 0)))
        let rawColumnWidth = availableWidth / CGFloat(count)
        let columnWidth = max(CGFloat(1), min(rawColumnWidth, rect.height * 0.5))
        let groupWidth = columnWidth * CGFloat(count) + gap * CGFloat(max(count - 1, 0))
        let startX = rect.midX - groupWidth / 2

        return (0..<count).map { index in
            CGRect(
                x: startX + CGFloat(index) * (columnWidth + gap),
                y: rect.minY,
                width: columnWidth,
                height: rect.height
            )
        }
    }
}

enum VUMeterChannelLabel {
    static func text(for channel: SurroundChannel) -> String {
        switch channel.role {
        case .frontLeft:
            "L"
        case .frontRight:
            "R"
        case .center:
            "C"
        case .lfe:
            "LFE"
        case .lfe2:
            "LFE2"
        case .sideLeft:
            "Ls"
        case .sideRight:
            "Rs"
        case .rearLeft:
            "Lb"
        case .rearRight:
            "Rb"
        case .rearCenter:
            "Cb"
        case .wideLeft:
            "Lw"
        case .wideRight:
            "Rw"
        case .frontLeftCenter:
            "Lc"
        case .frontRightCenter:
            "Rc"
        case .topFrontLeft:
            "TFL"
        case .topFrontCenter:
            "TFC"
        case .topFrontRight:
            "TFR"
        case .topMiddleLeft:
            "TML"
        case .topMiddleCenter:
            "TMC"
        case .topMiddleRight:
            "TMR"
        case .topRearLeft:
            "TRL"
        case .topRearCenter:
            "TRC"
        case .topRearRight:
            "TRR"
        case .discrete(let index):
            "\(index + 1)"
        }
    }
}

struct LabButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.orbisonicPalette) private var palette

    var isActive = false
    var accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        let activeAccent = accent ?? palette.accent
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isEnabled ? (isActive ? palette.text : palette.textSoft) : palette.textSoft.opacity(0.58))
            .frame(minHeight: 34)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                    .fill(buttonFill(configuration: configuration, activeAccent: activeAccent))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                    .stroke(isEnabled ? (isActive ? activeAccent.opacity(0.55) : palette.line) : palette.line.opacity(0.48), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.62)
    }

    private func buttonFill(configuration: Configuration, activeAccent: Color) -> Color {
        if !isEnabled {
            return Color.white.opacity(0.024)
        }
        if isActive {
            return activeAccent.opacity(configuration.isPressed ? 0.22 : 0.14)
        }
        return Color.white.opacity(configuration.isPressed ? 0.075 : 0.045)
    }
}

private struct OrbisonicLinearControl: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.orbisonicPalette) private var palette
    @State private var isEditing = false

    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var normalizedValue: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let trackHeight: CGFloat = 7
                let thumbSize: CGFloat = 16
                let fillWidth = width * CGFloat(normalizedValue)
                let thumbX = min(max(fillWidth - thumbSize / 2, 0), max(width - thumbSize, 0))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.linearControlWell)
                        .frame(height: trackHeight)

                    if normalizedValue > 0 {
                        Capsule()
                            .fill(palette.linearControlGradient)
                            .frame(width: max(trackHeight, fillWidth), height: trackHeight)
                            .clipShape(Capsule())
                    }

                    Circle()
                        .fill(palette.linearControlThumb)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay(
                            Circle()
                                .stroke(palette.text.opacity(0.34), lineWidth: 1)
                        )
                        .shadow(color: palette.linearControlThumb.opacity(0.32), radius: 7, x: 0, y: 0)
                        .offset(x: thumbX)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(linearDragGesture(width: width))
                .accessibilityHidden(true)
            }

            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .tint(.clear)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.42)
    }

    private func linearDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }
                if !isEditing {
                    isEditing = true
                    onEditingChanged(true)
                }
                updateValue(at: gesture.location.x, width: width)
            }
            .onEnded { gesture in
                guard isEnabled else { return }
                updateValue(at: gesture.location.x, width: width)
                if isEditing {
                    isEditing = false
                    onEditingChanged(false)
                }
            }
    }

    private func updateValue(at locationX: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let normalized = min(max(Double(locationX / width), 0), 1)
        value = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
    }
}

private struct PlayerArtworkView: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )

            if let url {
                if url.isFileURL, let image = NSImage(contentsOf: url) {
                    artworkImage(Image(nsImage: image))
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            artworkImage(image)
                        default:
                            artworkPlaceholder
                        }
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous))
    }

    private func artworkImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(LabTheme.textSoft)
    }
}

private struct LocalMusicThumbnailView: View {
    let artworkPath: String?
    var fallbackSystemImage = "music.note"
    private let size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(LabTheme.line.opacity(0.82), lineWidth: 1)
                )

            if let path = artworkPath?.trimmedNilIfBlank,
               let image = NSImage(contentsOf: URL(fileURLWithPath: path)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft.opacity(0.78))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ActivityBanner: View {
    let activity: PlaybackActivity

    var body: some View {
        HStack(spacing: 10) {
            if let progress = activity.clampedProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(activity.label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .shadow(radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.label)
    }
}

struct ContentView: View {
    @StateObject private var model = OrbisonicViewModel()
    @AppStorage("Orbisonic.hasConfirmedLoopbackSetup") private var hasConfirmedLoopbackSetup = false
    @State private var selectedStageTab: StageTab = .input
    @State private var selectedLocalMusicPanel: LocalMusicPanel = .music
    @AppStorage("Orbisonic.vuMeterStyle") private var selectedVUMeterStyle: VUMeterVisualStyle = .verticalBars
    @AppStorage("Orbisonic.audioMotionVUStyle") private var selectedAudioMotionVUStyle: AudioMotionVUStyle = .prismGlow
    @AppStorage("Orbisonic.vuMeterReferenceDbFS") private var vuMeterReferenceDbFS = VUMeterCalibrationSettings.default.referenceDbFS
    @AppStorage("Orbisonic.vuMeterResponseMode") private var vuMeterResponseMode: VUMeterResponseMode = .standard
    @AppStorage("Orbisonic.vuMeterMonitorTrimDb") private var vuMeterMonitorTrimDb = VUMeterCalibrationSettings.default.monitorTrimDb
    @AppStorage("Orbisonic.vuMeterSonicSphereTrimDb") private var vuMeterSonicSphereTrimDb = VUMeterCalibrationSettings.default.sonicSphereTrimDb
    @AppStorage("Orbisonic.vuMeterElementScaleOffset") private var vuMeterElementScale = 0.0
    @AppStorage("Orbisonic.vuMeterMaxSizeRatioOffset") private var vuMeterMaxSizeRatio = 0.0
    @AppStorage("Orbisonic.vuMeterOutlineWeightOffset") private var vuMeterOutlineWeight = 0.0
    @AppStorage("Orbisonic.vuMeterLabelGapOffset") private var vuMeterLabelGapOffset = 0.0
    @AppStorage("Orbisonic.vuMeterColorMode") private var vuMeterColorMode: VUMeterColorMode = .classic
    @AppStorage("Orbisonic.vuMeterScaleVersion") private var vuMeterScaleVersion = 0
    @AppStorage(OrbisonicColorScheme.storageKey) private var colorSchemeRawValue = OrbisonicColorScheme.defaultScheme.rawValue
    @State private var showsLoopbackSetupDialog = false
    @State private var vuOptionsExpanded = false
    @State private var showsSaveQueuePlaylistDialog = false
    @State private var saveQueuePlaylistName = ""
    @State private var showsNewPlaylistDialog = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistTrack: LocalMusicTrack?
    @State private var showsRenamePlaylistDialog = false
    @State private var renamePlaylistName = ""
    @State private var playlistPendingRename: LocalMusicPlaylist?
    @State private var playlistPendingDeletion: LocalMusicPlaylist?
    @State private var rendererTuningExpanded = false
    @State private var outputLaneEqualHeight: CGFloat = 0
    private let outputLaneLabelColumnWidth: CGFloat = 112
    private let outputLaneColumnSpacing: CGFloat = 12

    private var activeColorScheme: OrbisonicColorScheme {
        OrbisonicColorScheme.from(rawValue: colorSchemeRawValue)
    }

    private var activePalette: OrbisonicPalette {
        activeColorScheme.palette
    }

    var body: some View {
        appShell
            .padding(24)
            .frame(minWidth: 1_220, minHeight: 780, alignment: .topLeading)
            .overlay(alignment: .top) {
                if model.activity.isBusy {
                    ActivityBanner(activity: model.activity)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.activity)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [activePalette.backgroundTop, activePalette.backgroundBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [activePalette.accent.opacity(0.17), Color.clear],
                        center: .topTrailing,
                        startRadius: 40,
                        endRadius: 760
                    )
                }
            )
            .orbisonicPalette(activePalette)
            .alert("Audio Error", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )) {
                Button("OK") {
                    model.lastError = nil
                }
            } message: {
                Text(model.lastError ?? "Unknown error")
            }
            .confirmationDialog(
                "Install Orbisonic Inputs",
                isPresented: $showsLoopbackSetupDialog,
                titleVisibility: .visible
            ) {
                Button("Got It") {
                    hasConfirmedLoopbackSetup = true
                }
                Button("Remind Me Later", role: .cancel) {}
            } message: {
                Text("Install Orbisonic Inputs to use Roon, Spotify, and Aux Cable live capture. Roon and Spotify Connect are optional source helpers. Local Music works without live inputs.")
            }
            .onAppear {
                normalizeColorSchemeStorage()
                migrateCenteredVUMeterDefaultsIfNeeded()
                applyVUMeterCalibration()
                if !hasConfirmedLoopbackSetup {
                    showsLoopbackSetupDialog = true
                }
            }
            .onChange(of: colorSchemeRawValue) { _, _ in normalizeColorSchemeStorage() }
            .onChange(of: vuMeterReferenceDbFS) { _, _ in applyVUMeterCalibration() }
            .onChange(of: vuMeterResponseMode) { _, _ in applyVUMeterCalibration() }
            .onChange(of: vuMeterMonitorTrimDb) { _, _ in applyVUMeterCalibration() }
            .onChange(of: vuMeterSonicSphereTrimDb) { _, _ in applyVUMeterCalibration() }
            .sheet(isPresented: $showsSaveQueuePlaylistDialog) {
                SavePlaylistDialog(
                    title: "Save Queue as Playlist",
                    name: $saveQueuePlaylistName,
                    onCancel: {
                        showsSaveQueuePlaylistDialog = false
                    },
                    onSave: {
                        model.saveSessionQueueAsPlaylist(named: saveQueuePlaylistName)
                        showsSaveQueuePlaylistDialog = false
                    }
                )
            }
            .sheet(isPresented: $showsNewPlaylistDialog) {
                SavePlaylistDialog(
                    title: "New Playlist",
                    primaryActionTitle: "Create",
                    name: $newPlaylistName,
                    onCancel: {
                        showsNewPlaylistDialog = false
                        newPlaylistTrack = nil
                    },
                    onSave: {
                        if let track = newPlaylistTrack {
                            model.addLocalMusicTrackToNewPlaylist(track, named: newPlaylistName)
                        } else {
                            model.createLocalMusicPlaylist(named: newPlaylistName)
                        }
                        showsNewPlaylistDialog = false
                        newPlaylistTrack = nil
                    }
                )
            }
            .sheet(isPresented: $showsRenamePlaylistDialog) {
                SavePlaylistDialog(
                    title: "Rename Playlist",
                    primaryActionTitle: "Rename",
                    name: $renamePlaylistName,
                    onCancel: {
                        showsRenamePlaylistDialog = false
                        playlistPendingRename = nil
                    },
                    onSave: {
                        if let playlist = playlistPendingRename {
                            model.renameLocalMusicPlaylist(playlist, named: renamePlaylistName)
                        }
                        showsRenamePlaylistDialog = false
                        playlistPendingRename = nil
                    }
                )
            }
            .confirmationDialog(
                "Remove Playlist",
                isPresented: Binding(
                    get: { playlistPendingDeletion != nil },
                    set: { if !$0 { playlistPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let playlist = playlistPendingDeletion {
                    let isEditable = model.isEditableLocalMusicPlaylist(playlist)
                    Button(isEditable ? "Delete Playlist" : "Remove Playlist", role: .destructive) {
                        model.deleteLocalMusicPlaylist(playlist)
                        playlistPendingDeletion = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    playlistPendingDeletion = nil
                }
            } message: {
                if let playlist = playlistPendingDeletion {
                    Text(model.isEditableLocalMusicPlaylist(playlist)
                        ? "Delete \(playlist.name) from Orbisonic playlists. This removes the managed playlist file."
                        : "Remove \(playlist.name) from Orbisonic. The external M3U file will not be deleted.")
                }
            }
    }

    private var appShell: some View {
        HStack(alignment: .top, spacing: 24) {
            sidebarColumn
            stage
        }
    }

    private var sidebarColumn: some View {
        sidebar
            .frame(width: PlayerRailLayout.sidebarWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard

            nowPlayingSessionCard
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedStageTab.rawValue)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .frame(height: 24, alignment: .leading)

                stageTabBar
            }

            selectedStageContent
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.36), radius: 28, x: 0, y: 18)
        )
    }

    @ViewBuilder
    private var selectedStageContent: some View {
        switch selectedStageTab {
        case .input:
            stageViewport { inputTab }
        case .renderer:
            stageViewport { rendererTab }
        case .output:
            stageViewport { outputTab }
        case .analyzerVU:
            stageViewport { analyzerVUTab }
        case .localMusic:
            stageViewport(scrolls: false) { localMusicTab }
        case .diagnostics:
            stageViewport { diagnosticsTab }
        case .settings:
            stageViewport { settingsTab }
        }
    }

    private var stageTabBar: some View {
        HStack(spacing: 4) {
            ForEach(StageTab.allCases) { tab in
                Button {
                    selectedStageTab = tab
                } label: {
                    Text(tab.rawValue)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LabButtonStyle(isActive: selectedStageTab == tab))
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.toolbar)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private func migrateCenteredVUMeterDefaultsIfNeeded() {
        let previousScaleVersion = UserDefaults.standard.integer(forKey: VUMeterDefaultsMigration.scaleVersionKey)
        guard VUMeterDefaultsMigration.migrate(defaults: .standard) else { return }
        let settings = VUMeterDefaultsMigration.settings(defaults: .standard)
        vuMeterReferenceDbFS = settings.referenceDbFS
        vuMeterResponseMode = settings.responseMode
        vuMeterMonitorTrimDb = settings.monitorTrimDb
        vuMeterSonicSphereTrimDb = settings.sonicSphereTrimDb
        if previousScaleVersion < 4 {
            vuMeterElementScale = 0
            vuMeterMaxSizeRatio = 0
            vuMeterOutlineWeight = 0
        }
        vuMeterScaleVersion = VUMeterDefaultsMigration.currentScaleVersion
        AppLogger.shared.notice(category: "settings", "Migrated VU meter signal calibration defaults.")
    }

    private func applyVUMeterCalibration() {
        model.updateVUMeterCalibration(
            VUMeterCalibrationSettings(
                referenceDbFS: vuMeterReferenceDbFS,
                responseMode: vuMeterResponseMode,
                monitorTrimDb: vuMeterMonitorTrimDb,
                sonicSphereTrimDb: vuMeterSonicSphereTrimDb
            )
        )
    }

    private func normalizeColorSchemeStorage() {
        let normalized = activeColorScheme.rawValue
        if colorSchemeRawValue != normalized {
            colorSchemeRawValue = normalized
        }
    }

    private var inputTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsPanel(title: "Source Selector") {
                sourceSelectorPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var routingTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            routingFlowGraphic

            routingCompactMeters

            OrbisonicDisclosureTray(
                isExpanded: $vuOptionsExpanded,
                title: "VU Options",
                systemImage: "slider.horizontal.3",
                trailingSummary: selectedAudioMotionVUStyle.rawValue
            ) {
                analyzerVUStylePicker
                vuMeterCalibrationControls
                vuMeterAppearanceSliders
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var analyzerVUTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                AudioMotionVUMeterPanel(
                    title: "Input",
                    subtitle: "",
                    style: selectedAudioMotionVUStyle,
                    appearance: inputVUMeterAppearance,
                    meterStore: model.meterStore,
                    minMeterHeight: 160,
                    showsMeterPills: false
                )

                AudioMotionVUMeterPanel(
                    title: "Monitor",
                    subtitle: "",
                    style: selectedAudioMotionVUStyle,
                    appearance: monitorVUMeterAppearance,
                    meterStore: model.monitorMeterStore,
                    minMeterHeight: 160,
                    showsMeterPills: false
                )
            }

            AudioMotionVUMeterPanel(
                title: "Sonic Sphere",
                subtitle: "",
                style: selectedAudioMotionVUStyle,
                appearance: rendererVUMeterAppearance,
                meterStore: model.rendererMeterStore,
                minMeterHeight: 260,
                showsMeterPills: false
            )

            vuOptionsPanel
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var vuOptionsPanel: some View {
        OrbisonicDisclosureTray(
            isExpanded: $vuOptionsExpanded,
            title: "VU Options",
            systemImage: "slider.horizontal.3",
            trailingSummary: selectedAudioMotionVUStyle.rawValue
        ) {
            analyzerVUStylePicker
            vuMeterCalibrationControls
            vuMeterAppearanceSliders
        }
    }

    private var analyzerVUStylePicker: some View {
        HStack(spacing: 10) {
            ForEach(AudioMotionVUStyle.allCases) { style in
                Button {
                    selectedAudioMotionVUStyle = style
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        AudioMotionVUStylePreview(style: style)
                            .frame(height: 38)

                        Text(style.rawValue)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(LabTheme.text)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
                .buttonStyle(LabButtonStyle(isActive: selectedAudioMotionVUStyle == style))
            }
        }
    }

    private var sourceSelectorPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    ForEach(primarySourceModes) { mode in
                        sourceModeButton(for: mode)
                    }
                }
                .frame(width: 146)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Source")

                VStack(alignment: .leading, spacing: 10) {
                    Text(selectedSourceHeadline)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(LabTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel((model.sourceSwitchTargetMode ?? model.sourceMode).displayName)

                    if let detailText = selectedSourceDetailText.trimmedNilIfBlank {
                        Text(detailText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LabTheme.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !selectedSourceSections.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(selectedSourceSections) { section in
                                inputSourceStatusSection(section)
                            }
                        }
                    } else if !selectedSourceRows.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(selectedSourceRows) { row in
                                inputSourceStatusRow(title: row.title, value: row.value)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .fill(LabTheme.panelSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                                .stroke(LabTheme.line, lineWidth: 1)
                        )
                )
            }
        }
    }

    private func sourceModeButton(for mode: SourceMode) -> some View {
        Button {
            model.selectSourceMode(mode)
        } label: {
            Text(mode.displayName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(LabButtonStyle(isActive: sourceButtonIsActive(mode), accent: sourceButtonAccent(for: mode)))
    }

    private func inputSourceStatusSection(_ section: InputSourceStatusSection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(LabTheme.cyan.opacity(0.86))
                .lineLimit(1)

            ForEach(section.rows) { row in
                inputSourceStatusRow(title: row.title, value: row.value)
            }
        }
    }

    private func inputSourceStatusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 184, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(inputSourceStatusValueLineLimit(for: title))
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inputSourceStatusValueLineLimit(for title: String) -> Int {
        switch title {
        case "Now playing":
            return 2
        default:
            return 3
        }
    }

    private var selectedSourceStatusColor: Color {
        if model.sourceSwitchStatusText != nil {
            return LabTheme.amber
        }
        if model.sourceMode == .off {
            return LabTheme.textSoft
        }
        if model.sourceMode.isLiveInput {
            if isSelectedLiveSourceUnavailable ||
                (model.sourceMode == .roon && liveInputReadyValue(expected: .roonInput) == "Missing") ||
                (model.sourceMode == .spotify && (
                    isSpotifyReceiverUnavailable ||
                    liveInputReadyValue(expected: .spotifyInput) == "Missing"
                )) ||
                (model.sourceMode == .aux && liveInputReadyValue(expected: .auxCable) == "Missing") {
                return LabTheme.red
            }
            switch model.liveMonitorState {
            case .monitoring:
                return LabTheme.green
            case .silent, .stopped, .muted:
                return LabTheme.textSoft
            case .unavailable, .error:
                return LabTheme.red
            }
        }
        return model.isPlaying || model.isTestTonePlaying ? LabTheme.green : LabTheme.textSoft
    }

    private var selectedSourceHeadline: String {
        model.inputSourceStatusPanel.headline
    }

    private var selectedSourceDetailText: String {
        model.inputSourceStatusPanel.body
    }

    private var selectedSourceRows: [PlayerDetailRow] {
        model.inputSourceStatusPanel.rows.map { row in
            PlayerDetailRow(title: row.title, value: row.value)
        }
    }

    private var selectedSourceSections: [InputSourceStatusSection] {
        model.inputSourceStatusPanel.sections
    }

    private func liveInputReadyValue(expected: OrbisonicLoopbackDevice) -> String {
        model.inputRoute.uid == expected.deviceUID ? "Ready" : "Missing"
    }

    private var isSelectedLiveSourceUnavailable: Bool {
        guard model.sourceMode.isLiveInput else { return false }
        switch model.liveMonitorState {
        case .unavailable, .error:
            return true
        case .stopped, .monitoring, .muted, .silent:
            return false
        }
    }

    private var isSpotifyReceiverUnavailable: Bool {
        switch model.spotifyReceiverStatus.state {
        case .notStarted, .failed, .embeddedModuleUnavailable:
            return true
        case .waitingForConnection, .running, .restarting:
            return false
        }
    }

    private var liveSignalValue: String {
        switch model.liveMonitorState {
        case .monitoring:
            return "Present"
        case .silent, .stopped, .muted:
            return "No audio yet"
        case .unavailable, .error:
            return "No audio"
        }
    }

    private func sourceButtonIsActive(_ mode: SourceMode) -> Bool {
        model.sourceSwitchTargetMode == mode || model.sourceMode == mode
    }

    private func sourceButtonAccent(for mode: SourceMode) -> Color {
        guard sourceButtonIsActive(mode) else {
            return LabTheme.blue
        }
        return selectedSourceStatusColor
    }

    private var primarySourceModes: [SourceMode] {
        SourceMode.musicInputs
    }

    private var inputDeviceMenu: some View {
        Menu {
            ForEach(model.availableInputRoutes) { route in
                Button(route.deviceName) {
                    model.selectInputRoute(route)
                }
                .disabled(model.sourceMode.isLiveInput && !model.sourceMode.acceptsInputRoute(route))
            }
        } label: {
            HStack {
                Text("APP INPUT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft)
                Spacer()
                Text(model.inputRoute.displayName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LabTheme.cyan)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LabButtonStyle(isActive: model.inputRoute.isAvailable))
    }

    private var testTonePointMenu: some View {
        Menu {
            ForEach(TestTonePipelinePoint.allCases) { point in
                Button(point.rawValue) {
                    model.selectedTestTonePoint = point
                }
            }
        } label: {
            HStack {
                Text("TONE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft)
                Spacer()
                Text(model.selectedTestTonePoint.rawValue)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LabTheme.cyan)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LabButtonStyle())
    }

    private var routingFlowGraphic: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Signal Flow")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                Text("input arrives automatically; routing creates Output 1 Monitor and Output 2 Renderer streams")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 12) {
                routingNodeCard(
                    step: "Source",
                    title: model.sourceMode.displayName,
                    detail: model.sourceFlowDetail,
                    icon: "dial.medium"
                )

                flowArrow

                routingNodeCard(
                    step: "Incoming",
                    title: "Auto-detected stream",
                    detail: model.sourceMode.isLiveInput ? model.inputNowText : model.sourceFlowTitle,
                    icon: "waveform.path.ecg"
                )

                flowArrow

                routingNodeCard(
                    step: "Routing",
                    title: "Split to two outputs",
                    detail: "Output 1 Monitor stays on this Mac; Output 2 Renderer targets the selected Sonic Sphere or sound system.",
                    icon: "arrow.triangle.branch"
                )

                flowArrow

                VStack(spacing: 10) {
                    routingOutputCard(
                        title: "Output 1",
                        subtitle: "Output 1 Monitor",
                        device: model.monitorOutputNowText,
                        status: model.monitorOutputStatusText,
                        icon: "headphones",
                        accent: LabTheme.blue
                    )

                    routingOutputCard(
                        title: "Output 2",
                        subtitle: "Output 2 Renderer",
                        device: model.rendererOutputNowText,
                        matrix: model.rendererSceneOutputText,
                        status: model.rendererOutputStatusText,
                        icon: "dot.radiowaves.left.and.right",
                        accent: LabTheme.cyan
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private func routingNodeCard(
        step: String,
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LabTheme.cyan)
                    .frame(width: 22, height: 22)
                Text(step.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft)
                Spacer(minLength: 0)
            }

            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: 34, alignment: .bottomLeading)

            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LabTheme.textSoft)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(height: 46, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panelSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private func routingOutputCard(
        title: String,
        subtitle: String,
        device: String,
        matrix: String? = nil,
        status: String,
        icon: String,
        accent: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft)
                Text(subtitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                routingOutputCardRow(label: "Device", value: device)
                if let matrix {
                    routingOutputCardRow(label: "Matrix", value: matrix)
                }
                routingOutputCardRow(label: "Status", value: status)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: matrix == nil ? 72 : 90)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(accent.opacity(0.36), lineWidth: 1)
                )
        )
    }

    private func routingOutputCardRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LabTheme.textSoft)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var routingCompactMeters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AudioMotionVUMeterPanel(
                    title: "Input",
                    subtitle: inputVUMeterSubtitle,
                    style: selectedAudioMotionVUStyle,
                    appearance: inputVUMeterAppearance,
                    meterStore: model.meterStore,
                    minMeterHeight: 132,
                    showsMeterPills: false
                )

                AudioMotionVUMeterPanel(
                    title: "Output 1 Monitor",
                    subtitle: monitorVUMeterSubtitle,
                    style: selectedAudioMotionVUStyle,
                    appearance: monitorVUMeterAppearance,
                    meterStore: model.monitorMeterStore,
                    minMeterHeight: 132,
                    showsMeterPills: false
                )
            }

            AudioMotionVUMeterPanel(
                title: "Sonic Sphere Analysis Meter",
                subtitle: "",
                style: selectedAudioMotionVUStyle,
                appearance: rendererVUMeterAppearance,
                meterStore: model.rendererMeterStore,
                minMeterHeight: 150,
                showsMeterPills: false
            )
        }
    }

    private var outputTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                outputDestinationCard(
                    title: "Output 1: Listen locally"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        outputLaneControlRow(label: "Device") {
                            monitorOutputMenu
                        }
                        if let warning = model.monitorOutputWarningText {
                            outputLaneWarningText(warning)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                outputDestinationCard(
                    title: "Output 2: Sonic Sphere"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        outputLaneControlRow(label: "Device") {
                            rendererOutputMenu
                        }
                        if let warning = model.rendererOutputWarningText {
                            outputLaneWarningText(warning)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onPreferenceChange(OutputLaneNaturalHeightPreferenceKey.self) { height in
                if abs(outputLaneEqualHeight - height) > 0.5 {
                    outputLaneEqualHeight = height
                }
            }

            settingsPanel(title: "Now playing on Sonic Sphere webpage (local network only)") {
                webURLRow(title: "Link", url: model.webPublicPageURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var monitorOutputMenu: some View {
        Menu {
            Button("not set") {
                model.selectNoMonitorOutput()
            }

            Button("System Default") {
                model.selectSystemMonitorOutput()
            }

            Divider()

            ForEach(model.availableOutputRoutes) { route in
                Button(route.deviceName) {
                    model.selectMonitorOutputRoute(route)
                }
                .disabled(!route.isSelectableOutputTarget)
            }
        } label: {
            outputLaneMenuValue(model.monitorOutputDevicePickerText)
        }
        .buttonStyle(LabButtonStyle(isActive: true))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Output 1: Listen locally")
        .accessibilityValue(model.monitorOutputDevicePickerText)
    }

    private var rendererOutputMenu: some View {
        Menu {
            Button("not set") {
                model.selectNoRendererOutput()
            }

            Divider()

            ForEach(model.availableOutputRoutes) { route in
                Button(route.deviceName) {
                    model.selectRendererOutputRoute(route)
                }
                .disabled(!route.isSelectableOutputTarget)
            }
        } label: {
            outputLaneMenuValue(model.rendererOutputDevicePickerText)
        }
        .buttonStyle(LabButtonStyle(isActive: true))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Output 2: Sonic Sphere")
        .accessibilityValue(model.rendererOutputDevicePickerText)
    }

    private var vuMeterTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                DenseVUMeterPanel(
                    title: "Input",
                    subtitle: inputVUMeterSubtitle,
                    style: selectedVUMeterStyle,
                    appearance: inputVUMeterAppearance,
                    meterStore: model.meterStore,
                    minHeight: 220
                )

                DenseVUMeterPanel(
                    title: "Output 1 Monitor",
                    subtitle: monitorVUMeterSubtitle,
                    style: selectedVUMeterStyle,
                    appearance: monitorVUMeterAppearance,
                    meterStore: model.monitorMeterStore,
                    minHeight: 220
                )
            }

            AudioMotionVUMeterPanel(
                title: "Sonic Sphere Analysis Meter",
                subtitle: "",
                style: selectedAudioMotionVUStyle,
                appearance: rendererVUMeterAppearance,
                meterStore: model.rendererMeterStore,
                minMeterHeight: 260
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var vuMeterStylePicker: some View {
        HStack(spacing: 10) {
            ForEach(VUMeterVisualStyle.allCases) { style in
                Button {
                    selectedVUMeterStyle = style
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        VUMeterStylePreview(style: style, appearance: previewVUMeterAppearance)
                            .frame(height: 46)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.rawValue)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LabTheme.text)
                            Text("\(style.shapeLabel) • \(style.motionLabel)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(LabTheme.textSoft)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(LabButtonStyle(isActive: selectedVUMeterStyle == style))
            }
        }
    }

    private var inputVUMeterAppearance: VUMeterAppearance {
        vuMeterAppearance()
    }

    private var monitorVUMeterAppearance: VUMeterAppearance {
        vuMeterAppearance()
    }

    private var rendererVUMeterAppearance: VUMeterAppearance {
        vuMeterAppearance()
    }

    private var previewVUMeterAppearance: VUMeterAppearance {
        rendererVUMeterAppearance
    }

    private func vuMeterAppearance() -> VUMeterAppearance {
        VUMeterAppearance(
            elementScale: VUMeterControlScale.elementScale(offset: vuMeterElementScale),
            maxSizeRatio: VUMeterControlScale.maxSizeRatio(offset: vuMeterMaxSizeRatio),
            outlineWeight: VUMeterControlScale.outlineWeight(offset: vuMeterOutlineWeight),
            labelGapScale: VUMeterControlScale.labelGapScale(offset: vuMeterLabelGapOffset),
            colorMode: .classic
        )
    }

    private var vuMeterElementScaleBinding: Binding<Double> {
        Binding(
            get: { VUMeterControlScale.clampedOffset(vuMeterElementScale) },
            set: { vuMeterElementScale = VUMeterControlScale.clampedOffset($0) }
        )
    }

    private var vuMeterMaxSizeRatioBinding: Binding<Double> {
        Binding(
            get: { VUMeterControlScale.clampedOffset(vuMeterMaxSizeRatio) },
            set: { vuMeterMaxSizeRatio = VUMeterControlScale.clampedOffset($0) }
        )
    }

    private var vuMeterOutlineWeightBinding: Binding<Double> {
        Binding(
            get: { VUMeterControlScale.clampedOffset(vuMeterOutlineWeight) },
            set: { vuMeterOutlineWeight = VUMeterControlScale.clampedOffset($0) }
        )
    }

    private var vuMeterLabelGapBinding: Binding<Double> {
        Binding(
            get: { VUMeterControlScale.clampedOffset(vuMeterLabelGapOffset) },
            set: { vuMeterLabelGapOffset = VUMeterControlScale.clampedOffset($0) }
        )
    }

    private var vuMeterReferenceDbFSBinding: Binding<Double> {
        Binding(
            get: { min(max(vuMeterReferenceDbFS, VUMeterCalibrationSettings.referenceRange.lowerBound), VUMeterCalibrationSettings.referenceRange.upperBound) },
            set: { vuMeterReferenceDbFS = min(max($0, VUMeterCalibrationSettings.referenceRange.lowerBound), VUMeterCalibrationSettings.referenceRange.upperBound) }
        )
    }

    private var vuMeterMonitorTrimDbBinding: Binding<Double> {
        Binding(
            get: { min(max(vuMeterMonitorTrimDb, VUMeterCalibrationSettings.trimRange.lowerBound), VUMeterCalibrationSettings.trimRange.upperBound) },
            set: { vuMeterMonitorTrimDb = min(max($0, VUMeterCalibrationSettings.trimRange.lowerBound), VUMeterCalibrationSettings.trimRange.upperBound) }
        )
    }

    private var vuMeterSonicSphereTrimDbBinding: Binding<Double> {
        Binding(
            get: { min(max(vuMeterSonicSphereTrimDb, VUMeterCalibrationSettings.trimRange.lowerBound), VUMeterCalibrationSettings.trimRange.upperBound) },
            set: { vuMeterSonicSphereTrimDb = min(max($0, VUMeterCalibrationSettings.trimRange.lowerBound), VUMeterCalibrationSettings.trimRange.upperBound) }
        )
    }

    private var inputVUMeterSubtitle: String {
        let sourceText = model.sourceMode.isLiveInput ? model.inputRoute.displayName : model.loadedFileName
        let count = model.meterStore.channelMeters.count
        return count > 0 ? "\(sourceText) • \(count) ch" : "\(sourceText) • no input channels"
    }

    private var monitorVUMeterSubtitle: String {
        let count = model.monitorMeterStore.channelMeters.count
        return "\(model.monitorOutputNowText) • \(count) ch"
    }

    private var rendererVUMeterSubtitle: String {
        let count = model.rendererMeterStore.channelMeters.count
        if !model.sonicSphereMeterActive {
            return "\(model.rendererText) • no measured Sonic Sphere analysis bus"
        }
        return "\(model.rendererText) • \(count) analysis channels"
    }

    private var rendererTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsPanel(title: "Mode") {
                rendererModeSelector
            }

            EqualHeightPanelRow(spacing: 18) {
                monitorDownmixRenderPanel
                sonicSphereRenderPanel
            }

            OrbisonicDisclosureTray(
                isExpanded: $rendererTuningExpanded,
                title: "Tuning",
                systemImage: "slider.horizontal.3",
                style: .diagnostics
            ) {
                rendererTuningControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var monitorDownmixRenderPanel: some View {
        let panel = model.monitorDownmixPanelModel
        return settingsPanel(title: "Monitor Downmix", fillsHeight: true) {
            infoRow(title: "Signal", value: panel.signalText)
            infoRow(title: "Input", value: panel.inputText)
            infoRow(title: "Mapping", value: panel.mappingText)
            infoRow(title: "Render", value: panel.renderText)
            infoRow(title: "Rules", value: panel.rulesText)
            infoRow(title: "Output", value: panel.outputText)
            if let warning = panel.warningText {
                monitorDownmixWarningText(warning)
            }
        }
    }

    private var sonicSphereRenderPanel: some View {
        settingsPanel(title: "Sonic Sphere Render", fillsHeight: true) {
            infoRow(title: "Input", value: rendererInputChannelText)
            infoRow(title: "Layout", value: rendererSourceLayoutText)
            infoRow(title: "Matrix", value: model.rendererText)
            infoRow(title: "Output", value: model.rendererSelectionText)
            infoRow(title: "Inspect", value: model.rendererMatrixInspectionText)
        }
    }

    private var rendererModeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Always Mono", isOn: $model.rendererAlwaysMono)
                .toggleStyle(.switch)
                .tint(LabTheme.cyan)

            Picker("2-channel", selection: $model.rendererTwoChannelPreference) {
                ForEach(RendererTwoChannelPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            if let warning = model.rendererScene.validationMessages.last,
               model.rendererScene.renderMode != model.rendererScene.requestedRenderMode {
                Text(warning)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LabTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    private func rendererModeButtonLabel(for mode: RendererRenderMode) -> String {
        switch mode {
        case .auro111714h:
            "Auro 11.1"
        case .auro111515hT:
            "Auro 11.1 T"
        default:
            mode.displayName
        }
    }

    private var rendererPresetMenu: some View {
        Menu {
            ForEach(model.rendererPresets) { preset in
                Button(preset.name) {
                    model.selectRendererPreset(preset)
                }
            }
        } label: {
            HStack {
                Text(model.rendererPreset.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LabTheme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
        .buttonStyle(LabButtonStyle())
    }

    private var rendererPresetActions: some View {
        HStack(spacing: 8) {
            Button {
                model.saveRendererPreset()
            } label: {
                Label(model.rendererPresetIsDirty ? "Save Tuning" : "Save", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LabButtonStyle(isActive: model.rendererPresetIsDirty))

            Button {
                model.resetRendererTuning()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LabButtonStyle())
        }
    }

    private var rendererTuningControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            centeredTuningSlider(title: "Seam Support", value: $model.rendererSeamSupportGain, bounds: 0...1, defaultValue: FeyRendererOptions.default.seamSupportGain, format: "%.2f")
            centeredTuningSlider(title: "Upper Bias dB/Z", value: $model.rendererUpperBiasDbPerUnitZ, bounds: -3...4, defaultValue: FeyRendererOptions.default.upperBiasDbPerUnitZ, format: "%.1f")
            centeredTuningSlider(title: "Stereo Rear Fill", value: $model.rendererStereoRearFill, bounds: 0...0.35, defaultValue: FeyRendererOptions.default.stereoRearFill, format: "%.2f")
            centeredTuningSlider(title: "Center Side Support", value: $model.rendererCenterSideSupportGain, bounds: 0...0.7, defaultValue: FeyRendererOptions.default.centerSideSupportGain, format: "%.2f")
            centeredTuningSlider(title: "Adjacent Bleed", value: $model.rendererAdjacentBleed, bounds: 0...0.12, defaultValue: FeyRendererOptions.default.adjacentBleed, format: "%.2f")
            centeredTuningSlider(title: "Max Speaker Share", value: $model.rendererMaxSingleSpeakerPowerShare, bounds: 0.08...0.35, defaultValue: FeyRendererOptions.default.maxSingleSpeakerPowerShare, format: "%.2f")
            centeredTuningSlider(title: "Rendered Trim dB", value: $model.rendererRenderedOutputTrimDb, bounds: -12...0, defaultValue: FeyRendererOptions.default.renderedOutputTrimDb, format: "%.1f")
            centeredTuningSlider(title: "LFE Trim dB", value: $model.rendererLfeTrimDb, bounds: -12...6, defaultValue: FeyRendererOptions.default.lfeTrimDb, format: "%.1f")
            centeredTuningSlider(title: "Auro Lower Bias dB/Z", value: $model.rendererAuroLowerUpperBiasDbPerUnitZ, bounds: -3...4, defaultValue: FeyRendererOptions.default.defaultUpperBiasDbPerUnitZ, format: "%.1f")
            centeredTuningSlider(title: "Auro Height Bias dB/Z", value: $model.rendererAuroHeightUpperBiasDbPerUnitZ, bounds: -3...4, defaultValue: FeyRendererOptions.default.heightUpperBiasDbPerUnitZ, format: "%.1f")
            centeredTuningSlider(title: "Auro Height Max Share", value: $model.rendererAuroHeightMaxSingleSpeakerPowerShare, bounds: 0.08...0.35, defaultValue: FeyRendererOptions.default.heightMaxSingleSpeakerPowerShare, format: "%.2f")
            centeredTuningSlider(title: "Auro Top Max Share", value: $model.rendererAuroTopMaxSingleSpeakerPowerShare, bounds: 0.08...0.35, defaultValue: FeyRendererOptions.default.topMaxSingleSpeakerPowerShare, format: "%.2f")
        }
    }

    private var rendererInputChannelText: String {
        if let metadata = model.visibleLocalSourceMetadata {
            return "\(metadata.channelCount)"
        }

        let count = model.rendererScene.matrix.inputCount
        return count > 0 ? "\(count)" : "No source loaded"
    }

    private var rendererSourceLayoutText: String {
        if let metadata = model.visibleLocalSourceMetadata {
            return LocalFilePlayerRowsModel.layoutText(
                count: metadata.channelCount,
                layoutName: metadata.layoutName,
                formatNote: metadata.formatNote
            )
        }

        return model.rendererScene.renderMode.displayName
    }

    private var rendererAtmosNoteText: String? {
        guard let metadata = model.visibleLocalSourceMetadata else { return nil }
        return LocalFilePlayerRowsModel.rendererAtmosNote(metadata.formatNote)
    }

    private var headerCard: some View {
        card {
            Text("Orbisonic")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryTransportTitle: String {
        if model.sourceMode == .testTone {
            return model.isTestTonePlaying ? "Stop Tone" : "Play Tone"
        }
        if model.sourceMode == .atmosDRP {
            return model.dolbyReferencePlayerSnapshot.state == .paused ? "Resume" : (model.isPlaying ? "Pause" : "Play")
        }
        if model.sourceMode.isLiveInput {
            return livePrimaryTitle
        }
        return model.isPlaying ? "Pause" : "Play"
    }

    private var primaryTransportIcon: String {
        if model.sourceMode == .atmosDRP {
            return model.isPlaying ? "pause.fill" : "play.fill"
        }
        if model.sourceMode.isLiveInput {
            return livePrimaryIcon
        }
        return model.isPlaying ? "pause.fill" : "play.fill"
    }

    private var secondaryTransportTitle: String {
        "Stop"
    }

    private var statusChipText: String {
        if model.sourceMode == .filePlayback, model.isLocalFileLoading {
            return localPlaybackStatusText
        }
        if model.isDiagnosticTransitioning {
            return "Settling"
        }
        if model.sourceMode == .roon, model.isRoonTransportCommandInFlight {
            return roonPlaybackStatusText
        }
        if model.isLiveMonitorTransitioning {
            return compactTransitionStatus(model.sourceSwitchStatusText)
        }
        if model.sourceMode == .off {
            return "Idle"
        }
        if model.sourceMode == .atmosDRP {
            return atmosDRPStatusText
        }
        if model.sourceMode.isLiveInput {
            switch model.sourceMode {
            case .roon:
                return roonPlaybackStatusText
            case .spotify:
                return spotifyPlaybackStatusText
            case .aux:
                return "Aux live"
            case .atmosDRP:
                return atmosDRPStatusText
            case .off, .filePlayback, .testTone:
                return "Idle"
            }
        }
        if model.sourceMode == .testTone {
            return model.isTestTonePlaying ? "Tone playing" : "Tone ready"
        }
        if model.sourceMode == .filePlayback {
            return localPlaybackStatusText
        }
        return "Ready"
    }

    private var localPlaybackStatusText: String {
        if model.isLocalFileLoading {
            return condensedLocalLoadingStatus(model.statusMessage)
        }
        if model.isPlaying {
            return "Local playing"
        }
        if model.statusMessage.localizedCaseInsensitiveContains("paused") {
            return "Local paused"
        }
        return "Local ready"
    }

    private func condensedLocalLoadingStatus(_ status: String) -> String {
        if status.hasPrefix("Starting playback") {
            return "Starting"
        }
        if status.hasPrefix("Loading") {
            return "Loading"
        }
        if status.hasPrefix("Still loading") {
            return "Still loading"
        }
        return "Loading"
    }

    private func compactTransitionStatus(_ status: String?) -> String {
        guard let status else {
            return "Stopping"
        }
        if status.localizedCaseInsensitiveContains("stopping") {
            return "Stopping"
        }
        if let targetMode = model.sourceSwitchTargetMode {
            return "Switching to \(targetMode.displayName)"
        }
        if status.localizedCaseInsensitiveContains("switching") {
            return "Switching"
        }
        return status
    }

    private var roonPlaybackStatusText: String {
        let state = model.roonBridgeSnapshot.selectedZone?.state.lowercased() ??
            model.roonNowPlaying?.state.lowercased()
        guard let state else {
            return model.liveAudioSignalState.isRecentlyReceiving || model.liveMonitorState == .monitoring
                ? "Roon playing"
                : roonWaitingStatusText
        }
        switch state {
        case "playing", "loading":
            if model.liveAudioSignalState.isRecentlyReceiving || model.liveMonitorState == .monitoring {
                return "Roon playing"
            }
            if model.liveAudioSignalState == .noSignal || model.liveMonitorState == .silent {
                return "No Roon audio"
            }
            return "Waiting for Roon audio"
        case "paused":
            return "Roon paused"
        default:
            return roonWaitingStatusText
        }
    }

    private var roonWaitingStatusText: String {
        if model.liveAudioSignalState == .noSignal || model.liveMonitorState == .silent {
            return "No Roon audio"
        }
        return "Waiting for Roon"
    }

    private var spotifyPlaybackStatusText: String {
        guard model.spotifyReceiverStatus.isRunning else {
            return isSpotifyReceiverUnavailable ? "Spotify unavailable" : "Waiting for Spotify"
        }
        if model.liveAudioSignalState.isRecentlyReceiving ||
            model.liveMonitorState == .monitoring ||
            model.spotifyNowPlayingForActiveStatus?.isPlaying == true {
            return "Spotify playing"
        }
        return model.spotifyNowPlayingForActiveStatus == nil ? "No Spotify track" : "Spotify paused"
    }

    private var atmosDRPStatusText: String {
        switch model.dolbyReferencePlayerSnapshot.state {
        case .starting:
            return "Atmos starting"
        case .playing:
            return "Atmos playing"
        case .paused:
            return "Atmos paused"
        case .stopping:
            return "Atmos stopping"
        case .failed:
            return "Atmos failed"
        case .idle, .stopped:
            return "Atmos ready"
        }
    }

    private var statusChipForegroundColor: Color {
        if statusChipIsActive {
            return LabTheme.bg
        }
        return statusChipIsError ? LabTheme.red : LabTheme.textSoft
    }

    private var statusChipFillColor: Color {
        statusChipIsActive ? LabTheme.green : LabTheme.panelSoft
    }

    private var statusChipStrokeColor: Color {
        if statusChipIsActive {
            return LabTheme.green.opacity(0.55)
        }
        return statusChipIsError ? LabTheme.red.opacity(0.68) : LabTheme.line
    }

    private var statusChipIsError: Bool {
        if model.sourceMode == .atmosDRP,
           model.dolbyReferencePlayerSnapshot.state == .failed {
            return true
        }
        if model.sourceMode.isLiveInput, isSelectedLiveSourceUnavailable {
            return true
        }
        return model.sourceMode == .spotify && isSpotifyReceiverUnavailable
    }

    private var statusChipIsActive: Bool {
        if model.sourceMode == .filePlayback, model.isLocalFileLoading {
            return true
        }
        if transportIsBusy {
            return true
        }
        if model.sourceMode == .roon {
            return model.liveAudioSignalState.isRecentlyReceiving ||
                model.liveMonitorState == .monitoring
        }
        if model.sourceMode == .spotify {
            return model.liveAudioSignalState.isRecentlyReceiving ||
                model.liveMonitorState == .monitoring ||
                model.spotifyNowPlayingForActiveStatus?.isPlaying == true
        }
        if model.sourceMode == .aux {
            return model.liveAudioSignalState.isRecentlyReceiving || model.liveMonitorState == .monitoring
        }
        if model.sourceMode == .atmosDRP {
            return model.dolbyReferencePlayerSnapshot.state == .playing ||
                model.liveAudioSignalState.isRecentlyReceiving ||
                model.liveMonitorState == .monitoring
        }
        return model.isPlaying || model.isTestTonePlaying
    }

    private var statusChipIsLoading: Bool {
        (model.sourceMode == .filePlayback && model.isLocalFileLoading) ||
            (model.sourceMode == .atmosDRP && model.dolbyReferencePlayerSnapshot.state == .starting)
    }

    private var transportIsBusy: Bool {
        model.isDiagnosticTransitioning ||
            (model.sourceMode == .roon && model.isRoonTransportCommandInFlight) ||
            (model.sourceMode == .atmosDRP && [.starting, .stopping].contains(model.dolbyReferencePlayerSnapshot.state)) ||
            model.isLiveMonitorTransitioning
    }

    private var livePrimaryTitle: String {
        if model.liveMonitorState.isMuted {
            return "Resume"
        }
        if model.liveMonitorState.isCapturing {
            return "Mute"
        }
        return "Listen"
    }

    private var livePrimaryIcon: String {
        if model.liveMonitorState.isMuted {
            return "speaker.wave.2.fill"
        }
        if model.liveMonitorState.isCapturing {
            return "speaker.slash.fill"
        }
        return "waveform.path.ecg"
    }

    private func livePrimaryAction() {
        if model.liveMonitorState.isMuted {
            model.resumeLiveMonitor()
        } else if model.liveMonitorState.isCapturing {
            model.muteLiveMonitor()
        } else {
            model.startSelectedLiveMonitor()
        }
    }

    private var nowPlayingTitle: String {
        switch model.sourceMode {
        case .off:
            return "Off"
        case .roon:
            if let title = model.roonTransportTitleText, !title.isEmpty {
                return title
            }
            if let nowPlaying = model.roonNowPlaying {
                return nowPlaying.title
            }
            return "Roon"
        case .testTone:
            return model.selectedTestTonePoint.rawValue
        case .aux:
            return "Aux Cable"
        case .atmosDRP:
            return model.currentAtmosDRPTrack?.displayTitle ?? model.visibleLocalPlaybackTrack?.displayTitle ?? "Atmos"
        case .spotify:
            return model.spotifyNowPlayingForActiveStatus?.displayTitle ?? "Spotify"
        case .filePlayback:
            if let track = model.visibleLocalPlaybackTrack {
                return track.displayTitle
            }
            if let metadata = model.visibleLocalSourceMetadata {
                return metadata.fileName
            }
            return "No source loaded"
        }
    }

    private var nowPlayingSubtitle: String {
        switch model.sourceMode {
        case .off:
            return "Orbisonic is idle"
        case .roon:
            if let subtitle = model.roonTransportSubtitleText, !subtitle.isEmpty {
                return subtitle
            }
            if let nowPlaying = model.roonNowPlaying {
                return nowPlaying.artist.isEmpty ? "Roon" : nowPlaying.artist
            }
            return "Controlled from Roon."
        case .testTone:
            return model.testToneStatus.isEmpty ? "Test Tone" : model.testToneStatus
        case .aux:
            return "Controlled in the source app."
        case .atmosDRP:
            if let track = model.currentAtmosDRPTrack ?? model.visibleLocalPlaybackTrack {
                return track.displaySubtitle
            }
            return "Dolby Reference Player through \(AtmosDRPRoutingPolicy.captureLoopback.displayName)."
        case .spotify:
            return model.spotifyNowPlayingForActiveStatus?.artistText ?? "Controlled from Spotify Connect."
        case .filePlayback:
            if let track = model.visibleLocalPlaybackTrack {
                return track.displaySubtitle
            }
            if let metadata = model.visibleLocalSourceMetadata {
                return "\(metadata.layoutName) • \(metadata.channelCount) ch • \(metadata.sampleRateText)"
            }
            return "Choose Roon, Spotify, Atmos, Aux Cable, or Local Music."
        }
    }

    private var nowPlayingArtworkURL: URL? {
        switch model.sourceMode {
        case .roon:
            model.roonArtworkURL
        case .spotify:
            model.spotifyArtworkURL
        case .filePlayback:
            model.currentLocalArtworkURL
        case .atmosDRP:
            model.currentLocalArtworkURL
        case .off, .aux, .testTone:
            nil
        }
    }

    private var nowPlayingSessionCard: some View {
        playerRailCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Player")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(LabTheme.text)
                    Spacer()
                    Text(statusChipText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusChipForegroundColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: 154, height: 22)
                        .background(
                            StatusChipBackground(
                                fillColor: statusChipFillColor,
                                strokeColor: statusChipStrokeColor,
                                isLoading: statusChipIsLoading
                            )
                        )
                }

                nowPlayingMediaBlock

                playerTransportControls

                sphereVolumeControl

                playerProgressControl

                Divider()
                    .overlay(Color.white.opacity(0.08))

                playerDetailContent

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var nowPlayingMediaBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayerArtworkView(url: nowPlayingArtworkURL)
                .padding(6)
                .frame(maxWidth: .infinity, minHeight: PlayerRailLayout.artworkSize, maxHeight: PlayerRailLayout.artworkSize)
                .background(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .fill(Color.black.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                                .stroke(LabTheme.line, lineWidth: 1)
                        )
                )
                .accessibilityHidden(nowPlayingArtworkURL == nil)

            VStack(alignment: .leading, spacing: 4) {
                Text(nowPlayingTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                Text(nowPlayingSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if let badge = model.pureSphericalLosslessBadgePresentation {
                    pureSphericalLosslessBadge(badge)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(Color.black.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line.opacity(0.72), lineWidth: 1)
                )
        )
        .contextMenu {
            if let track = model.visibleLocalPlaybackTrack {
                addToPlaylistMenu(for: track)
            }
        }
    }

    private func pureSphericalLosslessBadge(_ presentation: PureSphericalLosslessBadgePresentation) -> some View {
        Text(presentation.text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(LabTheme.bg)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .padding(.horizontal, 8)
            .frame(minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                    .fill(LabTheme.cyan)
            )
            .accessibilityLabel(Text(presentation.text))
    }

    private var playerTransportControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(PlayerTransportKind.allCases) { kind in
                    Button(action: { performPlayerTransport(kind) }) {
                        Label(kind.title, systemImage: kind.systemImage)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LabButtonStyle(isActive: playerTransportIsActive(kind)))
                    .disabled(playerTransportIsDisabled(kind))
                    .help(kind.title)
                }
            }

            if model.sourceMode == .spotify {
                Text("Control player from Spotify app.")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func performPlayerTransport(_ kind: PlayerTransportKind) {
        switch kind {
        case .back:
            if model.sourceMode == .roon {
                model.playPreviousRoonTrack()
            } else if model.sourceMode == .atmosDRP {
                model.skipAtmosDRPTransport(offset: -1)
            } else if model.sourceMode == .filePlayback {
                model.skipLocalTransport(offset: -1)
            }
        case .play:
            if model.sourceMode == .roon {
                model.playRoonTransport()
            } else if model.sourceMode == .atmosDRP {
                model.playAtmosDRPTransport()
            } else if model.sourceMode == .filePlayback {
                model.playLocalTransport()
            } else if model.sourceMode == .testTone {
                model.playSelectedTestTone()
            }
        case .pause:
            if model.sourceMode == .roon {
                model.pauseRoonTransport()
            } else if model.sourceMode == .atmosDRP {
                model.pauseAtmosDRPTransport()
            } else if model.sourceMode == .filePlayback {
                model.pauseLocalTransport()
            }
        case .forward:
            if model.sourceMode == .roon {
                model.playNextRoonTrack()
            } else if model.sourceMode == .atmosDRP {
                model.skipAtmosDRPTransport(offset: 1)
            } else if model.sourceMode == .filePlayback {
                model.skipLocalTransport(offset: 1)
            }
        case .stop:
            if model.sourceMode == .roon {
                model.stopRoonTransport()
            } else if model.sourceMode == .atmosDRP {
                model.stopAtmosDRPTransport()
            } else if model.sourceMode == .filePlayback {
                model.stopLocalTransport()
            } else if model.sourceMode == .testTone {
                model.stop()
            }
        }
    }

    private func playerTransportIsActive(_ kind: PlayerTransportKind) -> Bool {
        switch kind {
        case .play:
            switch model.sourceMode {
            case .roon:
                return model.isRoonTransportPlaying
            case .filePlayback:
                return model.isPlaying
            case .atmosDRP:
                return model.dolbyReferencePlayerSnapshot.state == .playing
            case .testTone:
                return model.isTestTonePlaying
            case .off, .spotify, .aux:
                return false
            }
        default:
            return false
        }
    }

    private func playerTransportIsDisabled(_ kind: PlayerTransportKind) -> Bool {
        if transportIsBusy {
            return true
        }

        switch model.sourceMode {
        case .off, .aux:
            return true
        case .atmosDRP:
            let hasPlayableAtmosSource = model.currentAtmosDRPTrack != nil ||
                model.visibleLocalMusicTracks.contains { DolbyReferencePlayerController.supportsFile($0.url) }
            switch kind {
            case .back, .forward:
                return !hasPlayableAtmosSource
            case .play:
                return !hasPlayableAtmosSource || model.dolbyReferencePlayerSnapshot.state == .playing
            case .pause:
                return model.dolbyReferencePlayerSnapshot.state != .playing
            case .stop:
                return ![.starting, .playing, .paused, .stopping].contains(model.dolbyReferencePlayerSnapshot.state)
            }
        case .roon:
            switch kind {
            case .back:
                return !model.canSendRoonTransport(.previous)
            case .play:
                return !model.canSendRoonTransport(.play)
            case .pause:
                return !model.canSendRoonTransport(.pause)
            case .forward:
                return !model.canSendRoonTransport(.next)
            case .stop:
                return !model.canSendRoonTransport(.stop)
            }
        case .spotify:
            return true
        case .filePlayback:
            let hasPlayableLocalSource = model.visibleLocalSourceMetadata != nil || !model.localMusicTracks.isEmpty
            switch kind {
            case .back, .forward:
                return model.sessionQueue.isEmpty && model.localMusicTracks.isEmpty
            case .play:
                return !hasPlayableLocalSource || model.isPlaying || model.isLocalFileLoading
            case .pause:
                return !model.isPlaying && !model.isLocalFileLoading
            case .stop:
                return !hasPlayableLocalSource && !model.isLocalFileLoading
            }
        case .testTone:
            switch kind {
            case .play:
                return model.isTestTonePlaying
            case .stop:
                return !model.isTestTonePlaying
            case .back, .pause, .forward:
                return true
            }
        }
    }

    private var sphereVolumeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Volume")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                Spacer()
                Text(model.sphereOutputVolumeText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LabTheme.cyan)
            }

            OrbisonicLinearControl(value: $model.sphereOutputVolumePercent, range: 0...100)
                .help("Rendered Sonic Sphere output volume, capped by the renderer safety limit")
        }
    }

    private var playerProgressControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(playerProgressLeadingText)
                Spacer()
                Text(playerProgressTrailingText)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(LabTheme.textSoft)

            OrbisonicLinearControl(
                value: playerProgressBinding,
                range: 0...1,
                onEditingChanged: isPlayerProgressEditable ? model.scrubEditingChanged : { _ in }
            )
                .disabled(!isPlayerProgressEditable)
        }
    }

    private var isPlayerProgressEditable: Bool {
        model.sourceMode == .filePlayback && model.visibleLocalSourceMetadata != nil
    }

    private var playerProgressBinding: Binding<Double> {
        isPlayerProgressEditable ? $model.scrubProgress : .constant(playerDisplayProgress)
    }

    private var playerDisplayProgress: Double {
        switch model.sourceMode {
        case .roon:
            guard let nowPlaying = model.roonBridgeSnapshot.selectedZone?.nowPlaying,
                  let position = nowPlaying.seekPosition,
                  let length = nowPlaying.length,
                  length > 0
            else { return 0 }
            return min(max(position / length, 0), 1)
        case .spotify:
            guard let position = model.spotifyNowPlayingForActiveStatus?.positionMs,
                  let duration = model.spotifyNowPlayingForActiveStatus?.durationMs,
                  duration > 0
            else { return 0 }
            return min(max(Double(position) / Double(duration), 0), 1)
        case .atmosDRP:
            return min(max(model.scrubProgress, 0), 1)
        case .filePlayback:
            return min(max(model.scrubProgress, 0), 1)
        case .off, .aux, .testTone:
            return 0
        }
    }

    private var playerProgressLeadingText: String {
        switch model.sourceMode {
        case .roon:
            return timeText(seconds: model.roonBridgeSnapshot.selectedZone?.nowPlaying?.seekPosition)
        case .spotify:
            return model.spotifyNowPlayingForActiveStatus?.positionText ?? "0:00"
        case .filePlayback:
            return model.visibleLocalSourceMetadata == nil ? "0:00" : model.formattedCurrentTime()
        case .atmosDRP:
            return model.currentAtmosDRPTrack == nil ? "DRP elapsed" : model.formattedCurrentTime()
        case .off:
            return "0:00"
        case .aux:
            return "Live input"
        case .testTone:
            return "Tone"
        }
    }

    private var playerProgressTrailingText: String {
        switch model.sourceMode {
        case .roon:
            return timeText(seconds: model.roonBridgeSnapshot.selectedZone?.nowPlaying?.length)
        case .spotify:
            return model.spotifyNowPlayingForActiveStatus?.durationText ?? "0:00"
        case .filePlayback:
            return model.visibleLocalSourceMetadata == nil ? "0:00" : model.formattedDuration()
        case .atmosDRP:
            return model.currentAtmosDRPTrack == nil ? "0:00" : model.formattedDuration()
        case .off, .aux, .testTone:
            return "0:00"
        }
    }

    private func timeText(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return "0:00"
        }

        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func formatSampleRate(_ sampleRate: Double) -> String {
        guard sampleRate > 0 else {
            return "unknown rate"
        }

        let kilohertz = sampleRate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return "\(Int(kilohertz.rounded())) kHz"
        }

        return String(format: "%.1f kHz", kilohertz)
    }

    @ViewBuilder
    private var playerDetailContent: some View {
        let rows = playerDetailRows
        if rows.isEmpty {
            Text(playerDetailPlaceholder)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LabTheme.textSoft)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(height: PlayerRailLayout.detailContentHeight, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    if row.hasTopDivider {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.vertical, 2)
                    }
                    playerDetailRowView(row)
                }
                Spacer(minLength: 0)
            }
            .frame(height: PlayerRailLayout.detailContentHeight, alignment: .topLeading)
            .clipped()
        }
    }

    private var playerDetailRows: [PlayerDetailRow] {
        switch model.sourceMode {
        case .off:
            return []
        case .roon:
            return roonPlayerRows
        case .spotify:
            return spotifyPlayerRows
        case .aux:
            return auxPlayerRows
        case .atmosDRP:
            return atmosDRPPlayerRows
        case .filePlayback:
            return nonEmptyPlayerRows(localFilePlayerRows)
        case .testTone:
            return testTonePlayerRows
        }
    }

    private var roonPlayerRows: [PlayerDetailRow] {
        var rows: [PlayerDetailRow] = []

        rows.append(contentsOf: RoonPlayerRowsModel.rows(
            nowPlaying: model.roonNowPlaying,
            signalPath: model.roonSignalPath
        ).map(playerDetailRow))

        if let errorText = liveInputPlaybackErrorText {
            rows.append(PlayerDetailRow(title: "Error", value: errorText, hasTopDivider: !rows.isEmpty))
        }

        return nonEmptyPlayerRows(rows)
    }

    private var spotifyPlayerRows: [PlayerDetailRow] {
        var rows: [PlayerDetailRow] = []
        rows.append(PlayerDetailRow(title: "Format", value: "Spotify Connect 320 kbps"))
        rows.append(PlayerDetailRow(title: "Channels", value: "2 stereo"))
        rows.append(PlayerDetailRow(title: "Length", value: model.spotifyNowPlayingForActiveStatus?.durationText ?? "-"))
        if let errorText = liveInputPlaybackErrorText {
            rows.append(PlayerDetailRow(title: "Error", value: errorText, hasTopDivider: true))
        }
        return nonEmptyPlayerRows(rows)
    }

    private var auxPlayerRows: [PlayerDetailRow] {
        var rows: [PlayerDetailRow] = []
        rows.append(PlayerDetailRow(title: "Input", value: "Aux Cable"))
        rows.append(PlayerDetailRow(title: "Audio signal", value: liveSignalShortText))
        if let errorText = liveInputPlaybackErrorText {
            rows.append(PlayerDetailRow(title: "Error", value: errorText, hasTopDivider: true))
        }
        return nonEmptyPlayerRows(rows)
    }

    private var atmosDRPPlayerRows: [PlayerDetailRow] {
        var rows: [PlayerDetailRow] = []
        rows.append(PlayerDetailRow(title: "Player", value: "Dolby Reference Player"))
        rows.append(PlayerDetailRow(title: "Route", value: "\(AtmosDRPRoutingPolicy.captureLoopback.displayName) loopback"))
        rows.append(PlayerDetailRow(title: "Layout", value: model.atmosDRPOutputLayout.rawValue))
        rows.append(PlayerDetailRow(title: "Process", value: atmosDRPStatusText))

        if let track = model.currentAtmosDRPTrack ?? model.visibleLocalPlaybackTrack {
            rows.append(PlayerDetailRow(title: "Track", value: track.fileName, hasTopDivider: true))
            rows.append(PlayerDetailRow(title: "Length", value: track.durationText))
        }

        if let bitstream = model.dolbyReferencePlayerSnapshot.bitstreamInfo {
            if let value = bitstream.codec {
                rows.append(PlayerDetailRow(title: "Codec", value: value, hasTopDivider: true))
            }
            if let value = bitstream.hasAtmos {
                rows.append(PlayerDetailRow(title: "Atmos", value: value ? "Yes" : "No"))
            }
            if let value = bitstream.bitRateKbps {
                rows.append(PlayerDetailRow(title: "Data rate", value: "\(value) kbps"))
            }
            if let value = bitstream.codedChannels {
                rows.append(PlayerDetailRow(title: "Coded ch", value: value))
            }
            if let value = bitstream.sampleRateHz {
                rows.append(PlayerDetailRow(title: "Sample rate", value: formatSampleRate(Double(value))))
            }
            if let value = bitstream.dynamicObjectCount {
                rows.append(PlayerDetailRow(title: "Objects", value: "\(value) dynamic"))
            }
            if let value = bitstream.complexityIndex {
                rows.append(PlayerDetailRow(title: "Complexity", value: "\(value)"))
            }
        }

        if let errorText = model.dolbyReferencePlayerSnapshot.lastError?.trimmedNilIfBlank ?? liveInputPlaybackErrorText {
            rows.append(PlayerDetailRow(title: "Error", value: errorText, hasTopDivider: true))
        }

        return nonEmptyPlayerRows(rows)
    }

    private var localFilePlayerRows: [PlayerDetailRow] {
        var rows: [PlayerDetailRow] = []

        if let metadata = model.visibleLocalSourceMetadata {
            rows.append(contentsOf: LocalFilePlayerRowsModel.rows(metadata: metadata).map(playerDetailRow))
            return rows
        }

        if let track = model.visibleLocalPlaybackTrack {
            rows.append(contentsOf: LocalFilePlayerRowsModel.rows(track: track).map(playerDetailRow))
            return rows
        }

        return rows
    }

    private func playerDetailRow(_ row: PlayerDetailRowContent) -> PlayerDetailRow {
        PlayerDetailRow(title: row.title, value: row.value, hasTopDivider: row.hasTopDivider)
    }

    private var testTonePlayerRows: [PlayerDetailRow] {
        guard model.activeDiagnosticText != "Ready." || model.isTestTonePlaying else {
            return []
        }

        return [PlayerDetailRow(title: "Tone", value: model.activeDiagnosticText)]
    }

    private var playerDetailPlaceholder: String {
        switch model.sourceMode {
        case .off:
            "Orbisonic is idle."
        case .filePlayback:
            "Load a surround mix to see file metadata here."
        case .roon:
            "Waiting for Roon metadata."
        case .spotify:
            "Waiting for Spotify metadata."
        case .aux:
            "Waiting for Aux Cable audio."
        case .atmosDRP:
            "Select a DRP-compatible Local Music track and press play. Seek is unavailable because DRP CLI does not expose seek."
        case .testTone:
            "Use Diagnostics to run a tone or channel walk."
        }
    }

    private func playerDetailRowView(_ row: PlayerDetailRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: PlayerRailLayout.detailLabelWidth, height: PlayerRailLayout.detailRowHeight, alignment: .leading)

            Text(row.value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: PlayerRailLayout.detailRowHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nonEmptyPlayerRows(_ rows: [PlayerDetailRow]) -> [PlayerDetailRow] {
        let filtered = rows.filter { row in
            guard let value = row.value.trimmedNilIfBlank else { return false }
            return value != "-"
        }
        return Array(filtered.prefix(PlayerRailLayout.detailRowLimit))
    }

    private var liveInputPlaybackErrorText: String? {
        switch model.liveMonitorState {
        case .unavailable(let message), .error(let message):
            return message.trimmedNilIfBlank
        case .stopped, .monitoring, .muted, .silent:
            return nil
        }
    }

    private var liveSignalShortText: String {
        switch model.liveAudioSignalState {
        case .receiving:
            return "Receiving"
        case .briefSilence:
            return "Brief silence"
        case .silentPassage:
            return "Paused or silent"
        case .noSignal:
            return "No signal"
        case .unknown:
            return model.liveMonitorState == .monitoring ? "Receiving" : "Waiting"
        }
    }

    private func primaryNowPlayingAction() {
        if model.sourceMode == .atmosDRP {
            if model.dolbyReferencePlayerSnapshot.state == .playing {
                model.pauseAtmosDRPTransport()
            } else {
                model.playAtmosDRPTransport()
            }
        } else if model.sourceMode.isLiveInput {
            livePrimaryAction()
        } else if model.sourceMode == .filePlayback, !model.localMusicTracks.isEmpty {
            model.toggleLocalMusicPlayback()
        } else {
            model.togglePlayback()
        }
    }

    private func secondaryNowPlayingAction() {
        if model.sourceMode == .atmosDRP {
            model.stopAtmosDRPTransport()
        } else if model.sourceMode.isLiveInput {
            model.stopSelectedLiveMonitor()
        } else if model.sourceMode == .filePlayback {
            model.stopLocalTransport()
        } else {
            model.stop()
        }
    }

    private var localMusicNowPlayingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: model.playPreviousLocalMusicTrack) {
                    Label("Back", systemImage: "backward.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LabButtonStyle())

                Button(action: model.playNextLocalMusicTrack) {
                    Label("Next", systemImage: "forward.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LabButtonStyle())
            }
        }
        .disabled(model.localMusicTracks.isEmpty)
    }

    private var roonTransportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                roonTransportButton(
                    systemImage: "backward.fill",
                    help: "Previous in Roon",
                    control: .previous,
                    action: model.playPreviousRoonTrack
                )

                roonTransportButton(
                    systemImage: model.isRoonTransportPlaying ? "pause.fill" : "play.fill",
                    help: model.isRoonTransportPlaying ? "Pause Roon" : "Play Roon",
                    control: model.isRoonTransportPlaying ? .pause : .play,
                    isActive: model.isRoonTransportPlaying,
                    action: model.toggleRoonTransport
                )

                roonTransportButton(
                    systemImage: "stop.fill",
                    help: "Stop Roon",
                    control: .stop,
                    action: model.stopRoonTransport
                )

                roonTransportButton(
                    systemImage: "forward.fill",
                    help: "Next in Roon",
                    control: .next,
                    action: model.playNextRoonTrack
                )
            }

            Text(model.roonTransportCompactStatusText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(model.roonBridgeSnapshot.isReadyForTransport ? LabTheme.cyan : LabTheme.textSoft)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
        }
    }

    private var spotifyTransportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                spotifyTransportButton(systemImage: "backward.fill", help: "Previous in Spotify", action: model.playPreviousSpotifyTrack)
                spotifyTransportButton(
                    systemImage: (model.spotifyNowPlayingForActiveStatus?.isPlaying ?? false) ? "pause.fill" : "play.fill",
                    help: (model.spotifyNowPlayingForActiveStatus?.isPlaying ?? false) ? "Pause Spotify" : "Play Spotify",
                    action: model.toggleSpotifyTransport
                )
                spotifyTransportButton(systemImage: "forward.fill", help: "Next in Spotify", action: model.playNextSpotifyTrack)
            }

            Text("Control player from Spotify app.")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var spotifyCompactStatusText: String {
        var parts: [String] = []
        if let nowPlaying = model.spotifyNowPlayingForActiveStatus {
            if nowPlaying.positionText != "-" || nowPlaying.durationText != "-" {
                parts.append("\(nowPlaying.positionText) / \(nowPlaying.durationText)")
            }
        }
        if parts.isEmpty {
            parts.append(model.spotifySetupStatusForPrimaryUI)
        }
        return parts.joined(separator: " • ")
    }

    private func spotifyTransportButton(
        systemImage: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(LabButtonStyle(isActive: isActive))
        .disabled(true)
        .help(help)
    }

    private func roonTransportButton(
        systemImage: String,
        help: String,
        control: RoonBridgeControl,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(LabButtonStyle(isActive: isActive))
        .disabled(model.isRoonTransportCommandInFlight || !model.canSendRoonTransport(control))
        .help(help)
    }

    private var localMusicTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            localMusicPanelSelector

            localMusicPanelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var localMusicPanelSelector: some View {
        HStack(spacing: 4) {
            ForEach(LocalMusicPanel.allCases) { panel in
                Button {
                    selectedLocalMusicPanel = panel
                } label: {
                    Text(panel.rawValue)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LabButtonStyle(isActive: selectedLocalMusicPanel == panel))
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var localMusicPanelContent: some View {
        switch selectedLocalMusicPanel {
        case .music:
            localMusicAllTracksPanel
        case .playlists:
            localMusicPlaylistsPanel
        case .queue:
            localMusicQueuePanel
        }
    }

    private var localMusicAllTracksPanel: some View {
        settingsPanel(title: "Music", fillsHeight: true) {
            localMusicSearchSortBar
            infoRow(title: "Tracks", value: model.localMusicCountText)
            localMusicTrackList(model.visibleLocalMusicTracks)
        }
    }

    private var localMusicPlaylistsPanel: some View {
        settingsPanel(title: "Playlists", fillsHeight: true) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: { beginCreatePlaylist() }) {
                        Label("New Playlist", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LabButtonStyle(isActive: true))

                    infoRow(title: "Playlists", value: model.localMusicPlaylistCountText)

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(model.localMusicPlaylists.enumerated()), id: \.element.id) { _, playlist in
                                let isEditable = model.isEditableLocalMusicPlaylist(playlist)
                                Button {
                                    model.selectedLocalMusicPlaylistID = playlist.id
                                } label: {
                                    playlistLibraryRow(
                                        playlist,
                                        trackCount: playlist.trackPaths.count,
                                        isSelected: model.selectedLocalMusicPlaylistID == playlist.id,
                                        isEditable: isEditable
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Play Playlist") {
                                        model.playLocalMusicPlaylist(playlist, shuffle: false)
                                    }
                                    Button("Queue Playlist") {
                                        model.addLocalMusicPlaylistToQueue(playlist, shuffle: false)
                                    }
                                    Divider()
                                    Button("Move Up") {
                                        model.moveLocalMusicPlaylistUp(playlist)
                                    }
                                    .disabled(!model.canMoveLocalMusicPlaylistUp(playlist))
                                    Button("Move Down") {
                                        model.moveLocalMusicPlaylistDown(playlist)
                                    }
                                    .disabled(!model.canMoveLocalMusicPlaylistDown(playlist))
                                    if isEditable {
                                        Divider()
                                        Button("Rename Playlist") {
                                            beginRenamePlaylist(playlist)
                                        }
                                    }
                                    Button(isEditable ? "Delete Playlist" : "Remove Playlist", role: .destructive) {
                                        beginDeletePlaylist(playlist)
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(localMusicListBackground)
                }
                .frame(width: 278)

                localMusicSelectedPlaylistPanel
                    .frame(maxWidth: .infinity)
                }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var localMusicSelectedPlaylistPanel: some View {
        if let playlist = model.selectedLocalMusicPlaylist {
            let isEditable = model.isEditableLocalMusicPlaylist(playlist)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: { model.playLocalMusicPlaylist(playlist, shuffle: false) }) {
                        Label("Play Playlist", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LabButtonStyle(isActive: true))
                    .disabled(playlist.trackPaths.isEmpty)

                    Button(action: { model.addLocalMusicPlaylistToQueue(playlist, shuffle: false) }) {
                        Label("Queue Playlist", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LabButtonStyle())
                    .disabled(playlist.trackPaths.isEmpty)

                    Button(action: { beginRenamePlaylist(playlist) }) {
                        Label("Rename", systemImage: "pencil")
                            .frame(width: 104)
                    }
                    .buttonStyle(LabButtonStyle())
                    .disabled(!isEditable)

                    Button(action: { beginDeletePlaylist(playlist) }) {
                        Label(isEditable ? "Delete" : "Remove", systemImage: "trash")
                            .frame(width: 104)
                    }
                    .buttonStyle(LabButtonStyle())
                }

                infoRow(
                    title: playlist.name,
                    value: "\(playlist.trackPaths.count) track\(playlist.trackPaths.count == 1 ? "" : "s") • \(isEditable ? "Editable" : "Read-only")"
                )

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(playlist.trackPaths.enumerated()), id: \.offset) { index, path in
                            playlistTrackRow(
                                track: model.localMusicTracks.first { $0.path == path },
                                path: path,
                                playlist: playlist,
                                index: index,
                                trackCount: playlist.trackPaths.count,
                                isEditable: isEditable
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(localMusicListBackground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                infoRow(title: "Selected Playlist", value: "Choose a playlist.")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var localMusicQueuePanel: some View {
        settingsPanel(title: "Session Queue", fillsHeight: true) {
            HStack {
                Spacer(minLength: 0)

                Button(action: model.clearSessionQueue) {
                    Label("Clear Queue", systemImage: "trash")
                        .frame(width: 112)
                }
                .buttonStyle(LabButtonStyle())
                .disabled(model.sessionQueue.isEmpty)

                Button(action: beginSaveSessionQueuePlaylist) {
                    Label("Save Queue as Playlist", systemImage: "square.and.arrow.down")
                        .frame(width: 176)
                }
                .buttonStyle(LabButtonStyle(isActive: true))
                .disabled(model.sessionQueue.isEmpty)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.sessionQueue.enumerated()), id: \.offset) { index, track in
                        queueTrackRow(
                            track,
                            index: index,
                            isCurrent: model.sessionQueueIndex == index,
                            isSelected: model.selectedSessionQueueIndex == index,
                            isPending: model.pendingSessionQueueIndex == index
                        )
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(localMusicListBackground)
        }
    }

    private func beginSaveSessionQueuePlaylist() {
        saveQueuePlaylistName = Self.defaultQueuePlaylistName()
        showsSaveQueuePlaylistDialog = true
    }

    private func beginCreatePlaylist(for track: LocalMusicTrack? = nil) {
        newPlaylistTrack = track
        newPlaylistName = "New Playlist"
        showsNewPlaylistDialog = true
    }

    private func beginRenamePlaylist(_ playlist: LocalMusicPlaylist) {
        playlistPendingRename = playlist
        renamePlaylistName = playlist.name
        showsRenamePlaylistDialog = true
    }

    private func beginDeletePlaylist(_ playlist: LocalMusicPlaylist) {
        playlistPendingDeletion = playlist
    }

    private static func defaultQueuePlaylistName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Session Queue \(formatter.string(from: Date()))"
    }

    private var localMusicSearchSortBar: some View {
        HStack(spacing: 10) {
            TextField("Search song, artist, album, channels, or path", text: $model.localMusicSearchText)
                .textFieldStyle(.plain)
                .foregroundStyle(LabTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LabTheme.panelSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(LabTheme.line, lineWidth: 1)
                        )
                )

            localMusicSortMenu
                .frame(width: 150)

            localMusicChannelMenu
                .frame(width: 120)
        }
    }

    private var localMusicChannelMenu: some View {
        Menu {
            Button("All Channels") {
                model.localMusicChannelFilter = 0
            }
            ForEach(model.availableLocalMusicChannelCounts, id: \.self) { count in
                Button("\(count) ch") {
                    model.localMusicChannelFilter = count
                }
            }
        } label: {
            HStack {
                Text("CH")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft)
                Spacer()
                Text(model.localMusicChannelFilter == 0 ? "All" : "\(model.localMusicChannelFilter)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LabTheme.cyan)
            }
        }
        .buttonStyle(LabButtonStyle())
    }

    private var localMusicSortMenu: some View {
        Menu {
            ForEach(PlaylistSortMode.allCases) { sortMode in
                Button(sortMode.rawValue) {
                    model.localMusicSortMode = sortMode
                }
            }
        } label: {
            HStack {
                Text("SORT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LabTheme.textSoft)
                Spacer()
                Text(model.localMusicSortMode.rawValue)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LabTheme.cyan)
            }
        }
        .buttonStyle(LabButtonStyle())
    }

    private func localMusicTrackList(_ tracks: [LocalMusicTrack]) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 6) {
                ForEach(tracks) { track in
                    Button {
                        model.selectLocalMusicTrack(track)
                    } label: {
                        trackLibraryRow(track, isSelected: model.selectedLibraryTrackID == track.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play Now") {
                            model.playLocalMusicTrackNow(track)
                        }
                        Button("Add to Queue") {
                            model.addLocalMusicTrackToQueue(track)
                        }
                        addToPlaylistMenu(for: track)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(localMusicListBackground)
    }

    private var localMusicListBackground: some View {
        RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
            .fill(Color.black.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                    .stroke(LabTheme.line, lineWidth: 1)
            )
    }

    private func trackLibraryRow(_ track: LocalMusicTrack, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            LocalMusicThumbnailView(artworkPath: track.artworkPath)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(track.displaySubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(track.channelText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LabTheme.cyan)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)

                Text(track.durationText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? LabTheme.cyan.opacity(0.10) : Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? LabTheme.cyan.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        )
    }

    private func playlistLibraryRow(_ playlist: LocalMusicPlaylist, trackCount: Int, isSelected: Bool, isEditable: Bool) -> some View {
        HStack(spacing: 12) {
            LocalMusicThumbnailView(
                artworkPath: playlistArtworkPath(for: playlist),
                fallbackSystemImage: isEditable ? "music.note.list" : "lock"
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(playlist.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(isEditable ? "Editable" : "Read-only")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isEditable ? LabTheme.cyan.opacity(0.9) : LabTheme.textSoft.opacity(0.74))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text("\(trackCount)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(LabTheme.cyan)
                .frame(width: 42, alignment: .trailing)
        }
        .frame(height: 56)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? LabTheme.cyan.opacity(0.10) : Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? LabTheme.cyan.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        )
    }

    private func playlistTrackRow(
        track: LocalMusicTrack?,
        path: String,
        playlist: LocalMusicPlaylist,
        index: Int,
        trackCount: Int,
        isEditable: Bool
    ) -> some View {
        let title = track?.displayTitle ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let subtitle = track?.displaySubtitle ?? path

        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(LabTheme.textSoft)
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LabTheme.panelSoft)
                )

            LocalMusicThumbnailView(artworkPath: track?.artworkPath)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(track?.channelText ?? "-")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(LabTheme.textSoft)
                .frame(width: 58, alignment: .trailing)

            if isEditable {
                HStack(spacing: 4) {
                    Button {
                        model.moveLocalMusicPlaylistTrackUp(playlist, index: index)
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(LabButtonStyle())
                    .disabled(index == 0)

                    Button {
                        model.moveLocalMusicPlaylistTrackDown(playlist, index: index)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(LabButtonStyle())
                    .disabled(index >= trackCount - 1)

                    Button {
                        model.removeLocalMusicPlaylistTrack(playlist, index: index)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(LabButtonStyle())
                }
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .contextMenu {
            if let track {
                Button("Play Now") {
                    model.playLocalMusicTrackNow(track)
                }
                Button("Add to Queue") {
                    model.addLocalMusicTrackToQueue(track)
                }
            }
            if isEditable {
                if track != nil {
                    Divider()
                }
                Button("Remove From Playlist") {
                    model.removeLocalMusicPlaylistTrack(playlist, index: index)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private func queueTrackRow(
        _ track: LocalMusicTrack,
        index: Int,
        isCurrent: Bool,
        isSelected: Bool,
        isPending: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isCurrent || isPending ? LabTheme.bg : LabTheme.textSoft)
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isCurrent ? LabTheme.cyan : (isPending ? LabTheme.amber : LabTheme.panelSoft))
                )

            LocalMusicThumbnailView(artworkPath: track.artworkPath)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(track.displaySubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(track.channelText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isCurrent ? LabTheme.cyan : (isPending ? LabTheme.amber : (isSelected ? LabTheme.cyan : LabTheme.textSoft)))
                .frame(width: 58, alignment: .trailing)

            HStack(spacing: 4) {
                Button {
                    model.moveSessionQueueItemUp(index)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(LabButtonStyle())
                .disabled(index == 0)

                Button {
                    model.moveSessionQueueItemDown(index)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(LabButtonStyle())
                .disabled(index >= model.sessionQueue.count - 1)

                Button {
                    model.removeSessionQueueItem(index)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(LabButtonStyle())
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectSessionQueueIndex(index)
        }
        .contextMenu {
            Button("Play From Here") {
                model.playSessionQueueIndex(index)
            }
            addToPlaylistMenu(for: track)
            Divider()
            Button("Remove From Queue") {
                model.removeSessionQueueItem(index)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? LabTheme.cyan.opacity(0.10) : (isPending ? LabTheme.amber.opacity(0.10) : (isSelected ? LabTheme.blue.opacity(0.08) : Color.white.opacity(0.035))))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isCurrent ? LabTheme.cyan.opacity(0.45) : (isPending ? LabTheme.amber.opacity(0.45) : (isSelected ? LabTheme.blue.opacity(0.42) : Color.clear)), lineWidth: 1)
                )
        )
    }

    private func playlistArtworkPath(for playlist: LocalMusicPlaylist) -> String? {
        for path in playlist.trackPaths {
            if let track = model.localMusicTracks.first(where: { $0.path == path }),
               let artworkPath = track.artworkPath?.trimmedNilIfBlank {
                return artworkPath
            }
        }
        return nil
    }

    @ViewBuilder
    private func addToPlaylistMenu(for track: LocalMusicTrack) -> some View {
        Menu("Add to Playlist") {
            if model.editableLocalMusicPlaylists.isEmpty {
                Button("No editable playlists") {}
                    .disabled(true)
            } else {
                ForEach(model.editableLocalMusicPlaylists) { playlist in
                    Button(playlist.name) {
                        model.addLocalMusicTrackToPlaylist(track, playlist)
                    }
                }
                Divider()
            }
            Button("New Playlist...") {
                beginCreatePlaylist(for: track)
            }
        }
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            EqualHeightPanelRow(spacing: 18) {
                settingsPanel(
                    title: "Watch Folders",
                    fillsHeight: true
                ) {
                    HStack(spacing: 10) {
                        Button(action: model.chooseWatchFolder) {
                            Label("Add Folder", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LabButtonStyle(isActive: true))

                        Button(action: model.rescanLocalMusicLibrary) {
                            Label("Rescan", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LabButtonStyle())
                    }

                    settingsToggleRow(
                        title: "Search subfolders",
                        isOn: Binding(
                            get: { model.localMusicSettings.scansSubfolders },
                            set: model.setLocalMusicScansSubfolders
                        )
                    )

                    settingsToggleRow(
                        title: "Enhance Metadata",
                        isOn: Binding(
                            get: { model.localMusicSettings.enhancesMetadata },
                            set: model.setLocalMusicEnhancesMetadata
                        ),
                        helpText: "Use Orbisonic’s cached online names and artwork for missing local music info."
                    )

                    infoRow(title: "Folders", value: model.localMusicWatchFolderText)
                    settingsPathList(
                        paths: model.localMusicSettings.watchFolderPaths,
                        emptyText: "No watch folders yet.",
                        removeAction: model.removeWatchFolder
                    )
                }

                settingsPanel(
                    title: "Sound Settings",
                    fillsHeight: true
                ) {
                    tuningSlider(
                        title: "Max Output Volume",
                        value: $model.sphereOutputSafetyLimitPercent,
                        range: 0...100,
                        format: "%.0f"
                    )

                    settingsToggleRow(
                        title: "Gapless local playback",
                        isOn: $model.isLocalGaplessSchedulerEnabled
                    )

                    settingsToggleRow(
                        title: "Compressed trim metadata",
                        isOn: $model.isLocalGaplessCompressedTrimEnabled,
                        isEnabled: model.isLocalGaplessSchedulerEnabled
                    )

                    settingsToggleRow(
                        title: "Preload next track",
                        isOn: $model.preloadNextTrackEnabled,
                        helpText: "Decode the next queued track into memory so skips are instant. Works for any track; skipped automatically when memory is tight."
                    )

                    Text(model.nextTrackPreloadCaptionText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LabTheme.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            colorThemePanel
        }
    }

    private var colorThemePanel: some View {
        settingsPanel(title: "Color Theme") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 164), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(OrbisonicColorScheme.allCases) { scheme in
                    colorThemeTile(for: scheme)
                }
            }
        }
    }

    private func colorThemeTile(for scheme: OrbisonicColorScheme) -> some View {
        let isSelected = activeColorScheme == scheme
        let palette = scheme.palette

        return Button {
            colorSchemeRawValue = scheme.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    themeSwatch(palette.accent)
                    themeSwatch(palette.accentSecondary)
                    themeSwatch(palette.success)
                    themeSwatch(palette.warning)
                    themeSwatch(palette.danger)
                    Spacer(minLength: 0)
                }

                Text(scheme.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(scheme.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                    .fill(isSelected ? palette.accent.opacity(0.12) : Color.white.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                            .stroke(isSelected ? palette.accent.opacity(0.72) : LabTheme.line, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func themeSwatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 18, height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }

    private func settingsToggleRow(
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        helpText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isEnabled ? LabTheme.text : LabTheme.textSoft.opacity(0.58))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 190, alignment: .leading)

                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(LabTheme.cyan)
                    .disabled(!isEnabled)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)

            if let helpText {
                Text(helpText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEnabled ? LabTheme.textSoft : LabTheme.textSoft.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var vuMeterCalibrationControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VU Calibration")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)

            vuSliderRow(
                title: "0 VU Reference",
                valueText: String(format: "%.0f dBFS", vuMeterReferenceDbFS),
                lowText: "-24",
                highText: "-12",
                binding: vuMeterReferenceDbFSBinding,
                range: VUMeterCalibrationSettings.referenceRange
            )

            HStack(spacing: 8) {
                ForEach(VUMeterResponseMode.allCases) { mode in
                    Button {
                        vuMeterResponseMode = mode
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LabButtonStyle(isActive: vuMeterResponseMode == mode))
                }
            }

            vuSliderRow(
                title: "Monitor Trim",
                valueText: dbText(vuMeterMonitorTrimDb),
                lowText: "-6",
                highText: "+6",
                binding: vuMeterMonitorTrimDbBinding,
                range: VUMeterCalibrationSettings.trimRange
            )
            vuSliderRow(
                title: "Sonic Sphere Trim",
                valueText: dbText(vuMeterSonicSphereTrimDb),
                lowText: "-6",
                highText: "+6",
                binding: vuMeterSonicSphereTrimDbBinding,
                range: VUMeterCalibrationSettings.trimRange
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                .fill(Color.black.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private var vuMeterAppearanceSliders: some View {
        VStack(alignment: .leading, spacing: 14) {
            vuSliderRow(
                title: "Channel Label Gap",
                valueText: signedOffsetText(vuMeterLabelGapOffset, suffix: String(format: " / %.2fx", Double(rendererVUMeterAppearance.resolvedLabelGapScale))),
                lowText: "Tight",
                highText: "Loose",
                binding: vuMeterLabelGapBinding,
                range: VUMeterControlScale.sliderRange
            )
            vuSliderRow(
                title: "VU Element Size",
                valueText: signedOffsetText(vuMeterElementScale, suffix: String(format: " / %.2fx", previewVUMeterAppearance.resolvedElementScale)),
                lowText: "-10",
                highText: "+10",
                binding: vuMeterElementScaleBinding,
                range: VUMeterControlScale.sliderRange
            )
            vuSliderRow(
                title: "VU Size Ratio",
                valueText: signedOffsetText(vuMeterMaxSizeRatio, suffix: String(format: " / %.1fx", previewVUMeterAppearance.resolvedMaxSizeRatio)),
                lowText: "-10",
                highText: "+10",
                binding: vuMeterMaxSizeRatioBinding,
                range: VUMeterControlScale.sliderRange
            )
            vuSliderRow(
                title: "VU Outline Weight",
                valueText: signedOffsetText(vuMeterOutlineWeight, suffix: String(format: " / %.1f px", Double(previewVUMeterAppearance.resolvedOutlineWeight))),
                lowText: "-10",
                highText: "+10",
                binding: vuMeterOutlineWeightBinding,
                range: VUMeterControlScale.sliderRange
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                .fill(Color.black.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private func vuSliderRow(
        title: String,
        valueText: String,
        lowText: String,
        highText: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(LabTheme.cyan)
            }

            OrbisonicLinearControl(value: binding, range: range)

            HStack {
                Text(lowText)
                Spacer()
                Text(highText)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(LabTheme.textSoft)
        }
    }

    private func signedOffsetText(_ value: Double, suffix: String = "") -> String {
        "\(String(format: "%+.0f", VUMeterControlScale.clampedOffset(value)))\(suffix)"
    }

    private func dbText(_ value: Double) -> String {
        "\(String(format: "%+.1f", value)) dB"
    }

    private func settingsPathList(
        paths: [String],
        emptyText: String,
        removeAction: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if paths.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .frame(height: 38, alignment: .leading)
            } else {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LabTheme.textSoft)
                            .frame(width: 18)

                        Text(path)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LabTheme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)

                        Button {
                            removeAction(path)
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(LabButtonStyle())
                    }
                    .frame(height: 38)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(LabTheme.line, lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

    private func webURLRow(title: String, url: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
                .frame(width: 110, alignment: .leading)

            Text(url.isEmpty ? "Starting web server..." : url)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                                .stroke(LabTheme.line, lineWidth: 1)
                        )
                )

            Button {
                model.copyWebURLToPasteboard(url)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(LabButtonStyle())
            .disabled(url.isEmpty)
            .help("Copy \(title.lowercased()) URL")
        }
    }

    private var diagnosticsTab: some View {
        DiagnosticsView(model: model)
    }

    @ViewBuilder
    private func stageViewport<Content: View>(
        scrolls: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if scrolls {
            ScrollView(.vertical, showsIndicators: true) {
                content()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            content()
                .padding(.trailing, 6)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var outputChannelText: String {
        guard let metadata = model.visibleLocalSourceMetadata else {
            return "No source loaded"
        }

        return compactChannelText(for: metadata)
    }

    private func compactChannelText(for metadata: AudioSourceMetadata) -> String {
        compactChannelText(
            count: metadata.channelCount,
            layoutName: metadata.layoutName,
            channelSummary: metadata.channelSummary
        )
    }

    private func compactChannelText(count: Int, layoutName: String, channelSummary: String) -> String {
        guard count > 0 else { return "-" }

        if count == 4, layoutName.localizedCaseInsensitiveContains("quad") {
            return "4 quadraphonic"
        }

        if count <= 12, !channelSummary.isEmpty {
            return "\(count) \(layoutName)"
        }

        return "\(count) channels"
    }

    private var flowArrow: some View {
        VStack {
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(LabTheme.cyan.opacity(0.52))
            Spacer()
        }
        .frame(width: 18)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.36), radius: 18, x: 0, y: 10)
        )
    }

    private func playerRailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.36), radius: 18, x: 0, y: 10)
        )
        .clipped()
    }

    private func tuningSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(LabTheme.cyan)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            OrbisonicLinearControl(value: value, range: range)
        }
    }

    private func centeredTuningSlider(
        title: String,
        value: Binding<Double>,
        bounds: ClosedRange<Double>,
        defaultValue: Double,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(LabTheme.cyan)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }

            OrbisonicLinearControl(
                value: centeredTuningBinding(value: value, bounds: bounds, defaultValue: defaultValue),
                range: -1...1
            )

            HStack {
                Text(String(format: format, bounds.lowerBound))
                Spacer()
                Text("Default \(String(format: format, defaultValue))")
                Spacer()
                Text(String(format: format, bounds.upperBound))
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(LabTheme.textSoft)
        }
    }

    private func centeredTuningBinding(
        value: Binding<Double>,
        bounds: ClosedRange<Double>,
        defaultValue: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                let clamped = min(max(value.wrappedValue, bounds.lowerBound), bounds.upperBound)
                if clamped < defaultValue {
                    let span = max(defaultValue - bounds.lowerBound, 0.000_001)
                    return (clamped - defaultValue) / span
                }
                let span = max(bounds.upperBound - defaultValue, 0.000_001)
                return (clamped - defaultValue) / span
            },
            set: { position in
                let clampedPosition = min(max(position, -1), 1)
                let next: Double
                if clampedPosition < 0 {
                    next = defaultValue + clampedPosition * max(defaultValue - bounds.lowerBound, 0)
                } else {
                    next = defaultValue + clampedPosition * max(bounds.upperBound - defaultValue, 0)
                }
                value.wrappedValue = min(max(next, bounds.lowerBound), bounds.upperBound)
            }
        )
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LabTheme.text)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(minHeight: 32, alignment: .topLeading)
        }
    }

    private func monitorDownmixWarningText(_ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LabTheme.amber)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LabTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputDestinationCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LabTheme.text)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LabTheme.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .padding(16)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: OutputLaneNaturalHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .frame(maxWidth: .infinity, minHeight: outputLaneEqualHeight > 0 ? outputLaneEqualHeight : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panelSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private func outputLaneControlRow<Control: View>(
        label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: outputLaneColumnSpacing) {
            outputLaneLabel(label)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputLaneTextRow(label: String, value: String, isStatus: Bool = false) -> some View {
        HStack(alignment: .top, spacing: outputLaneColumnSpacing) {
            outputLaneLabel(label)
            Text(value)
                .font(.system(size: 12, weight: isStatus ? .bold : .semibold))
                .foregroundStyle(isStatus ? LabTheme.cyan : LabTheme.text)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(isStatus ? .tail : .middle)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputLaneWarningText(_ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LabTheme.amber)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LabTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, outputLaneLabelColumnWidth + outputLaneColumnSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputLaneLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(LabTheme.textSoft)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: outputLaneLabelColumnWidth, alignment: .leading)
    }

    private func outputLaneMenuValue(_ value: String) -> some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LabTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LabTheme.cyan)
        }
        .frame(maxWidth: .infinity)
    }

    private func outputLaneHelperText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LabTheme.textSoft)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsPanel<Content: View>(
        title: String,
        minHeight: CGFloat? = nil,
        fillsHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LabTheme.text)
            content()
        }
        .frame(
            maxWidth: .infinity,
            minHeight: minHeight,
            maxHeight: fillsHeight ? .infinity : nil,
            alignment: .topLeading
        )
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panelSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

}

private struct SavePlaylistDialog: View {
    var title = "Save Playlist"
    var primaryActionTitle = "Save"
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(LabTheme.text)

            TextField("Playlist Name", text: $name)
                .textFieldStyle(.plain)
                .foregroundStyle(LabTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                                .stroke(LabTheme.line, lineWidth: 1)
                        )
                )

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button("Cancel", action: onCancel)
                    .buttonStyle(LabButtonStyle())

                Button(primaryActionTitle, action: onSave)
                    .buttonStyle(LabButtonStyle(isActive: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(LabTheme.bg)
    }
}

private struct CompactSquareVUMeterPanel: View {
    let title: String
    let accent: Color
    let style: VUMeterVisualStyle
    let appearance: VUMeterAppearance
    @ObservedObject var meterStore: ChannelMeterStore
    var minHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(height: 18, alignment: .leading)

            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                Canvas { canvasContext, size in
                    DenseVUMeterRenderer.draw(
                        meters: sortedMeters,
                        style: style,
                        time: context.date.timeIntervalSinceReferenceDate,
                        context: &canvasContext,
                        size: size,
                        preferredCellSize: VUMeterLayout.preferredCellSize,
                        appearance: appearance
                    )
                }
                .frame(minHeight: minHeight)
                .background(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .fill(Color.black.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                                .stroke(LabTheme.line, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private var sortedMeters: [ChannelMeter] {
        meterStore.channelMeters.sorted { lhs, rhs in
            if lhs.channel.role.displayOrder == rhs.channel.role.displayOrder {
                return lhs.channel.index < rhs.channel.index
            }
            return lhs.channel.role.displayOrder < rhs.channel.role.displayOrder
        }
    }

}

private enum VUMeterLayout {
    static let preferredCellSize: CGFloat = 44
    static let minimumCellSize: CGFloat = 18
    static let panelPadding: CGFloat = 24
    static let cellGap: CGFloat = 10

    static var gapRatio: CGFloat {
        cellGap / preferredCellSize
    }
}

private struct LiveSurroundVUView: View {
    let title: String
    let subtitle: String
    @ObservedObject var meterStore: ChannelMeterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .frame(height: 22, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(meterStore.channelMeters.sorted(by: meterSort), id: \.id) { meter in
                        VStack(spacing: 8) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                                            .stroke(LabTheme.text.opacity(0.62), lineWidth: 1)
                                    )
                                    .frame(width: 54, height: 144)
                                RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                                    .fill(meterGradient(for: meter.channel.role))
                                    .frame(width: 54, height: max(12, 144 * CGFloat(meter.level)))
                            }
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 178)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panelSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
        .frame(minHeight: 238, alignment: .topLeading)
    }

    private func meterSort(lhs: ChannelMeter, rhs: ChannelMeter) -> Bool {
        if lhs.channel.role.displayOrder == rhs.channel.role.displayOrder {
            return lhs.channel.index < rhs.channel.index
        }
        return lhs.channel.role.displayOrder < rhs.channel.role.displayOrder
    }

    private func meterGradient(for role: SurroundChannelRole) -> LinearGradient {
        if role.isLFE {
            LinearGradient(
                colors: [LabTheme.amber, LabTheme.amber.opacity(0.55)],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if role.isRear {
            LinearGradient(
                colors: [LabTheme.blue, LabTheme.cyan.opacity(0.55)],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            LinearGradient(
                colors: [LabTheme.cyan, LabTheme.blue],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

private struct AudioMotionVUMeterPanel: View {
    let title: String
    let subtitle: String
    let style: AudioMotionVUStyle
    let appearance: VUMeterAppearance
    @ObservedObject var meterStore: ChannelMeterStore
    var minMeterHeight: CGFloat = 520
    var maxMeterHeight: CGFloat? = nil
    var showsMeterPills = true

    private var sortedMeters: [ChannelMeter] {
        meterStore.channelMeters.sorted { lhs, rhs in
            if lhs.channel.role.displayOrder == rhs.channel.role.displayOrder {
                return lhs.channel.index < rhs.channel.index
            }
            return lhs.channel.role.displayOrder < rhs.channel.role.displayOrder
        }
    }

    private var activeCount: Int {
        sortedMeters.filter { $0.level >= 0.005 }.count
    }

    private var hotCount: Int {
        sortedMeters.filter { $0.level >= 0.72 }.count
    }

    private var energyPercent: Int {
        Int(AudioMotionVUMeterRenderer.energyPercent(for: sortedMeters, appearance: appearance).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(LabTheme.text)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LabTheme.textSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                if showsMeterPills {
                    meterPill("CH", sortedMeters.count)
                    meterPill("E", energyPercent, accent: LabTheme.amber)
                    meterPill("A", activeCount)
                    meterPill("HOT", hotCount, accent: hotCount > 0 ? LabTheme.amber : LabTheme.textSoft)
                }
            }

            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    AudioMotionVUMeterRenderer.draw(
                        meters: sortedMeters,
                        style: style,
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        context: &context,
                        size: size,
                        appearance: appearance
                    )
                }
                .frame(maxWidth: .infinity, minHeight: minMeterHeight, maxHeight: resolvedMaxMeterHeight)
                .background(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                                .stroke(LabTheme.line, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panelSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private var resolvedMaxMeterHeight: CGFloat? {
        if let maxMeterHeight {
            return maxMeterHeight
        }
        return minMeterHeight == 520 ? .infinity : minMeterHeight
    }

    private func meterPill(_ label: String, _ value: Int, accent: Color = LabTheme.cyan) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
            Text("\(value)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }
}

private struct AudioMotionVUStylePreview: View {
    let style: AudioMotionVUStyle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas { context, size in
                let levels: [Float] = [0.18, 0.72, 0.46, 0.92, 0.31, 0.64, 0.24, 0.82]
                let meters = levels.enumerated().map { index, level in
                    ChannelMeter(
                        channel: SurroundChannel(index: index, role: .discrete(index)),
                        level: level
                    )
                }
                AudioMotionVUMeterRenderer.draw(
                    meters: meters,
                    style: style,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    context: &context,
                    size: size,
                    appearance: .default,
                    showLabels: false
                )
            }
        }
    }
}

private enum AudioMotionVUMeterRenderer {
    static func draw(
        meters: [ChannelMeter],
        style: AudioMotionVUStyle,
        time: TimeInterval,
        context: inout GraphicsContext,
        size: CGSize,
        appearance: VUMeterAppearance,
        showLabels: Bool = true
    ) {
        let bounds = CGRect(origin: .zero, size: size)
        drawBackground(in: bounds, context: &context)

        guard !meters.isEmpty else {
            context.draw(
                Text("NO INPUT CHANNELS")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(LabTheme.textSoft),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let levels = activityLevels(for: meters, appearance: appearance)

        switch style {
        case .classicSpectrum, .ledBars, .prismGlow:
            drawSpectrumBars(
                meters: meters,
                levels: levels,
                style: style,
                time: time,
                context: &context,
                bounds: bounds,
                appearance: appearance,
                showLabels: showLabels
            )
        case .mirror:
            drawMirrorBars(
                meters: meters,
                levels: levels,
                time: time,
                context: &context,
                bounds: bounds,
                appearance: appearance,
                showLabels: showLabels
            )
        case .radial:
            drawRadialBars(
                meters: meters,
                levels: levels,
                time: time,
                context: &context,
                bounds: bounds,
                showLabels: showLabels
            )
        }
    }

    static func energyPercent(for meters: [ChannelMeter], appearance: VUMeterAppearance) -> Double {
        Double(meterEnergy(levels: activityLevels(for: meters, appearance: appearance)) * 100)
    }

    private static func drawBackground(in bounds: CGRect, context: inout GraphicsContext) {
        context.fill(
            Path(bounds),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 1 / 255, green: 6 / 255, blue: 8 / 255),
                    Color(red: 9 / 255, green: 19 / 255, blue: 25 / 255),
                    Color.black.opacity(0.92)
                ]),
                startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
            )
        )

        let gridCount = 8
        for line in 1..<gridCount {
            let y = bounds.minY + bounds.height * CGFloat(line) / CGFloat(gridCount)
            var path = Path()
            path.move(to: CGPoint(x: bounds.minX, y: y))
            path.addLine(to: CGPoint(x: bounds.maxX, y: y))
            context.stroke(path, with: .color(LabTheme.line.opacity(0.35)), lineWidth: 1)
        }
    }

    private static func drawSpectrumBars(
        meters: [ChannelMeter],
        levels: [Float],
        style: AudioMotionVUStyle,
        time: TimeInterval,
        context: inout GraphicsContext,
        bounds: CGRect,
        appearance: VUMeterAppearance,
        showLabels: Bool
    ) {
        let content = bounds.insetBy(dx: max(18, bounds.width * 0.026), dy: max(18, bounds.height * 0.045))
        let labelGapScale = showLabels ? appearance.resolvedLabelGapScale : 1
        let labelHeight: CGFloat = showLabels ? 28 * labelGapScale : 8
        let reflectionHeight = (style == .classicSpectrum ? content.height * 0.16 : content.height * 0.2) * labelGapScale
        let labelSpacer = 10 * labelGapScale
        let meterRect = CGRect(
            x: content.minX,
            y: content.minY,
            width: content.width,
            height: max(1, content.height - reflectionHeight - labelHeight - labelSpacer)
        )
        let bars = VUMeterVerticalBarLayout.frames(count: levels.count, rect: meterRect)

        for index in 0..<min(levels.count, bars.count, meters.count) {
            let level = clampedLevel(levels[index])
            let barRect = bars[index]
            drawBarShell(rect: barRect, context: &context)

            if style == .ledBars {
                drawLedBar(level: level, index: index, rect: barRect, time: time, context: &context)
            } else {
                drawFilledBar(level: level, index: index, rect: barRect, style: style, time: time, context: &context)
            }

            drawPeakCap(level: level, index: index, rect: barRect, style: style, time: time, context: &context)
            drawReflection(level: level, index: index, rect: barRect, style: style, time: time, labelGapScale: labelGapScale, context: &context)

            if showLabels, shouldShowLabel(index: index, count: meters.count) {
                context.draw(
                    Text(VUMeterChannelLabel.text(for: meters[index].channel))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(LabTheme.textSoft),
                    at: CGPoint(x: barRect.midX, y: content.maxY - 6),
                    anchor: .bottom
                )
            }
        }
    }

    private static func drawMirrorBars(
        meters: [ChannelMeter],
        levels: [Float],
        time: TimeInterval,
        context: inout GraphicsContext,
        bounds: CGRect,
        appearance: VUMeterAppearance,
        showLabels: Bool
    ) {
        let content = bounds.insetBy(dx: max(18, bounds.width * 0.026), dy: max(20, bounds.height * 0.055))
        let labelGapScale = showLabels ? appearance.resolvedLabelGapScale : 1
        let labelHeight: CGFloat = showLabels ? 26 * labelGapScale : 8
        let meterRect = CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height - labelHeight)
        let bars = VUMeterVerticalBarLayout.frames(count: levels.count, rect: meterRect)
        let centerY = meterRect.midY

        var centerLine = Path()
        centerLine.move(to: CGPoint(x: meterRect.minX, y: centerY))
        centerLine.addLine(to: CGPoint(x: meterRect.maxX, y: centerY))
        context.stroke(centerLine, with: .color(LabTheme.cyan.opacity(0.18)), lineWidth: 1)

        for index in 0..<min(levels.count, bars.count, meters.count) {
            let level = clampedLevel(levels[index])
            let barRect = bars[index]
            let halfHeight = meterRect.height * 0.46 * CGFloat(level)
            let corner = min(4, barRect.width * 0.25)
            let upper = CGRect(x: barRect.minX, y: centerY - halfHeight, width: barRect.width, height: halfHeight)
            let lower = CGRect(x: barRect.minX, y: centerY, width: barRect.width, height: halfHeight)
            let color = barColor(level: level, index: index, style: .mirror, time: time)

            context.fill(Path(roundedRect: barRect, cornerRadius: corner), with: .color(Color.white.opacity(0.026)))
            var glow = context
            glow.addFilter(.shadow(color: color.opacity(0.38), radius: 10, x: 0, y: 0))
            glow.fill(Path(roundedRect: upper, cornerRadius: corner), with: .color(color.opacity(0.84)))
            glow.fill(Path(roundedRect: lower, cornerRadius: corner), with: .color(color.opacity(0.48)))
            drawPeakCap(level: level, index: index, rect: CGRect(x: barRect.minX, y: meterRect.minY, width: barRect.width, height: meterRect.height / 2), style: .mirror, time: time, context: &context)

            if showLabels, shouldShowLabel(index: index, count: meters.count) {
                context.draw(
                    Text(VUMeterChannelLabel.text(for: meters[index].channel))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(LabTheme.textSoft),
                    at: CGPoint(x: barRect.midX, y: content.maxY - 4),
                    anchor: .bottom
                )
            }
        }
    }

    private static func drawRadialBars(
        meters: [ChannelMeter],
        levels: [Float],
        time: TimeInterval,
        context: inout GraphicsContext,
        bounds: CGRect,
        showLabels: Bool
    ) {
        let content = bounds.insetBy(dx: max(22, bounds.width * 0.04), dy: max(22, bounds.height * 0.06))
        let center = CGPoint(x: content.midX, y: content.midY)
        let minDimension = min(content.width, content.height)
        let innerRadius = minDimension * 0.19
        let outerRadius = minDimension * 0.46
        let maxLength = outerRadius - innerRadius
        let count = max(1, levels.count)
        let lineWidth = max(3, min(18, minDimension / CGFloat(max(count, 8)) * 0.58))

        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)),
            with: .color(LabTheme.line.opacity(0.58)),
            lineWidth: 1
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2)),
            with: .color(LabTheme.line.opacity(0.28)),
            lineWidth: 1
        )

        for index in 0..<min(levels.count, meters.count) {
            let level = clampedLevel(levels[index])
            let angle = -.pi / 2 + CGFloat(index) / CGFloat(count) * .pi * 2
            let start = point(center: center, radius: innerRadius, angle: angle)
            let end = point(center: center, radius: innerRadius + maxLength * (0.12 + CGFloat(level) * 0.88), angle: angle)
            let color = barColor(level: level, index: index, style: .radial, time: time)
            var bar = Path()
            bar.move(to: start)
            bar.addLine(to: end)

            var glow = context
            glow.addFilter(.shadow(color: color.opacity(0.46), radius: 12, x: 0, y: 0))
            glow.stroke(bar, with: .color(color.opacity(0.86)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            if showLabels, count <= 16 {
                let labelPoint = point(center: center, radius: outerRadius + 18, angle: angle)
                context.draw(
                    Text(VUMeterChannelLabel.text(for: meters[index].channel))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(LabTheme.textSoft),
                    at: labelPoint,
                    anchor: .center
                )
            }
        }
    }

    private static func drawBarShell(rect: CGRect, context: inout GraphicsContext) {
        let radius = min(4, rect.width * 0.24)
        let shell = Path(roundedRect: rect, cornerRadius: radius)
        context.fill(shell, with: .color(Color.white.opacity(0.03)))
        context.stroke(shell, with: .color(LabTheme.line.opacity(0.45)), lineWidth: 1)
    }

    private static func drawFilledBar(
        level: Float,
        index: Int,
        rect: CGRect,
        style: AudioMotionVUStyle,
        time: TimeInterval,
        context: inout GraphicsContext
    ) {
        guard level > 0 else { return }

        let radius = min(4, rect.width * 0.24)
        let fillHeight = max(rect.width * 0.8, rect.height * CGFloat(level))
        let fillRect = CGRect(
            x: rect.minX,
            y: rect.maxY - min(rect.height, fillHeight),
            width: rect.width,
            height: min(rect.height, fillHeight)
        )
        let path = Path(roundedRect: fillRect, cornerRadius: radius)
        let colors = gradientColors(level: level, index: index, style: style, time: time)

        var glow = context
        glow.addFilter(.shadow(color: barColor(level: level, index: index, style: style, time: time).opacity(0.42), radius: style == .prismGlow ? 14 : 7, x: 0, y: 0))
        glow.fill(
            path,
            with: .linearGradient(
                Gradient(colors: colors),
                startPoint: CGPoint(x: fillRect.midX, y: fillRect.maxY),
                endPoint: CGPoint(x: fillRect.midX, y: fillRect.minY)
            )
        )
    }

    private static func drawLedBar(
        level: Float,
        index: Int,
        rect: CGRect,
        time: TimeInterval,
        context: inout GraphicsContext
    ) {
        let segments = max(10, min(32, Int(rect.height / 9)))
        let gap: CGFloat = 2
        let segmentHeight = max(2, (rect.height - gap * CGFloat(segments - 1)) / CGFloat(segments))
        let litSegments = Int((CGFloat(level) * CGFloat(segments)).rounded(.up))

        for segment in 0..<segments {
            let y = rect.maxY - CGFloat(segment + 1) * segmentHeight - CGFloat(segment) * gap
            let segmentRect = CGRect(x: rect.minX, y: y, width: rect.width, height: segmentHeight)
            let lit = segment < litSegments
            let segmentLevel = Float(segment + 1) / Float(segments)
            let color = lit
                ? barColor(level: max(level, segmentLevel), index: index, style: .ledBars, time: time)
                : Color.white.opacity(0.055)
            context.fill(
                Path(roundedRect: segmentRect, cornerRadius: min(2, segmentHeight * 0.35)),
                with: .color(color.opacity(lit ? 0.9 : 1))
            )
        }
    }

    private static func drawPeakCap(
        level: Float,
        index: Int,
        rect: CGRect,
        style: AudioMotionVUStyle,
        time: TimeInterval,
        context: inout GraphicsContext
    ) {
        guard level > 0.01 else { return }

        let capY = rect.maxY - rect.height * CGFloat(level)
        let capRect = CGRect(
            x: rect.minX - min(2, rect.width * 0.1),
            y: max(rect.minY, capY - 2),
            width: rect.width + min(4, rect.width * 0.2),
            height: 3
        )
        let color = level > 0.92 ? LabTheme.red : barColor(level: level, index: index, style: style, time: time)
        context.fill(Path(roundedRect: capRect, cornerRadius: 1.5), with: .color(color.opacity(0.95)))
    }

    private static func drawReflection(
        level: Float,
        index: Int,
        rect: CGRect,
        style: AudioMotionVUStyle,
        time: TimeInterval,
        labelGapScale: CGFloat,
        context: inout GraphicsContext
    ) {
        guard level > 0, style != .ledBars else { return }

        let height = min(rect.height * 0.28, rect.height * CGFloat(level) * 0.34) * labelGapScale
        let reflection = CGRect(x: rect.minX, y: rect.maxY + 6 * labelGapScale, width: rect.width, height: height)
        let color = barColor(level: level, index: index, style: style, time: time)
        context.fill(
            Path(roundedRect: reflection, cornerRadius: min(4, rect.width * 0.2)),
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.22), color.opacity(0.0)]),
                startPoint: CGPoint(x: reflection.midX, y: reflection.minY),
                endPoint: CGPoint(x: reflection.midX, y: reflection.maxY)
            )
        )
    }

    private static func shouldShowLabel(index: Int, count: Int) -> Bool {
        if count <= 16 { return true }
        let stride = Int(ceil(Double(count) / 16.0))
        return index.isMultiple(of: max(stride, 1))
    }

    private static func activityLevels(for meters: [ChannelMeter], appearance: VUMeterAppearance) -> [Float] {
        _ = appearance
        return meters.map { clampedLevel($0.level) }
    }

    private static func meterEnergy(levels: [Float]) -> Float {
        let active = levels.filter { $0 > 0.0001 }
        guard !active.isEmpty else { return 0 }
        let sumSquares = active.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(active.count))
    }

    private static func gradientColors(level: Float, index: Int, style: AudioMotionVUStyle, time: TimeInterval) -> [Color] {
        switch style {
        case .classicSpectrum, .mirror:
            return [
                Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255),
                Color(red: 132 / 255, green: 204 / 255, blue: 22 / 255),
                LabTheme.amber,
                level > 0.9 ? LabTheme.red : LabTheme.amber.opacity(0.9)
            ]
        case .ledBars:
            return [barColor(level: level, index: index, style: style, time: time)]
        case .prismGlow, .radial:
            let base = prismColor(index: index, time: time)
            return [
                base.opacity(0.7),
                Color(hue: shiftedHue(index: index, time: time) + 0.08, saturation: 0.78, brightness: 1),
                level > 0.94 ? LabTheme.red : Color.white.opacity(0.92)
            ]
        }
    }

    private static func barColor(level: Float, index: Int, style: AudioMotionVUStyle, time: TimeInterval) -> Color {
        switch style {
        case .classicSpectrum, .mirror:
            if level > 0.94 { return LabTheme.red }
            if level > 0.76 { return LabTheme.amber }
            if level > 0.45 { return Color(red: 132 / 255, green: 204 / 255, blue: 22 / 255) }
            return Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
        case .ledBars:
            if level > 0.94 { return LabTheme.red }
            if level > 0.72 { return LabTheme.amber }
            return LabTheme.cyan
        case .prismGlow, .radial:
            return prismColor(index: index, time: time)
        }
    }

    private static func prismColor(index: Int, time: TimeInterval) -> Color {
        Color(
            hue: shiftedHue(index: index, time: time),
            saturation: 0.72,
            brightness: 0.96
        )
    }

    private static func shiftedHue(index: Int, time: TimeInterval) -> Double {
        let raw = Double(index) * 0.085 + time * 0.025
        return raw - floor(raw)
    }

    private static func point(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private static func clampedLevel(_ level: Float) -> Float {
        min(max(level, 0), 1)
    }
}

private struct DenseVUMeterPanel: View {
    let title: String
    let subtitle: String
    let style: VUMeterVisualStyle
    let appearance: VUMeterAppearance
    @ObservedObject var meterStore: ChannelMeterStore
    var minHeight: CGFloat

    private var sortedMeters: [ChannelMeter] {
        meterStore.channelMeters.sorted { lhs, rhs in
            if lhs.channel.role.displayOrder == rhs.channel.role.displayOrder {
                return lhs.channel.index < rhs.channel.index
            }
            return lhs.channel.role.displayOrder < rhs.channel.role.displayOrder
        }
    }

    private var activeCount: Int {
        sortedMeters.filter { $0.level >= 0.005 }.count
    }

    private var hotCount: Int {
        sortedMeters.filter { $0.level >= 0.72 }.count
    }

    private var energyPercent: Int {
        Int(DenseVUMeterRenderer.energyPercent(for: sortedMeters, appearance: appearance).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(LabTheme.text)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LabTheme.textSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                meterPill("CH", sortedMeters.count)
                meterPill("E", energyPercent, accent: LabTheme.amber)
                meterPill("A", activeCount)
                meterPill("HOT", hotCount, accent: hotCount > 0 ? LabTheme.amber : LabTheme.textSoft)
            }

            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    DenseVUMeterRenderer.draw(
                        meters: sortedMeters,
                        style: style,
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        context: &context,
                        size: size,
                        preferredCellSize: VUMeterLayout.preferredCellSize,
                        appearance: appearance
                    )
                }
            }
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                    .fill(Color.black.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                            .stroke(LabTheme.line, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                .fill(LabTheme.panelSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }

    private func meterPill(_ label: String, _ value: Int, accent: Color = LabTheme.cyan) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LabTheme.textSoft)
            Text("\(value)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: LabTheme.controlRadius, style: .continuous)
                        .stroke(LabTheme.line, lineWidth: 1)
                )
        )
    }
}

private struct VUMeterStylePreview: View {
    let style: VUMeterVisualStyle
    let appearance: VUMeterAppearance

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let levels: [Float] = [0.28, 0.76, 0.48, 0.12, 0.92, 0.36]
                let meters = levels.enumerated().map { index, level in
                    ChannelMeter(
                        channel: SurroundChannel(index: index, role: .discrete(index)),
                        level: level
                    )
                }

                DenseVUMeterRenderer.draw(
                    meters: meters,
                    style: style,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    context: &context,
                    size: size,
                    preferredCellSize: VUMeterLayout.preferredCellSize,
                    appearance: appearance,
                    showLabels: false
                )
            }
        }
    }
}

private struct DenseMeterCell {
    let index: Int
    let center: CGPoint
    let rect: CGRect
    let size: CGFloat
    let radius: CGFloat
}

private enum DenseVUMeterRenderer {
    static func draw(
        meters: [ChannelMeter],
        style: VUMeterVisualStyle,
        time: TimeInterval,
        context: inout GraphicsContext,
        size: CGSize,
        preferredCellSize: CGFloat? = nil,
        appearance: VUMeterAppearance = .default,
        showLabels: Bool = true
    ) {
        let background = Path(CGRect(origin: .zero, size: size))
        context.fill(background, with: .color(LabTheme.bg.opacity(0.22)))

        guard !meters.isEmpty else {
            context.draw(
                Text("NO CHANNELS")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(LabTheme.textSoft),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let levels = activityLevels(for: meters, appearance: appearance)

        if style.isBars {
            drawVerticalBars(
                meters: meters,
                levels: levels,
                time: time,
                appearance: appearance,
                context: &context,
                size: size
            )
            return
        }

        let fillScale = appearance.resolvedPanelFillScale

        if style.isHex {
            let cells = hexCells(count: meters.count, size: size, fillScale: fillScale)
            for index in 0..<min(meters.count, cells.count, levels.count) {
                drawHex(meter: meters[index], level: levels[index], cell: cells[index], style: style, time: time, appearance: appearance, context: &context, showLabels: showLabels)
            }
        } else {
            let cells = squareCells(count: meters.count, size: size, fillScale: fillScale)
            for index in 0..<min(meters.count, cells.count, levels.count) {
                drawSquare(meter: meters[index], level: levels[index], cell: cells[index], style: style, time: time, appearance: appearance, context: &context, showLabels: showLabels)
            }
        }
    }

    static func energyPercent(for meters: [ChannelMeter], appearance: VUMeterAppearance) -> Double {
        Double(meterEnergy(levels: activityLevels(for: meters, appearance: appearance)) * 100)
    }

    private static func squareCells(count: Int, size: CGSize, fillScale: CGFloat) -> [DenseMeterCell] {
        let resolvedFillScale = min(max(fillScale, 0.2), 1)
        let padding = meterPadding(for: size, constrained: true)
        let aspect = size.width / max(size.height, 1)
        var best: (cols: Int, rows: Int, side: CGFloat, gap: CGFloat, score: CGFloat)?

        for cols in 1...max(count, 1) {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let gapRatio = VUMeterLayout.gapRatio
            let rawSide = min(
                (size.width - padding * 2) / (CGFloat(cols) + gapRatio * CGFloat(max(cols - 1, 0))),
                (size.height - padding * 2) / (CGFloat(rows) + gapRatio * CGFloat(max(rows - 1, 0)))
            )
            let side = rawSide * resolvedFillScale
            guard side > 1 else { continue }

            let gridAspect = CGFloat(cols) / CGFloat(max(rows, 1))
            let undersizePenalty = side < VUMeterLayout.minimumCellSize
                ? (VUMeterLayout.minimumCellSize - side) * 4
                : 0
            let score = side - abs(log(gridAspect / aspect)) * 5 - undersizePenalty
            if best == nil || score > best!.score {
                best = (cols, rows, side, side * gapRatio, score)
            }
        }

        guard let best else { return [] }

        let gridWidth = CGFloat(best.cols) * best.side + CGFloat(max(best.cols - 1, 0)) * best.gap
        let gridHeight = CGFloat(best.rows) * best.side + CGFloat(max(best.rows - 1, 0)) * best.gap
        let startX = (size.width - gridWidth) / 2
        let startY = (size.height - gridHeight) / 2

        return (0..<count).map { index in
            let col = index % best.cols
            let row = index / best.cols
            let rect = CGRect(
                x: startX + CGFloat(col) * (best.side + best.gap),
                y: startY + CGFloat(row) * (best.side + best.gap),
                width: best.side,
                height: best.side
            )
            return DenseMeterCell(index: index, center: CGPoint(x: rect.midX, y: rect.midY), rect: rect, size: best.side, radius: best.side / 2)
        }
    }

    private static func hexCells(count: Int, size: CGSize, fillScale: CGFloat) -> [DenseMeterCell] {
        let resolvedFillScale = min(max(fillScale, 0.2), 1)
        let padding = meterPadding(for: size, constrained: true)
        let gapRatio = VUMeterLayout.gapRatio
        let sqrt3 = CGFloat(sqrt(3.0))
        var best: (cols: Int, rows: Int, radius: CGFloat, score: CGFloat)?

        for cols in 1...max(count, 1) {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let rowOffsetFactor = rows > 1 ? (sqrt3 + gapRatio) / 2 : 0
            let widthFactor = CGFloat(cols) * sqrt3 + CGFloat(max(cols - 1, 0)) * gapRatio + rowOffsetFactor
            let heightFactor = CGFloat(2) + CGFloat(max(rows - 1, 0)) * (1.5 + gapRatio)
            let rawRadius = min((size.width - padding * 2) / widthFactor, (size.height - padding * 2) / heightFactor)
            let radius = rawRadius * resolvedFillScale
            guard radius > 1 else { continue }

            let usedWidth = radius * widthFactor
            let usedHeight = radius * heightFactor
            let diameter = radius * 2
            let undersizePenalty = diameter < VUMeterLayout.minimumCellSize
                ? (VUMeterLayout.minimumCellSize - diameter) * 2
                : 0
            let score = radius - abs(log((usedWidth / max(usedHeight, 1)) / (size.width / max(size.height, 1)))) * 4 - undersizePenalty
            if best == nil || score > best!.score {
                best = (cols, rows, radius, score)
            }
        }

        guard let best else { return [] }

        let radius = best.radius
        let gap = radius * gapRatio
        let hexWidth = sqrt3 * radius
        let stepX = hexWidth + gap
        let stepY = radius * 1.5 + gap
        let rowOffset = best.rows > 1 ? stepX / 2 : 0
        let usedWidth = CGFloat(best.cols) * hexWidth + CGFloat(max(best.cols - 1, 0)) * gap + rowOffset
        let usedHeight = radius * 2 + CGFloat(max(best.rows - 1, 0)) * stepY
        let startX = (size.width - usedWidth) / 2 + hexWidth / 2
        let startY = (size.height - usedHeight) / 2 + radius

        return (0..<count).map { index in
            let col = index % best.cols
            let row = index / best.cols
            let center = CGPoint(
                x: startX + CGFloat(col) * stepX + (row.isMultiple(of: 2) ? 0 : rowOffset),
                y: startY + CGFloat(row) * stepY
            )
            return DenseMeterCell(
                index: index,
                center: center,
                rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                size: radius * 2,
                radius: radius
            )
        }
    }

    private static func meterPadding(for size: CGSize, constrained: Bool) -> CGFloat {
        guard constrained else {
            return max(CGFloat(12), min(size.width, size.height) * 0.055)
        }

        return min(VUMeterLayout.panelPadding, max(10, min(size.width, size.height) * 0.22))
    }

    private static func drawVerticalBars(
        meters: [ChannelMeter],
        levels: [Float],
        time: TimeInterval,
        appearance: VUMeterAppearance,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let count = max(1, min(meters.count, levels.count))
        let padding = meterPadding(for: size, constrained: true)
        let rect = CGRect(
            x: padding,
            y: padding,
            width: max(1, size.width - padding * 2),
            height: max(1, size.height - padding * 2)
        )
        let barFrames = VUMeterVerticalBarLayout.frames(count: count, rect: rect)

        for index in 0..<count {
            let level = levels[index]
            let columnRect = barFrames[index]
            let columnWidth = columnRect.width
            let shell = Path(roundedRect: columnRect, cornerRadius: min(3, columnWidth * 0.22))
            context.fill(shell, with: .color(Color.white.opacity(0.035)))
            context.stroke(
                shell,
                with: .color(outlineColor(level: level).opacity(outlineOpacity(level: level, appearance: appearance))),
                lineWidth: appearance.resolvedOutlineWeight
            )

            guard level > 0 else { continue }
            let fillHeight = max(columnWidth * 0.6, columnRect.height * fillFraction(level: level, appearance: appearance))
            let fillRect = CGRect(
                x: columnRect.minX,
                y: columnRect.maxY - min(columnRect.height, fillHeight),
                width: columnRect.width,
                height: min(columnRect.height, fillHeight)
            )
            context.fill(
                Path(roundedRect: fillRect, cornerRadius: min(3, columnWidth * 0.22)),
                with: meterFillShading(
                    level: level,
                    rect: fillRect,
                    seed: CGFloat(index) * 0.09,
                    time: time,
                    colorMode: appearance.colorMode,
                    opacity: 0.26 + Double(level) * 0.64,
                    axis: .vertical
                )
            )
        }
    }

    private static func drawSquare(
        meter: ChannelMeter,
        level: Float,
        cell: DenseMeterCell,
        style: VUMeterVisualStyle,
        time: TimeInterval,
        appearance: VUMeterAppearance,
        context: inout GraphicsContext,
        showLabels: Bool
    ) {
        let shell = Path(roundedRect: cell.rect, cornerRadius: max(2, cell.size * 0.055))
        context.fill(shell, with: .color(Color.white.opacity(0.045)))
        context.stroke(
            shell,
            with: .color(outlineColor(level: level).opacity(outlineOpacity(level: level, appearance: appearance))),
            lineWidth: appearance.resolvedOutlineWeight
        )

        if style.isFlicker {
            drawSquareFlicker(level: level, cell: cell, time: time, appearance: appearance, context: &context)
        } else {
            let inner = cell.size * fillFraction(level: level, appearance: appearance)
            let rect = CGRect(x: cell.center.x - inner / 2, y: cell.center.y - inner / 2, width: inner, height: inner)
            context.fill(
                Path(roundedRect: rect, cornerRadius: max(1, inner * 0.06)),
                with: .color(meterColor(level: level, seed: CGFloat(cell.index) * 0.13, time: time, colorMode: appearance.colorMode).opacity(0.24 + Double(level) * 0.68))
            )
        }

        _ = meter
        _ = showLabels
    }

    private static func drawHex(
        meter: ChannelMeter,
        level: Float,
        cell: DenseMeterCell,
        style: VUMeterVisualStyle,
        time: TimeInterval,
        appearance: VUMeterAppearance,
        context: inout GraphicsContext,
        showLabels: Bool
    ) {
        let shell = hexPath(center: cell.center, radius: cell.radius)
        context.fill(shell, with: .color(Color.white.opacity(0.041)))
        context.stroke(
            shell,
            with: .color(outlineColor(level: level).opacity(outlineOpacity(level: level, appearance: appearance))),
            lineWidth: max(appearance.resolvedOutlineWeight, cell.radius * 0.035)
        )

        if style.isFlicker {
            drawHexRipple(level: level, cell: cell, time: time, appearance: appearance, context: &context)
        } else {
            let inner = cell.radius * fillFraction(level: level, appearance: appearance)
            context.fill(
                hexPath(center: cell.center, radius: inner),
                with: .color(meterColor(level: level, seed: CGFloat(cell.index) * 0.13, time: time, colorMode: appearance.colorMode).opacity(0.24 + Double(level) * 0.68))
            )
        }

        _ = meter
        _ = showLabels
    }

    private static func drawSquareFlicker(
        level: Float,
        cell: DenseMeterCell,
        time: TimeInterval,
        appearance: VUMeterAppearance,
        context: inout GraphicsContext
    ) {
        let energy = pow(CGFloat(level), 1.4)
        let block = max(CGFloat(2), floor(cell.size / (energy > 0.5 ? 8 : 10)))
        let inset = cell.size * 0.12
        let field = cell.size - inset * 2
        let pulse = sin(CGFloat(time) * (0.8 + energy * 4.2) * .pi * 2 + CGFloat(cell.index)) * 0.5 + 0.5
        let coreSize = max(block, floor(field * (0.12 + CGFloat(level) * 0.68) * (0.78 + pulse * 0.34) / block) * block)
        let coreRect = CGRect(
            x: floor((cell.center.x - coreSize / 2) / block) * block,
            y: floor((cell.center.y - coreSize / 2) / block) * block,
            width: coreSize,
            height: coreSize
        )
        context.fill(
            Path(roundedRect: coreRect, cornerRadius: max(1, block)),
            with: .color(meterColor(level: level, seed: CGFloat(cell.index) * 0.17, time: time, colorMode: appearance.colorMode).opacity(0.06 + Double(energy) * 0.32))
        )

        let pixels = max(1, Int(1 + energy * min(20, cell.size / 2.4)))
        let speed = 0.35 + energy * 15
        let frame = floor(CGFloat(time) * speed)

        for pixel in 0..<pixels {
            let seed = noise(CGFloat(cell.index) * 31.7 + CGFloat(pixel) * 5.1)
            let jitter = noise(CGFloat(cell.index) * 9.3 + CGFloat(pixel) * 13.9 + frame)
            let x = cell.rect.minX + inset + noise(seed * 101 + jitter * 7) * field
            let y = cell.rect.minY + inset + noise(seed * 209 + jitter * 11) * field
            let rect = CGRect(x: floor(x / block) * block, y: floor(y / block) * block, width: block, height: block)
            context.fill(
                Path(rect),
                with: .color(pixelColor(level: level, seed: seed, time: time, colorMode: appearance.colorMode).opacity(0.12 + Double(level) * 0.7))
            )
        }
    }

    private static func drawHexRipple(
        level: Float,
        cell: DenseMeterCell,
        time: TimeInterval,
        appearance: VUMeterAppearance,
        context: inout GraphicsContext
    ) {
        let energy = pow(CGFloat(level), 1.35)
        let maxRadius = cell.radius * 0.84
        let block = max(CGFloat(2), floor(cell.radius / (energy > 0.55 ? 4.2 : 5.4)))
        let diameter = maxRadius * 2
        let columns = max(1, Int(ceil(diameter / block)))
        let startX = floor((cell.center.x - diameter / 2) / block) * block
        let startY = floor((cell.center.y - diameter / 2) / block) * block
        let speed = 0.045 + energy * 0.42
        let travel = (CGFloat(time) * speed + noise(CGFloat(cell.index) * 0.23)).truncatingRemainder(dividingBy: 1)
        let width = 9.5 - energy * 3.3
        let shimmerFrame = floor(CGFloat(time) * (0.35 + energy * 1.45))
        var clipped = context
        clipped.clip(to: hexPath(center: cell.center, radius: maxRadius))

        for row in 0...columns {
            for col in 0...columns {
                let x = startX + CGFloat(col) * block
                let y = startY + CGFloat(row) * block
                let sample = CGPoint(x: x + block / 2, y: y + block / 2)
                let distance = hypot(sample.x - cell.center.x, sample.y - cell.center.y)
                guard distance <= maxRadius else { continue }

                let normalized = distance / max(maxRadius, 1)
                let seed = noise(CGFloat(cell.index) * 53.2 + CGFloat(row) * 7.9 + CGFloat(col) * 3.1)
                let ring = rippleBand(normalized: normalized, travel: travel + seed * 0.025, width: width)
                let secondary = rippleBand(normalized: normalized, travel: travel - 0.34 + seed * 0.018, width: width * 1.18) * 0.48
                let centerBloom = pow(1 - normalized, 2.4) * (0.08 + energy * 0.34)
                let shimmer = 0.82 + noise(seed * 113 + shimmerFrame) * 0.36
                let alpha = (ring + secondary + centerBloom) * shimmer * (0.08 + pow(CGFloat(level), 0.92) * 0.8)

                guard alpha >= 0.025 else { continue }
                clipped.fill(
                    Path(CGRect(x: x, y: y, width: block, height: block)),
                    with: .color(pixelColor(level: level, seed: min(seed + ring * energy * 0.55, 1), time: time, colorMode: appearance.colorMode).opacity(Double(alpha)))
                )
            }
        }
    }

    private static func hexPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for index in 0..<6 {
            let angle = -.pi / 2 + CGFloat(index) * .pi / 3
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private static func clampedLevel(_ level: Float) -> Float {
        min(max(level, 0), 1)
    }

    private static func activityLevels(for meters: [ChannelMeter], appearance: VUMeterAppearance) -> [Float] {
        _ = appearance
        return meters.map { clampedLevel($0.level) }
    }

    private static func meterEnergy(levels: [Float]) -> Float {
        let active = levels.filter { $0 > 0.0001 }
        guard !active.isEmpty else { return 0 }
        let sumSquares = active.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(active.count))
    }

    private static func fillFraction(level: Float, appearance: VUMeterAppearance) -> CGFloat {
        let maxFraction: CGFloat = 0.86
        let minFraction = maxFraction / max(CGFloat(appearance.resolvedMaxSizeRatio), 1)
        return minFraction + CGFloat(clampedLevel(level)) * (maxFraction - minFraction)
    }

    private static func outlineColor(level: Float) -> Color {
        _ = level
        return LabTheme.text
    }

    private static func outlineOpacity(level: Float, appearance: VUMeterAppearance) -> Double {
        let weightLift = min(Double(appearance.resolvedOutlineWeight) * 0.07, 0.18)
        return min(0.94, 0.42 + Double(level) * 0.34 + weightLift)
    }

    private static func meterColor(
        level: Float,
        seed: CGFloat,
        time: TimeInterval,
        colorMode: VUMeterColorMode
    ) -> Color {
        switch colorMode {
        case .systemGreen:
            return LabTheme.palette.vuColor(for: Double(level))
        case .white:
            if level > 0.94 { return LabTheme.red }
            if level > 0.78 { return LabTheme.amber }
            let value = 0.56 + Double(level) * 0.44
            return Color(red: value, green: value, blue: value)
        case .sparkle:
            return sparkleColor(level: level, seed: seed, time: time)
        case .classic:
            return LabTheme.palette.vuColor(for: Double(level))
        }
    }

    private static func pixelColor(
        level: Float,
        seed: CGFloat,
        time: TimeInterval,
        colorMode: VUMeterColorMode
    ) -> Color {
        switch colorMode {
        case .sparkle:
            return sparkleColor(level: level, seed: seed, time: time)
        case .classic:
            return LabTheme.palette.vuColor(for: Double(min(1, level + Float(seed) * 0.08)))
        case .white:
            if level > 0.94, seed > 0.35 { return LabTheme.red }
            if level > 0.78, seed > 0.22 { return LabTheme.amber }
            let value = 0.52 + Double(level) * 0.48
            return Color(red: value, green: value, blue: value)
        case .systemGreen:
            return LabTheme.palette.vuColor(for: Double(min(1, level + Float(seed) * 0.08)))
        }
    }

    private enum MeterFillAxis {
        case horizontal
        case vertical
    }

    private static func meterFillShading(
        level: Float,
        rect: CGRect,
        seed: CGFloat,
        time: TimeInterval,
        colorMode: VUMeterColorMode,
        opacity: Double,
        axis: MeterFillAxis
    ) -> GraphicsContext.Shading {
        let palette = LabTheme.palette
        let usesCompressedPaletteRamp =
            palette.compressesLinearControlRampIntoActiveSegment &&
            (colorMode == .classic || colorMode == .systemGreen)

        guard usesCompressedPaletteRamp else {
            return .color(meterColor(level: level, seed: seed, time: time, colorMode: colorMode).opacity(opacity))
        }

        let gradient = Gradient(stops: palette.vuRamp
            .sorted { $0.position < $1.position }
            .map { Gradient.Stop(color: $0.color.opacity(opacity), location: $0.position) })

        switch axis {
        case .horizontal:
            return .linearGradient(
                gradient,
                startPoint: CGPoint(x: rect.minX, y: rect.midY),
                endPoint: CGPoint(x: rect.maxX, y: rect.midY)
            )
        case .vertical:
            return .linearGradient(
                gradient,
                startPoint: CGPoint(x: rect.midX, y: rect.maxY),
                endPoint: CGPoint(x: rect.midX, y: rect.minY)
            )
        }
    }

    private static func sparkleColor(level: Float, seed: CGFloat, time: TimeInterval) -> Color {
        if level > 0.96, seed > 0.72 { return LabTheme.red }
        let rawHue = time * 0.075 + Double(seed) * 0.82 + Double(level) * 0.18
        let hue = rawHue - floor(rawHue)
        return Color(hue: hue, saturation: 0.72 + Double(level) * 0.2, brightness: 0.72 + Double(level) * 0.28)
    }

    private static func classicWinampColor(level: Float) -> Color {
        let colors: [(Double, Double, Double)] = [
            (24, 132, 8),
            (41, 148, 0),
            (49, 156, 8),
            (57, 181, 16),
            (50, 190, 16),
            (41, 206, 16),
            (148, 222, 33),
            (189, 222, 41),
            (214, 181, 33),
            (222, 165, 24),
            (198, 123, 8),
            (214, 115, 0),
            (214, 102, 0),
            (214, 90, 0),
            (206, 41, 16),
            (239, 49, 16)
        ]
        let index = min(colors.count - 1, max(0, Int(round(Double(clampedLevel(level)) * Double(colors.count - 1)))))
        let color = colors[index]
        return Color(red: color.0 / 255, green: color.1 / 255, blue: color.2 / 255)
    }

    private static func rippleBand(normalized: CGFloat, travel: CGFloat, width: CGFloat) -> CGFloat {
        let wrapped = ((travel.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)
        let distance = min(abs(normalized - wrapped), abs(normalized - wrapped + 1), abs(normalized - wrapped - 1))
        return pow(max(1 - distance * width, 0), 2.2)
    }

    private static func noise(_ value: CGFloat) -> CGFloat {
        let raw = sin(value * 127.1 + 311.7) * 43_758.5453
        return raw - floor(raw)
    }
}

private struct OrbitalSonicSphereMeterPanel: View {
    let sceneModel: RendererSceneModel
    let isPlaying: Bool
    let physicalOutputChannelCount: Int
    @ObservedObject var meterStore: ChannelMeterStore

    var body: some View {
        let meterState = orbitalVUMeterState

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Orbital View")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LabTheme.text)
                    .lineLimit(1)

                Text(meterState.meterSourceLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(meterState.hasActiveMarkers ? LabTheme.cyan : LabTheme.textSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Orbital VU meter source")
                    .accessibilityValue(meterState.meterSourceLabel)

                Spacer(minLength: 0)

                Text(activityText(for: meterState))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(activityColor(for: meterState))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityLabel("Orbital VU meter activity")
            }
            .frame(height: 18, alignment: .leading)

            SonicSphereRendererSceneView(
                sceneModel: sceneModel,
                isPlaying: isPlaying,
                orbitalVUMeterState: meterState,
                viewportMode: .isometric,
                isInteractive: false
            )
            .frame(minHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous)
                    .stroke(LabTheme.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: LabTheme.panelRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var orbitalVUMeterState: OrbitalVUMeterViewState {
        let snapshot = OrbitalVUMeterSnapshot(
            source: .sonicSphereAnalysis,
            channels: meterStore.channelMeters.map { meter in
                OrbitalVUMeterChannelSnapshot(
                    normalizedLevel: meter.level,
                    peakDbFS: meter.peakDbFS,
                    isClipping: meter.peakDbFS >= 0
                )
            },
            isActive: meterStore.isActive
        )
        let physicalOutputCount = physicalOutputChannelCount > sceneModel.outputSpeakers.count
            ? min(physicalOutputChannelCount, 32)
            : nil
        return OrbitalVUMeterModel.sonicSphereOutputState(
            scene: sceneModel,
            meterSnapshot: snapshot,
            physicalOutputChannelCount: physicalOutputCount
        )
    }

    private func activityText(for state: OrbitalVUMeterViewState) -> String {
        let activeCount = state.markers.filter { $0.isActive }.count
        let totalCount = state.markers.count

        if state.markers.contains(where: { $0.isClipping }) {
            return "clip"
        }
        if state.markers.contains(where: { $0.isHot }) {
            return "hot"
        }
        if activeCount > 0 {
            return "\(activeCount)/\(totalCount) active"
        }
        return "inactive"
    }

    private func activityColor(for state: OrbitalVUMeterViewState) -> Color {
        if state.markers.contains(where: { $0.isClipping }) {
            return LabTheme.red
        }
        if state.markers.contains(where: { $0.isHot }) {
            return LabTheme.amber
        }
        if state.hasActiveMarkers {
            return LabTheme.cyan
        }
        return LabTheme.textSoft
    }
}

private struct SonicSphereRendererSceneView: NSViewRepresentable {
    let sceneModel: RendererSceneModel
    let isPlaying: Bool
    var orbitalVUMeterState: OrbitalVUMeterViewState = .empty(source: .sonicSphereAnalysis)
    var viewportMode: RendererViewportMode = .isometric
    var isInteractive = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CenteredOrbitSceneView {
        let view = CenteredOrbitSceneView()
        view.orbitCoordinator = context.coordinator
        view.isOrbitInteractionEnabled = isInteractive
        context.coordinator.sceneView = view
        context.coordinator.configure(viewportMode: viewportMode, isInteractive: isInteractive)
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.backgroundColor = NSColor(calibratedRed: 0.006, green: 0.014, blue: 0.017, alpha: 1.0)
        view.rendersContinuously = true
        let sceneBundle = makeScene()
        view.scene = sceneBundle.scene
        view.pointOfView = sceneBundle.cameraNode
        context.coordinator.attach(cameraNode: sceneBundle.cameraNode, contentRoot: sceneBundle.contentRoot)
        context.coordinator.updateScene(
            sceneModel: sceneModel,
            isPlaying: isPlaying,
            meterState: orbitalVUMeterState,
            makeOutputSpeaker: makeOutputSpeaker,
            makeInputSpeaker: makeInputSpeaker,
            makeReservedOutputMarker: makeReservedOutputMarker,
            makeListener: makeListener
        )
        if isInteractive {
            let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
            view.addGestureRecognizer(pan)
            let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnify(_:)))
            view.addGestureRecognizer(magnify)
        }
        return view
    }

    func updateNSView(_ nsView: CenteredOrbitSceneView, context: Context) {
        nsView.isOrbitInteractionEnabled = isInteractive
        context.coordinator.configure(viewportMode: viewportMode, isInteractive: isInteractive)
        context.coordinator.updateScene(
            sceneModel: sceneModel,
            isPlaying: isPlaying,
            meterState: orbitalVUMeterState,
            makeOutputSpeaker: makeOutputSpeaker,
            makeInputSpeaker: makeInputSpeaker,
            makeReservedOutputMarker: makeReservedOutputMarker,
            makeListener: makeListener
        )
    }

    private func makeScene() -> (scene: SCNScene, cameraNode: SCNNode, contentRoot: SCNNode) {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.006, green: 0.014, blue: 0.017, alpha: 1.0)

        let root = scene.rootNode

        let camera = SCNCamera()
        camera.fieldOfView = 46
        camera.zNear = 0.01
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        root.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 520
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .omni
        key.intensity = 680
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-2.5, 2.5, 3.0)
        root.addChildNode(keyNode)

        root.addChildNode(makeLamellaSphere())
        root.addChildNode(makeEquator())

        let contentRoot = SCNNode()
        contentRoot.name = "orbisonic-renderer-dynamic-content"
        root.addChildNode(contentRoot)

        return (scene, cameraNode, contentRoot)
    }

    private func makeLamellaSphere() -> SCNNode {
        let container = SCNNode()
        let sectorCount = 22
        let ringCount = 19
        let skewRadians = 45.0 * Double.pi / 180

        for ring in 1...ringCount {
            let y = -1.0 + 2.0 * Double(ring) / Double(ringCount + 1)
            let node = torusNode(
                radius: sqrt(max(0, 1 - y * y)),
                color: NSColor(calibratedRed: 0.34, green: 0.90, blue: 0.84, alpha: 0.52)
            )
            node.position.y = CGFloat(y)
            container.addChildNode(node)
        }

        for sector in 0..<sectorCount {
            let baseAzimuth = Double(sector) * 2.0 * Double.pi / Double(sectorCount)
            let points = (0...96).map { step -> SCNVector3 in
                let y = -0.985 + 1.97 * Double(step) / 96.0
                let radius = sqrt(max(0, 1 - y * y))
                let azimuth = baseAzimuth + skewRadians * y / 2.0
                return SCNVector3(
                    Float(cos(azimuth) * radius),
                    Float(y),
                    Float(sin(azimuth) * radius)
                )
            }
            let node = polylineNode(
                points: points,
                color: NSColor(calibratedRed: 0.24, green: 0.54, blue: 0.95, alpha: 0.30)
            )
            container.addChildNode(node)
        }

        return container
    }

    private func makeEquator() -> SCNNode {
        let node = torusNode(
            radius: 1.002,
            color: NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 0.82),
            pipeRadius: 0.0038
        )
        return node
    }

    private func makeOutputSpeaker(_ speaker: RendererOutputSpeaker) -> SCNNode {
        let geometry = SCNSphere(radius: speaker.isLFE ? 0.048 : 0.036)
        geometry.segmentCount = speaker.isLFE ? 16 : 20
        geometry.firstMaterial = material(
            color: speaker.isLFE
                ? NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 1.0)
                : NSColor(calibratedRed: 0.37, green: 0.92, blue: 0.83, alpha: 1.0),
            emission: speaker.isLFE
                ? NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.02, alpha: 1.0)
                : NSColor(calibratedRed: 0.06, green: 0.34, blue: 0.31, alpha: 1.0)
        )

        let node = SCNNode(geometry: geometry)
        node.name = speaker.displayName
        node.position = speaker.position.scnVector
        return node
    }

    private func makeReservedOutputMarker(_ marker: OrbitalVUMeterMarker, offset: Int) -> SCNNode {
        let geometry = SCNSphere(radius: 0.026)
        geometry.segmentCount = 12
        geometry.firstMaterial = material(
            color: NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.31, alpha: 0.62),
            emission: NSColor(calibratedRed: 0.015, green: 0.035, blue: 0.04, alpha: 1.0)
        )

        let node = SCNNode(geometry: geometry)
        node.name = "Reserved Output \(marker.label)"
        let angle = -Double.pi / 2.0 + Double(offset) * 0.12
        node.position = SCNVector3(
            Float(cos(angle) * 1.10),
            -1.12,
            Float(sin(angle) * 1.10)
        )
        return node
    }

    private func makeInputSpeaker(_ speaker: RendererInputSpeaker) -> SCNNode {
        let geometry = SCNBox(width: 0.075, height: 0.075, length: 0.075, chamferRadius: 0.008)
        geometry.firstMaterial = material(
            color: speaker.channel.role.isLFE
                ? NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 0.95)
                : NSColor(calibratedRed: 0.96, green: 0.44, blue: 0.52, alpha: 0.95),
            emission: speaker.channel.role.isLFE
                ? NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.02, alpha: 1.0)
                : NSColor(calibratedRed: 0.26, green: 0.08, blue: 0.12, alpha: 1.0)
        )

        let node = SCNNode(geometry: geometry)
        node.name = speaker.displayName
        node.position = speaker.position.scnVector
        return node
    }

    private func makeListener() -> SCNNode {
        let geometry = SCNSphere(radius: isPlaying ? 0.043 : 0.034)
        geometry.segmentCount = 20
        geometry.firstMaterial = material(
            color: NSColor(calibratedRed: 0.93, green: 0.99, blue: 1.0, alpha: 1.0),
            emission: NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.28, alpha: 1.0)
        )
        return SCNNode(geometry: geometry)
    }

    private func torusNode(
        radius: Double,
        color: NSColor,
        pipeRadius: CGFloat = 0.0025
    ) -> SCNNode {
        let torus = SCNTorus(ringRadius: CGFloat(max(radius, 0.001)), pipeRadius: pipeRadius)
        torus.ringSegmentCount = 96
        torus.pipeSegmentCount = 6
        torus.firstMaterial = material(color: color, emission: color.withAlphaComponent(0.18))
        return SCNNode(geometry: torus)
    }

    private func polylineNode(points: [SCNVector3], color: NSColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: points)
        let indices = (0..<max(points.count - 1, 0)).flatMap { index in
            [Int32(index), Int32(index + 1)]
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial = material(color: color, emission: color.withAlphaComponent(0.18))
        return SCNNode(geometry: geometry)
    }

    private func material(
        color: NSColor,
        emission: NSColor,
        fillMode: SCNFillMode = .fill
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = emission
        material.lightingModel = .physicallyBased
        material.transparency = CGFloat(color.alphaComponent)
        material.isDoubleSided = true
        material.fillMode = fillMode
        return material
    }

    final class Coordinator: NSObject {
        weak var sceneView: CenteredOrbitSceneView?
        private weak var cameraNode: SCNNode?
        private weak var contentRoot: SCNNode?
        private var outputNodes: [String: SCNNode] = [:]
        private var inputNodes: [String: SCNNode] = [:]
        private var listenerNode: SCNNode?
        private var listenerIsPlaying = false
        private var yaw: CGFloat = 0
        private var pitch: CGFloat = 0.34
        private var distance: CGFloat = 4.15
        private var viewportMode: RendererViewportMode = .isometric
        private var isInteractive = true
        private var panStartYaw: CGFloat = 0
        private var panStartPitch: CGFloat = 0
        private var magnifyStartDistance: CGFloat = 4.15

        func configure(viewportMode: RendererViewportMode, isInteractive: Bool) {
            let modeChanged = self.viewportMode != viewportMode
            let interactionChanged = self.isInteractive != isInteractive
            self.viewportMode = viewportMode
            self.isInteractive = isInteractive

            if modeChanged || interactionChanged || !isInteractive {
                applyViewportPose()
                updateCamera()
            }
        }

        func attach(cameraNode: SCNNode, contentRoot: SCNNode) {
            self.cameraNode = cameraNode
            self.contentRoot = contentRoot
            applyViewportPose()
            updateCamera()
        }

        func updateScene(
            sceneModel: RendererSceneModel,
            isPlaying: Bool,
            meterState: OrbitalVUMeterViewState,
            makeOutputSpeaker: (RendererOutputSpeaker) -> SCNNode,
            makeInputSpeaker: (RendererInputSpeaker) -> SCNNode,
            makeReservedOutputMarker: (OrbitalVUMeterMarker, Int) -> SCNNode,
            makeListener: () -> SCNNode
        ) {
            guard let contentRoot else { return }

            var markersByID: [String: OrbitalVUMeterMarker] = [:]
            for marker in meterState.markers {
                markersByID[marker.channelID] = marker
            }
            let reservedMarkers = meterState.markers.filter { $0.role == .reservedPhysicalOutput }
            let outputIDs = Set(sceneModel.outputSpeakers.map(\.id) + reservedMarkers.map(\.channelID))
            for id in outputNodes.keys.filter({ !outputIDs.contains($0) }) {
                outputNodes.removeValue(forKey: id)?.removeFromParentNode()
            }

            for speaker in sceneModel.outputSpeakers {
                let node: SCNNode
                if let existingNode = outputNodes[speaker.id] {
                    node = existingNode
                } else {
                    let newNode = makeOutputSpeaker(speaker)
                    outputNodes[speaker.id] = newNode
                    contentRoot.addChildNode(newNode)
                    node = newNode
                }
                node.name = speaker.displayName
                node.position = speaker.position.scnVector
                applyOutputMeterMarker(
                    markersByID[speaker.id],
                    to: node,
                    isLFE: speaker.isLFE,
                    isReserved: false
                )
            }

            for (offset, marker) in reservedMarkers.enumerated() {
                let node: SCNNode
                if let existingNode = outputNodes[marker.channelID] {
                    node = existingNode
                } else {
                    let newNode = makeReservedOutputMarker(marker, offset)
                    outputNodes[marker.channelID] = newNode
                    contentRoot.addChildNode(newNode)
                    node = newNode
                }
                node.name = "Reserved Output \(marker.label)"
                applyOutputMeterMarker(
                    marker,
                    to: node,
                    isLFE: false,
                    isReserved: true
                )
            }

            let inputIDs = Set(sceneModel.inputSpeakers.map(\.id))
            for id in inputNodes.keys.filter({ !inputIDs.contains($0) }) {
                inputNodes.removeValue(forKey: id)?.removeFromParentNode()
            }

            for speaker in sceneModel.inputSpeakers {
                let node: SCNNode
                if let existingNode = inputNodes[speaker.id] {
                    node = existingNode
                } else {
                    let newNode = makeInputSpeaker(speaker)
                    inputNodes[speaker.id] = newNode
                    contentRoot.addChildNode(newNode)
                    node = newNode
                }
                node.name = speaker.displayName
                node.position = speaker.position.scnVector
            }

            if listenerNode == nil || listenerIsPlaying != isPlaying {
                listenerNode?.removeFromParentNode()
                let node = makeListener()
                listenerNode = node
                listenerIsPlaying = isPlaying
                contentRoot.addChildNode(node)
            }
        }

        private func applyOutputMeterMarker(
            _ marker: OrbitalVUMeterMarker?,
            to node: SCNNode,
            isLFE: Bool,
            isReserved: Bool
        ) {
            let level = CGFloat(marker?.normalizedLevel ?? 0).clamped(to: 0...1)
            let isActive = marker?.isActive == true
            let isHot = marker?.isHot == true
            let isClipping = marker?.isClipping == true
            let visual = outputMeterVisual(
                level: level,
                isActive: isActive,
                isHot: isHot,
                isClipping: isClipping,
                isLFE: isLFE,
                isReserved: isReserved
            )
            let scaleAmount: CGFloat
            if isReserved {
                scaleAmount = 1
            } else if isLFE {
                scaleAmount = isActive ? 1 + level * 0.32 : 1
            } else {
                scaleAmount = isActive ? 1 + level * 0.56 : 1
            }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = isActive ? 0.08 : 0
            node.geometry?.firstMaterial = meterMaterial(color: visual.color, emission: visual.emission)
            node.scale = SCNVector3(Float(scaleAmount), Float(scaleAmount), Float(scaleAmount))
            updateOutputMeterRing(
                on: node,
                color: visual.ringColor,
                isVisible: isHot || isClipping,
                isLFE: isLFE,
                isClipping: isClipping
            )
            SCNTransaction.commit()
        }

        private func updateOutputMeterRing(
            on node: SCNNode,
            color: NSColor,
            isVisible: Bool,
            isLFE: Bool,
            isClipping: Bool
        ) {
            let ringName = "orbital-vu-state-ring"
            guard isVisible else {
                node.childNode(withName: ringName, recursively: false)?.removeFromParentNode()
                return
            }

            let ringNode: SCNNode
            if let existing = node.childNode(withName: ringName, recursively: false) {
                ringNode = existing
            } else {
                let torus = SCNTorus(
                    ringRadius: isLFE ? 0.080 : 0.062,
                    pipeRadius: isClipping ? 0.0048 : 0.0034
                )
                torus.ringSegmentCount = 36
                torus.pipeSegmentCount = 6
                ringNode = SCNNode(geometry: torus)
                ringNode.name = ringName
                node.addChildNode(ringNode)
            }

            ringNode.geometry?.firstMaterial = meterMaterial(
                color: color,
                emission: color.withAlphaComponent(0.55)
            )
        }

        private func outputMeterVisual(
            level: CGFloat,
            isActive: Bool,
            isHot: Bool,
            isClipping: Bool,
            isLFE: Bool,
            isReserved: Bool
        ) -> (color: NSColor, emission: NSColor, ringColor: NSColor) {
            if LabTheme.palette.compressesLinearControlRampIntoActiveSegment {
                return daftPunkOutputMeterVisual(
                    level: level,
                    isActive: isActive,
                    isHot: isHot,
                    isClipping: isClipping,
                    isLFE: isLFE,
                    isReserved: isReserved
                )
            }

            if isReserved {
                let color = NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.31, alpha: 0.56)
                return (color, NSColor(calibratedRed: 0.012, green: 0.025, blue: 0.028, alpha: 1), color)
            }

            if isClipping {
                let color = NSColor(calibratedRed: 1.0, green: 0.16, blue: 0.20, alpha: 1)
                return (color, NSColor(calibratedRed: 0.76, green: 0.025, blue: 0.04, alpha: 1), color)
            }

            if isHot {
                let color = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.08, alpha: 1)
                return (color, NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.015, alpha: 1), color)
            }

            if isActive {
                let glow = 0.22 + Double(level) * 0.48
                if isLFE {
                    let color = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.18, alpha: 0.98)
                    return (
                        color,
                        NSColor(calibratedRed: 0.24 + glow * 0.34, green: 0.16 + glow * 0.22, blue: 0.025, alpha: 1),
                        color
                    )
                }

                let color = NSColor(calibratedRed: 0.38, green: 0.94, blue: 0.86, alpha: 1)
                return (
                    color,
                    NSColor(calibratedRed: 0.035 + glow * 0.18, green: 0.22 + glow * 0.34, blue: 0.22 + glow * 0.30, alpha: 1),
                    color
                )
            }

            if isLFE {
                let color = NSColor(calibratedRed: 0.48, green: 0.39, blue: 0.13, alpha: 0.72)
                return (color, NSColor(calibratedRed: 0.035, green: 0.028, blue: 0.012, alpha: 1), color)
            }

            let color = NSColor(calibratedRed: 0.20, green: 0.36, blue: 0.38, alpha: 0.58)
            return (color, NSColor(calibratedRed: 0.012, green: 0.045, blue: 0.048, alpha: 1), color)
        }

        private func daftPunkOutputMeterVisual(
            level: CGFloat,
            isActive: Bool,
            isHot: Bool,
            isClipping: Bool,
            isLFE: Bool,
            isReserved: Bool
        ) -> (color: NSColor, emission: NSColor, ringColor: NSColor) {
            if isReserved {
                let color = NSColor(calibratedRed: 52 / 255, green: 64 / 255, blue: 71 / 255, alpha: 0.56)
                return (color, NSColor(calibratedRed: 0.012, green: 0.025, blue: 0.028, alpha: 1), color)
            }

            if isClipping {
                let color = NSColor(calibratedRed: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1)
                return (color, NSColor(calibratedRed: 0.72, green: 0.03, blue: 0.035, alpha: 1), color)
            }

            if isHot {
                let color = NSColor(calibratedRed: 251 / 255, green: 146 / 255, blue: 60 / 255, alpha: 1)
                return (color, NSColor(calibratedRed: 0.58, green: 0.20, blue: 0.035, alpha: 1), color)
            }

            if isActive {
                let color = isLFE
                    ? NSColor(calibratedRed: 253 / 255, green: 224 / 255, blue: 71 / 255, alpha: 0.98)
                    : daftPunkSceneMeterColor(level: level)
                let glow = 0.20 + Double(level) * 0.48
                return (
                    color,
                    color.blended(withFraction: min(glow, 0.68), of: .white) ?? color,
                    color
                )
            }

            let inactive = isLFE
                ? NSColor(calibratedRed: 0.40, green: 0.36, blue: 0.17, alpha: 0.72)
                : NSColor(calibratedRed: 52 / 255, green: 64 / 255, blue: 71 / 255, alpha: 0.58)
            return (inactive, NSColor(calibratedRed: 0.012, green: 0.025, blue: 0.028, alpha: 1), inactive)
        }

        private func daftPunkSceneMeterColor(level: CGFloat) -> NSColor {
            let normalized = min(max(level, 0), 1)
            let stops: [(position: CGFloat, color: NSColor)] = [
                (0.00, NSColor(calibratedRed: 167 / 255, green: 139 / 255, blue: 250 / 255, alpha: 1)),
                (0.18, NSColor(calibratedRed: 91 / 255, green: 140 / 255, blue: 255 / 255, alpha: 1)),
                (0.34, NSColor(calibratedRed: 34 / 255, green: 211 / 255, blue: 238 / 255, alpha: 1)),
                (0.50, NSColor(calibratedRed: 52 / 255, green: 211 / 255, blue: 153 / 255, alpha: 1)),
                (0.66, NSColor(calibratedRed: 253 / 255, green: 224 / 255, blue: 71 / 255, alpha: 1)),
                (0.82, NSColor(calibratedRed: 251 / 255, green: 146 / 255, blue: 60 / 255, alpha: 1)),
                (1.00, NSColor(calibratedRed: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1))
            ]

            return stops.last { normalized >= $0.position }?.color ?? stops[0].color
        }

        private func meterMaterial(color: NSColor, emission: NSColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = emission
            material.lightingModel = .physicallyBased
            material.transparency = CGFloat(color.alphaComponent)
            material.isDoubleSided = true
            return material
        }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard isInteractive else { return }

            switch gesture.state {
            case .began:
                panStartYaw = yaw
                panStartPitch = pitch
            case .changed:
                let translation = gesture.translation(in: gesture.view)
                yaw = panStartYaw - translation.x * 0.008
                pitch = (panStartPitch + translation.y * 0.006).clamped(to: -0.95...0.95)
                updateCamera()
            default:
                break
            }
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            guard isInteractive else { return }

            switch gesture.state {
            case .began:
                magnifyStartDistance = distance
            case .changed:
                distance = (magnifyStartDistance / max(0.25, 1 + gesture.magnification)).clamped(to: 2.2...7.4)
                updateCamera()
            default:
                break
            }
        }

        func handleScroll(deltaY: CGFloat) {
            guard isInteractive else { return }

            distance = (distance + deltaY * 0.018).clamped(to: 2.2...7.4)
            updateCamera()
        }

        private func applyViewportPose() {
            let pose = viewportMode.cameraPose
            yaw = pose.yaw
            pitch = pose.pitch
            distance = pose.distance
        }

        private func updateCamera() {
            guard let cameraNode else { return }
            let horizontal = cos(pitch) * distance
            let x = sin(yaw) * horizontal
            let y = sin(pitch) * distance
            let z = cos(yaw) * horizontal
            cameraNode.position = SCNVector3(Float(x), Float(y), Float(z))
            cameraNode.look(at: SCNVector3(0, 0, 0))
        }
    }
}

private final class CenteredOrbitSceneView: SCNView {
    weak var orbitCoordinator: SonicSphereRendererSceneView.Coordinator?
    var isOrbitInteractionEnabled = true

    override func scrollWheel(with event: NSEvent) {
        guard isOrbitInteractionEnabled else {
            super.scrollWheel(with: event)
            return
        }

        orbitCoordinator?.handleScroll(deltaY: event.scrollingDeltaY)
    }
}

private extension RendererVector3 {
    var scnVector: SCNVector3 {
        SCNVector3(Float(x), Float(y), Float(z))
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
