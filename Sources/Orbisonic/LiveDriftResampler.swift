import Foundation

/// Pure helpers for drift-compensating sample-rate conversion on the live
/// input path. The capture clock (e.g. Spotify's 44.1 kHz virtual device) and
/// the Dante output clock (48 kHz) free-run independently, so a fixed-ratio
/// resampler cannot absorb their drift and the ring buffer slowly fills or
/// drains, producing popping (high-water drops) and cutouts (underflow).
///
/// These pieces let `LiveAudioPipe.render` resample the ring at a *variable*
/// ratio nudged by the measured buffer fill, holding latency at the target.
enum LiveDriftResampler {

    /// 4-tap Catmull-Rom (cubic Hermite) interpolation between `p1` and `p2`.
    /// `fraction` is the sub-sample position in [0, 1]; `p0` and `p3` are the
    /// neighbouring samples that shape the tangent. Reproduces linear and
    /// constant signals exactly; returns `p1` at fraction 0 and `p2` at 1.
    static func cubicInterpolate(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, fraction frac: Float) -> Float {
        let a = (3 * (p1 - p2) + p3 - p0)
        let b = (2 * p0 - 5 * p1 + 4 * p2 - p3)
        let c = (p2 - p0)
        return p1 + 0.5 * frac * (c + frac * (b + frac * a))
    }
}

/// Proportional controller that converts the live ring's fill error into a
/// fractional rate correction. Output is the relative nudge applied to the
/// nominal resample step: positive drains a too-full buffer (consume input
/// faster), negative refills a draining one.
struct LiveDriftController {
    let proportionalGain: Double
    let maxCorrection: Double

    init(proportionalGain: Double = 0.1, maxCorrection: Double = 0.05) {
        self.proportionalGain = proportionalGain
        self.maxCorrection = max(maxCorrection, 0)
    }

    func rateCorrection(availableFrames: Int, targetFrames: Int) -> Double {
        guard targetFrames > 0 else { return 0 }
        let error = Double(availableFrames - targetFrames) / Double(targetFrames)
        let correction = proportionalGain * error
        return min(max(correction, -maxCorrection), maxCorrection)
    }
}

/// Stateful variable-ratio resampler shared across channels. Holds a single
/// fractional read phase and a short per-channel history so cubic windows stay
/// continuous across render blocks. Not thread-safe: only the audio render
/// thread touches it.
final class LiveSampleRateConverter {
    let channelCount: Int
    private(set) var phase: Double = 0
    private var history: [[Float]]   // [channel][3], most-recent sample last

    private static let historyLength = 3

    init(channelCount: Int) {
        self.channelCount = max(channelCount, 1)
        history = Array(
            repeating: [Float](repeating: 0, count: LiveSampleRateConverter.historyLength),
            count: self.channelCount
        )
    }

    /// Number of new input frames consumed to produce `outputFrames` outputs at
    /// `step` input-frames-per-output-frame, given the current phase. Deterministic:
    /// the caller reads exactly this many frames from each ring.
    func framesToConsume(outputFrames: Int, step: Double) -> Int {
        guard outputFrames > 0, step > 0 else { return 0 }
        return Int((phase + Double(outputFrames) * step).rounded(.down))
    }

    /// Resamples `outputFrames` samples per channel from `inputs` (each holding
    /// at least `framesToConsume(outputFrames:step:)` new frames) into `outputs`,
    /// advancing the phase and updating history.
    func process(
        inputs: [[Float]],
        inputFrameCount: Int,
        step: Double,
        outputFrames: Int,
        into outputs: inout [[Float]]
    ) {
        guard outputFrames > 0 else { return }
        guard step > 0 else {
            for channel in 0..<min(channelCount, outputs.count) {
                for j in 0..<min(outputFrames, outputs[channel].count) { outputs[channel][j] = 0 }
            }
            return
        }

        let consumed = Int((phase + Double(outputFrames) * step).rounded(.down))
        let activeChannels = min(channelCount, min(inputs.count, outputs.count))

        for channel in 0..<activeChannels {
            let input = inputs[channel]
            let channelHistory = history[channel]

            func sample(at index: Int) -> Float {
                if index < 0 {
                    let historyIndex = LiveSampleRateConverter.historyLength + index
                    if historyIndex < 0 { return channelHistory.first ?? 0 }
                    return channelHistory[historyIndex]
                }
                guard inputFrameCount > 0 else { return 0 }
                if index >= inputFrameCount { return input[inputFrameCount - 1] }
                return input[index]
            }

            for j in 0..<outputFrames {
                let srcPos = phase + Double(j) * step
                let base = Int(srcPos.rounded(.down))
                let frac = Float(srcPos - Double(base))
                outputs[channel][j] = LiveDriftResampler.cubicInterpolate(
                    sample(at: base - 1),
                    sample(at: base),
                    sample(at: base + 1),
                    sample(at: base + 2),
                    fraction: frac
                )
            }

            // Carry the last `historyLength` consumed samples into history so the
            // next block's negative-index taps stay continuous.
            var newHistory = channelHistory
            for m in 0..<LiveSampleRateConverter.historyLength {
                newHistory[m] = sample(at: consumed - LiveSampleRateConverter.historyLength + m)
            }
            history[channel] = newHistory
        }

        phase = phase + Double(outputFrames) * step - Double(consumed)
    }

    func reset() {
        phase = 0
        for channel in 0..<channelCount {
            for m in 0..<LiveSampleRateConverter.historyLength { history[channel][m] = 0 }
        }
    }
}
