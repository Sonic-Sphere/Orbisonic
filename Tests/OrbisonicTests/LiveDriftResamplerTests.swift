import XCTest
@testable import Orbisonic

final class LiveDriftResamplerTests: XCTestCase {

    // MARK: cubicInterpolate (4-tap Catmull-Rom)

    func testCubicInterpolateReturnsP1AtFractionZero() {
        let value = LiveDriftResampler.cubicInterpolate(10, 20, 30, 40, fraction: 0)
        XCTAssertEqual(value, 20, accuracy: 1e-5)
    }

    func testCubicInterpolateReturnsP2AtFractionOne() {
        let value = LiveDriftResampler.cubicInterpolate(10, 20, 30, 40, fraction: 1)
        XCTAssertEqual(value, 30, accuracy: 1e-5)
    }

    func testCubicInterpolateReproducesLinearRampExactly() {
        // Colinear taps: cubic Hermite must reproduce the straight line.
        let value = LiveDriftResampler.cubicInterpolate(0, 1, 2, 3, fraction: 0.5)
        XCTAssertEqual(value, 1.5, accuracy: 1e-5)
    }

    func testCubicInterpolateHoldsConstantInput() {
        let value = LiveDriftResampler.cubicInterpolate(5, 5, 5, 5, fraction: 0.37)
        XCTAssertEqual(value, 5, accuracy: 1e-5)
    }

    // MARK: LiveDriftController

    func testRateCorrectionIsZeroAtTarget() {
        let controller = LiveDriftController()
        XCTAssertEqual(controller.rateCorrection(availableFrames: 6_615, targetFrames: 6_615), 0, accuracy: 1e-9)
    }

    func testRateCorrectionIsPositiveWhenBufferAboveTarget() {
        let controller = LiveDriftController()
        XCTAssertGreaterThan(controller.rateCorrection(availableFrames: 7_000, targetFrames: 6_615), 0)
    }

    func testRateCorrectionIsNegativeWhenBufferBelowTarget() {
        let controller = LiveDriftController()
        XCTAssertLessThan(controller.rateCorrection(availableFrames: 6_000, targetFrames: 6_615), 0)
    }

    func testRateCorrectionClampsToMaximumWhenFarAboveTarget() {
        let controller = LiveDriftController(proportionalGain: 0.5, maxCorrection: 0.05)
        XCTAssertEqual(controller.rateCorrection(availableFrames: 1_000_000, targetFrames: 6_615), 0.05, accuracy: 1e-9)
    }

    func testRateCorrectionClampsToMinimumWhenFarBelowTarget() {
        let controller = LiveDriftController(proportionalGain: 0.5, maxCorrection: 0.05)
        XCTAssertEqual(controller.rateCorrection(availableFrames: 0, targetFrames: 6_615), -0.05, accuracy: 1e-9)
    }

    func testRateCorrectionIsZeroWhenTargetNonPositive() {
        let controller = LiveDriftController()
        XCTAssertEqual(controller.rateCorrection(availableFrames: 5_000, targetFrames: 0), 0, accuracy: 1e-9)
    }

    // MARK: LiveSampleRateConverter.framesToConsume

    func testFramesToConsumeAtUnityStep() {
        let converter = LiveSampleRateConverter(channelCount: 2)
        XCTAssertEqual(converter.framesToConsume(outputFrames: 512, step: 1.0), 512)
    }

    func testFramesToConsumeFloorsAtFractionalStep() {
        let converter = LiveSampleRateConverter(channelCount: 2)
        // 44100/48000 = 0.91875; 512 * 0.91875 = 470.4 -> floor 470
        XCTAssertEqual(converter.framesToConsume(outputFrames: 512, step: 44_100.0 / 48_000.0), 470)
    }

    // MARK: LiveSampleRateConverter.process

    func testProcessPassesThroughAtUnityStep() {
        let converter = LiveSampleRateConverter(channelCount: 1)
        let frames = 64
        let step = 1.0
        let consumed = converter.framesToConsume(outputFrames: frames, step: step)
        XCTAssertEqual(consumed, frames)

        var input = [Float](repeating: 0, count: consumed)
        for i in 0..<consumed { input[i] = Float(i) * 0.5 - 3 }
        var output = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 1)

        converter.process(inputs: [input], inputFrameCount: consumed, step: step, outputFrames: frames, into: &output)

        for i in 0..<frames {
            XCTAssertEqual(output[0][i], input[i], accuracy: 1e-4, "mismatch at \(i)")
        }
    }

    func testProcessUpsamplesLinearRampExactly() {
        let converter = LiveSampleRateConverter(channelCount: 1)
        let frames = 128
        let step = 0.5
        let consumed = converter.framesToConsume(outputFrames: frames, step: step)

        var input = [Float](repeating: 0, count: consumed)
        for i in 0..<consumed { input[i] = Float(i) }
        var output = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 1)

        converter.process(inputs: [input], inputFrameCount: consumed, step: step, outputFrames: frames, into: &output)

        // Interior samples (away from the history boundary) must equal the
        // exact source position phase + j*step for a linear ramp.
        for j in 8..<(frames - 8) {
            XCTAssertEqual(output[0][j], Float(Double(j) * step), accuracy: 1e-3, "mismatch at \(j)")
        }
    }

    func testProcessAdvancesPhaseByFractionalRemainder() {
        let converter = LiveSampleRateConverter(channelCount: 1)
        let frames = 512
        let step = 44_100.0 / 48_000.0
        let consumed = converter.framesToConsume(outputFrames: frames, step: step)

        var input = [Float](repeating: 0, count: consumed)
        for i in 0..<consumed { input[i] = Float(i) }
        var output = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 1)

        converter.process(inputs: [input], inputFrameCount: consumed, step: step, outputFrames: frames, into: &output)

        let expectedPhase = (0 + Double(frames) * step) - Double(consumed)
        XCTAssertEqual(converter.phase, expectedPhase, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(converter.phase, 0)
        XCTAssertLessThan(converter.phase, 1)
    }

    func testResetReturnsPhaseToZero() {
        let converter = LiveSampleRateConverter(channelCount: 1)
        let frames = 100
        let step = 0.91875
        let consumed = converter.framesToConsume(outputFrames: frames, step: step)
        var input = [Float](repeating: 1, count: consumed)
        var output = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 1)
        converter.process(inputs: [input], inputFrameCount: consumed, step: step, outputFrames: frames, into: &output)
        XCTAssertGreaterThan(converter.phase, 0)

        converter.reset()
        XCTAssertEqual(converter.phase, 0, accuracy: 1e-9)
        _ = input
    }
}
