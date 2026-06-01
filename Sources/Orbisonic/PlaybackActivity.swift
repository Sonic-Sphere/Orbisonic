import Foundation

/// A small, UI-agnostic description of in-flight background work (decoding,
/// converting, switching the output device, prefetching). Published by the
/// view model and encoded into the web state so both the native UI and the web
/// control page can show a determinate or indeterminate progress affordance
/// instead of freezing silently.
struct PlaybackActivity: Equatable, Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case idle
        case probing
        case decoding
        case converting
        case switchingOutput
        case preparing
    }

    var phase: Phase
    var detail: String
    /// Fractional progress in 0...1 when known; `nil` means indeterminate.
    var progress: Double?

    init(phase: Phase, detail: String = "", progress: Double? = nil) {
        self.phase = phase
        self.detail = detail
        self.progress = progress
    }

    static let idle = PlaybackActivity(phase: .idle)

    var isBusy: Bool { phase != .idle }
    var isIndeterminate: Bool { progress == nil }

    var clampedProgress: Double? {
        guard let progress else { return nil }
        return Swift.min(1.0, Swift.max(0.0, progress))
    }

    var label: String {
        guard phase != .idle else { return "" }

        if phase == .switchingOutput {
            let target = detail.isEmpty ? "output device" : detail
            return "Switching output to \(target)…"
        }

        let verb: String
        switch phase {
        case .probing: verb = "Reading"
        case .decoding: verb = "Decoding"
        case .converting: verb = "Converting"
        case .preparing: verb = "Preparing"
        case .idle, .switchingOutput: verb = ""
        }

        var text = verb
        if !detail.isEmpty { text += " \(detail)" }
        text += "…"
        if let pct = clampedProgress {
            text += " \(Int((pct * 100).rounded()))%"
        }
        return text
    }
}
