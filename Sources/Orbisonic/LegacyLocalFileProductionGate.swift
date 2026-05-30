import AudioContracts
import AudioCore
import AudioImport
import Foundation

struct LegacyLocalFileSourceDescription: Equatable {
    let id: String
    let displayName: String
    let sampleRate: Double
    let channelCount: Int
    let durationFrames: Int64?
    let codecDescription: String?
    let containerDescription: String?

    var sampleRateText: String {
        LegacyLocalFileProductionGate.formatSampleRate(sampleRate)
    }
}

struct LegacyLocalFileProductionGateError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum LegacyLocalFileProductionAdmission: Equatable {
    case allowed(reason: String)
    case blocked(reason: String)

    var blocksPlayback: Bool {
        if case .blocked = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .allowed(let reason), .blocked(let reason):
            reason
        }
    }
}

struct LegacyLocalFileProductionGate {
    static func admission(
        for source: LegacyLocalFileSourceDescription,
        monitorRoute: OutputRouteInfo,
        systemOutputRoute: OutputRouteInfo,
        rendererRoute: OutputRouteInfo,
        rendererOutputSelected: Bool,
        isSessionRunning: Bool = true
    ) -> LegacyLocalFileProductionAdmission {
        guard rendererOutputSelected else {
            return .allowed(
                reason: "Legacy Normal Monitor desktop-only playback; Pure Audio Dante production is not active."
            )
        }

        guard source.sampleRate.isFinite, source.sampleRate > 0 else {
            return .blocked(reason: "Local file sample rate is unknown. Production playback requires a known sample rate.")
        }
        guard SourceDescriptor.sourceChannelLimit.contains(source.channelCount) else {
            return .blocked(
                reason: "Local file channel count \(source.channelCount) is outside the supported 1...64 source range."
            )
        }

        guard rendererRoute.isAvailable else {
            return .blocked(reason: "Pure Audio Dante production requires a selected renderer output route.")
        }
        guard rendererRoute.isDanteVirtualSoundcard else {
            return .blocked(
                reason: "Pure Audio production requires a validated Dante renderer route. \(rendererRoute.deviceName) is not a Dante Virtual Soundcard route."
            )
        }
        guard rendererRoute.isSelectableOutputTarget else {
            return .blocked(reason: outputRiskMessage(for: rendererRoute, role: "Dante renderer"))
        }

        let desktopRoute = monitorRoute.isAvailable ? monitorRoute : systemOutputRoute
        guard desktopRoute.isAvailable else {
            return .blocked(reason: "Pure Audio production requires an available desktop monitor route.")
        }
        guard desktopRoute.isSelectableOutputTarget else {
            return .blocked(reason: outputRiskMessage(for: desktopRoute, role: "desktop monitor"))
        }

        let sessionRate: AudioSampleRate
        do {
            sessionRate = try AudioSampleRate(hertz: rendererRoute.nominalSampleRate)
        } catch {
            return .blocked(reason: "Dante renderer route sample rate is invalid or unknown.")
        }

        let sourceRate: AudioSampleRate
        do {
            sourceRate = try AudioSampleRate(hertz: source.sampleRate)
        } catch {
            return .blocked(reason: "Local file sample rate is invalid.")
        }

        let routeValidator = RouteCapabilityValidator()
        let danteCapability = routeValidator.danteRouteCapability(from: rendererRoute)
        let desktopDescriptor = routeValidator.outputRouteDescriptor(from: desktopRoute)
        let layout = AudioChannelLayoutDescriptor.fallbackLayout(channelCount: source.channelCount)
        let sourceDescriptor = SourceDescriptor(
            id: source.id,
            kind: .localFile,
            sampleRate: sourceRate,
            channelCount: source.channelCount,
            layout: layout,
            durationFrames: source.durationFrames,
            isLive: false,
            codecDescription: source.codecDescription,
            originalPath: source.id
        )
        let planningSourceDescriptor = sourceRate.matches(sessionRate) ? sourceDescriptor : nil

        let plan = AudioSessionPlanner().plan(
            AudioSessionPlanRequest(
                desiredSampleRate: sessionRate,
                desiredDesktopRoute: desktopDescriptor,
                desiredDanteRoute: danteCapability,
                desiredSource: planningSourceDescriptor,
                sourceReadiness: .sessionNative,
                intent: .production
            )
        )

        guard plan.isAccepted, let sessionFormat = plan.plannedSessionFormat else {
            return .blocked(reason: productionBlockedMessage(from: plan))
        }

        let readiness = LocalAssetProbeResult(
            path: source.id,
            durationFrames: source.durationFrames,
            durationSeconds: durationSeconds(source.durationFrames, sampleRate: sourceRate),
            sourceSampleRate: sourceRate,
            channelCount: source.channelCount,
            codecDescription: source.codecDescription,
            channelLayout: layout,
            containerDescription: source.containerDescription,
            estimatedDecodedBytes: estimatedDecodedBytes(source.durationFrames, channelCount: source.channelCount)
        ).readiness(
            for: sessionFormat,
            routeCapabilities: [danteCapability],
            isSessionRunning: isSessionRunning
        )

        switch readiness {
        case .productionReady:
            return .allowed(
                reason: "Local file matches the Pure Audio production session rate \(formatSampleRate(sessionRate.hertz))."
            )
        case .requiresOfflineImport(let reason, let targetSampleRate):
            // Resolvable mismatch: playback converts an offline managed copy to
            // the session rate before the engine sees it, so production is allowed.
            return .allowed(
                reason: "Preparing a managed \(formatSampleRate(targetSampleRate.hertz)) copy for Pure Audio production. \(reason)"
            )
        case .canRestartStoppedSessionAtFileRate(let reason, _):
            return .allowed(
                reason: "Preparing a managed session-rate copy for Pure Audio production. \(reason)"
            )
        case .unsupported(let reason), .desktopPreviewOnly(let reason):
            return .blocked(reason: reason)
        }
    }

    static func formatSampleRate(_ sampleRate: Double) -> String {
        guard sampleRate.isFinite, sampleRate > 0 else { return "unknown rate" }
        let kilohertz = sampleRate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return "\(Int(kilohertz.rounded())) kHz"
        }
        return String(format: "%.1f kHz", kilohertz)
    }

    private static func outputRiskMessage(for route: OutputRouteInfo, role: String) -> String {
        switch route.routeRisk {
        case .feedbackLoop(let name):
            return "Blocked: \(name) would feed Orbisonic output back into an input loopback. Choose a safe \(role) output."
        case .virtualOutput(let name):
            return "Blocked: \(name) is a virtual output. Pure Audio production requires an explicitly validated Dante route."
        case .unavailable:
            return "No \(role) route is available."
        case .safe:
            return "\(role) route is safe."
        }
    }

    private static func productionBlockedMessage(from plan: AudioSessionPlan) -> String {
        let messages = plan.validationMessages.filter { !$0.isEmpty }
        if !messages.isEmpty {
            return messages.joined(separator: " ")
        }
        let errors = plan.validationErrors.map(\.description)
        if !errors.isEmpty {
            return errors.joined(separator: " ")
        }
        return "Pure Audio production planning rejected this local file."
    }

    private static func durationSeconds(_ frameCount: Int64?, sampleRate: AudioSampleRate) -> Double? {
        guard let frameCount, frameCount >= 0 else { return nil }
        return Double(frameCount) / sampleRate.hertz
    }

    private static func estimatedDecodedBytes(_ frameCount: Int64?, channelCount: Int) -> Int64? {
        guard let frameCount, frameCount >= 0, channelCount > 0 else { return nil }
        let estimate = Double(frameCount) * Double(channelCount) * Double(MemoryLayout<Float>.size)
        guard estimate.isFinite, estimate >= 0, estimate <= Double(Int64.max) else { return nil }
        return Int64(estimate.rounded(.up))
    }
}

extension AudioAssetDescriptor {
    var legacyLocalFileSourceDescription: LegacyLocalFileSourceDescription {
        LegacyLocalFileSourceDescription(
            id: url.path,
            displayName: url.lastPathComponent,
            sampleRate: sourceSampleRate,
            channelCount: channelCount,
            durationFrames: durationFrames.map { Int64($0) },
            codecDescription: codecDescription,
            containerDescription: containerDescription
        )
    }
}

extension LoadedAudioFile {
    var legacyLocalFileSourceDescription: LegacyLocalFileSourceDescription {
        LegacyLocalFileSourceDescription(
            id: url.path,
            displayName: metadata.fileName,
            sampleRate: sampleRate,
            channelCount: layout.channelCount,
            durationFrames: Int64(frameCount),
            codecDescription: metadata.codecName,
            containerDescription: metadata.containerName
        )
    }
}

extension AudioSourceMetadata {
    func legacyLocalFileSourceDescription(path: String) -> LegacyLocalFileSourceDescription {
        let frames = sampleRate > 0 && duration.isFinite && duration >= 0
            ? Int64((duration * sampleRate).rounded(.toNearestOrAwayFromZero))
            : nil
        return LegacyLocalFileSourceDescription(
            id: path,
            displayName: fileName,
            sampleRate: sampleRate,
            channelCount: channelCount,
            durationFrames: frames,
            codecDescription: codecName,
            containerDescription: containerName
        )
    }
}
