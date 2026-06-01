import Foundation

/// Why the next-track full-audio preload was or was not started, for a single
/// candidate. Drives the user-facing status surfaces and the preload gate.
/// Framework-free so it is unit-testable without AVFoundation/CoreAudio.
enum NextTrackPreloadDecision: Equatable {
    case allow
    case skipLowMemory
    case skipUnknownSize
}

/// Pure adaptive budget: should we spend `estimatedBytes` of resident RAM to
/// fully decode the next track, given `availableBytes` free right now?
///
/// Policy: allow only when the estimate is known (> 0), there is some RAM
/// available, and the estimate fits within `fraction` of the available RAM.
/// `fraction` defaults to 0.5 at the call site (see `OrbisonicViewModel`).
func planNextTrackPreload(
    estimatedBytes: Int?,
    availableBytes: Int,
    fraction: Double
) -> NextTrackPreloadDecision {
    guard let estimatedBytes, estimatedBytes > 0 else { return .skipUnknownSize }
    guard availableBytes > 0 else { return .skipLowMemory }
    let budget = Double(availableBytes) * fraction
    return Double(estimatedBytes) <= budget ? .allow : .skipLowMemory
}

/// User-facing status of the next-track preload feature. `idle` = enabled but
/// nothing to do yet; `noNextTrack` = enabled but the queue has no distinct
/// next track. `skipped` carries the budget reason so the UI can explain it.
enum NextTrackPreloadStatus: Equatable {
    case idle
    case preparing
    case ready
    case skippedLowMemory
    case skippedUnknownSize
    case noNextTrack

    /// Short label for chips / captions.
    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing…"
        case .ready: return "Ready"
        case .skippedLowMemory: return "Skipped (low memory)"
        case .skippedUnknownSize: return "Skipped (unknown size)"
        case .noNextTrack: return "No next track"
        }
    }

    /// Stable token for the web JSON (lower-camel, parser-friendly).
    var webToken: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .skippedLowMemory: return "skippedLowMemory"
        case .skippedUnknownSize: return "skippedUnknownSize"
        case .noNextTrack: return "noNextTrack"
        }
    }

    var isBusy: Bool { self == .preparing }
}
