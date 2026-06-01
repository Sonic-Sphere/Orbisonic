import Accelerate
import AVFoundation

enum RendererMatrixSampleRenderer {
    static func renderSampleBuffers(
        matrix: RendererMatrix,
        sourceBuffers: [AVAudioPCMBuffer],
        startFrame: Int,
        frameCount: Int
    ) -> (sampleBuffers: [[Float]], frameCount: Int) {
        let frames = renderedFrameCount(
            matrix: matrix,
            sourceBuffers: sourceBuffers,
            startFrame: startFrame,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else { return ([], 0) }

        var outputBuffers = Array(
            repeating: Array(repeating: Float(0), count: frames),
            count: matrix.outputCount
        )
        let renderedFrames = render(
            matrix: matrix,
            sourceBuffers: sourceBuffers,
            startFrame: startFrame,
            frameCount: frames,
            outputBuffers: &outputBuffers
        )
        return (outputBuffers, renderedFrames)
    }

    static func renderSampleBuffers(
        matrix: RendererMatrix,
        inputSamples: [[Float]],
        frameCount: Int
    ) -> (sampleBuffers: [[Float]], frameCount: Int) {
        let frames = renderedFrameCount(
            matrix: matrix,
            inputSamples: inputSamples,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else { return ([], 0) }

        var outputBuffers = Array(
            repeating: Array(repeating: Float(0), count: frames),
            count: matrix.outputCount
        )
        let renderedFrames = render(
            matrix: matrix,
            inputSamples: inputSamples,
            frameCount: frames,
            outputBuffers: &outputBuffers
        )
        return (outputBuffers, renderedFrames)
    }

    static func renderSampleBuffers(
        matrix: RendererMatrix,
        sourceBuffer: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int
    ) -> (sampleBuffers: [[Float]], frameCount: Int) {
        let frames = renderedFrameCount(
            matrix: matrix,
            sourceBuffer: sourceBuffer,
            startFrame: startFrame,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else { return ([], 0) }

        var outputBuffers = Array(
            repeating: Array(repeating: Float(0), count: frames),
            count: matrix.outputCount
        )
        let renderedFrames = render(
            matrix: matrix,
            sourceBuffer: sourceBuffer,
            startFrame: startFrame,
            frameCount: frames,
            outputBuffers: &outputBuffers
        )
        return (outputBuffers, renderedFrames)
    }

    @discardableResult
    static func render(
        matrix: RendererMatrix,
        sourceBuffers: [AVAudioPCMBuffer],
        startFrame: Int,
        frameCount: Int,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        clearFrameCount: Int? = nil
    ) -> Int {
        clear(outputBuffers: outputBuffers, frameCount: clearFrameCount ?? frameCount)

        let frames = renderedFrameCount(
            matrix: matrix,
            sourceBuffers: sourceBuffers,
            startFrame: startFrame,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else { return 0 }

        let outputLimit = min(outputBuffers.count, matrix.outputCount)
        guard outputLimit > 0 else { return 0 }
        let sourceOffset = max(startFrame, 0)

        for inputIndex in 0..<matrix.inputCount {
            guard let channelData = sourceBuffers[inputIndex].floatChannelData else { continue }
            let input = channelData[0].advanced(by: sourceOffset)
            renderInput(input, matrix: matrix, inputIndex: inputIndex, frameCount: frames, outputBuffers: outputBuffers, outputLimit: outputLimit)
        }

        return frames
    }

    @discardableResult
    static func render(
        matrix: RendererMatrix,
        inputSamples: [[Float]],
        frameCount: Int,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        clearFrameCount: Int? = nil
    ) -> Int {
        clear(outputBuffers: outputBuffers, frameCount: clearFrameCount ?? frameCount)

        let frames = renderedFrameCount(
            matrix: matrix,
            inputSamples: inputSamples,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else { return 0 }

        let outputLimit = min(outputBuffers.count, matrix.outputCount)
        guard outputLimit > 0 else { return 0 }

        for inputIndex in 0..<matrix.inputCount {
            inputSamples[inputIndex].withUnsafeBufferPointer { inputBuffer in
                guard let input = inputBuffer.baseAddress else { return }
                renderInput(input, matrix: matrix, inputIndex: inputIndex, frameCount: frames, outputBuffers: outputBuffers, outputLimit: outputLimit)
            }
        }

        return frames
    }

    @discardableResult
    static func render(
        matrix: RendererMatrix,
        inputSamples: [[Float]],
        frameCount: Int,
        outputBuffers: inout [[Float]]
    ) -> Int {
        let frames = renderedFrameCount(
            matrix: matrix,
            inputSamples: inputSamples,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else {
            outputBuffers.removeAll()
            return 0
        }

        normalize(outputBuffers: &outputBuffers, outputCount: matrix.outputCount, frameCount: frames)
        let outputLimit = min(outputBuffers.count, matrix.outputCount)
        guard outputLimit > 0 else { return 0 }

        for inputIndex in 0..<matrix.inputCount {
            let gains = matrix.gains[inputIndex]
            inputSamples[inputIndex].withUnsafeBufferPointer { inputBuffer in
                guard let input = inputBuffer.baseAddress else { return }
                for outputIndex in 0..<outputLimit {
                    guard gains.indices.contains(outputIndex) else { continue }
                    var gain = Float(gains[outputIndex])
                    guard abs(gain) > 0.000_001 else { continue }

                    outputBuffers[outputIndex].withUnsafeMutableBufferPointer { outputBuffer in
                        guard let output = outputBuffer.baseAddress else { return }
                        vDSP_vsma(input, 1, &gain, output, 1, output, 1, vDSP_Length(frames))
                    }
                }
            }
        }

        return frames
    }

    @discardableResult
    static func render(
        matrix: RendererMatrix,
        sourceBuffers: [AVAudioPCMBuffer],
        startFrame: Int,
        frameCount: Int,
        outputBuffers: inout [[Float]]
    ) -> Int {
        let frames = renderedFrameCount(
            matrix: matrix,
            sourceBuffers: sourceBuffers,
            startFrame: startFrame,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else {
            outputBuffers.removeAll()
            return 0
        }

        normalize(outputBuffers: &outputBuffers, outputCount: matrix.outputCount, frameCount: frames)
        let outputLimit = min(outputBuffers.count, matrix.outputCount)
        guard outputLimit > 0 else { return 0 }
        let sourceOffset = max(startFrame, 0)

        for inputIndex in 0..<matrix.inputCount {
            guard let channelData = sourceBuffers[inputIndex].floatChannelData else { continue }
            let input = channelData[0].advanced(by: sourceOffset)
            let gains = matrix.gains[inputIndex]
            for outputIndex in 0..<outputLimit {
                guard gains.indices.contains(outputIndex) else { continue }
                var gain = Float(gains[outputIndex])
                guard abs(gain) > 0.000_001 else { continue }

                outputBuffers[outputIndex].withUnsafeMutableBufferPointer { outputBuffer in
                    guard let output = outputBuffer.baseAddress else { return }
                    vDSP_vsma(input, 1, &gain, output, 1, output, 1, vDSP_Length(frames))
                }
            }
        }

        return frames
    }

    @discardableResult
    static func render(
        matrix: RendererMatrix,
        sourceBuffer: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int,
        outputBuffers: inout [[Float]]
    ) -> Int {
        let frames = renderedFrameCount(
            matrix: matrix,
            sourceBuffer: sourceBuffer,
            startFrame: startFrame,
            requestedFrameCount: frameCount
        )
        guard frames > 0 else {
            outputBuffers.removeAll()
            return 0
        }

        normalize(outputBuffers: &outputBuffers, outputCount: matrix.outputCount, frameCount: frames)
        let outputLimit = min(outputBuffers.count, matrix.outputCount)
        guard outputLimit > 0,
              let channelData = sourceBuffer.floatChannelData
        else { return 0 }

        let sourceOffset = max(startFrame, 0)
        for inputIndex in 0..<matrix.inputCount {
            let input = channelData[inputIndex].advanced(by: sourceOffset)
            let gains = matrix.gains[inputIndex]
            for outputIndex in 0..<outputLimit {
                guard gains.indices.contains(outputIndex) else { continue }
                var gain = Float(gains[outputIndex])
                guard abs(gain) > 0.000_001 else { continue }

                outputBuffers[outputIndex].withUnsafeMutableBufferPointer { outputBuffer in
                    guard let output = outputBuffer.baseAddress else { return }
                    vDSP_vsma(input, 1, &gain, output, 1, output, 1, vDSP_Length(frames))
                }
            }
        }

        return frames
    }

    private static func renderedFrameCount(
        matrix: RendererMatrix,
        sourceBuffers: [AVAudioPCMBuffer],
        startFrame: Int,
        requestedFrameCount: Int
    ) -> Int {
        guard requestedFrameCount > 0,
              matrix.inputCount > 0,
              matrix.outputCount > 0,
              sourceBuffers.count == matrix.inputCount
        else {
            return 0
        }

        let sourceOffset = max(startFrame, 0)
        var frames = requestedFrameCount
        for buffer in sourceBuffers {
            let availableFrames = Int(buffer.frameLength) - sourceOffset
            guard availableFrames > 0 else { return 0 }
            frames = min(frames, availableFrames)
        }
        return max(frames, 0)
    }

    private static func renderedFrameCount(
        matrix: RendererMatrix,
        sourceBuffer: AVAudioPCMBuffer,
        startFrame: Int,
        requestedFrameCount: Int
    ) -> Int {
        guard requestedFrameCount > 0,
              matrix.inputCount > 0,
              matrix.outputCount > 0,
              Int(sourceBuffer.format.channelCount) == matrix.inputCount,
              sourceBuffer.floatChannelData != nil
        else {
            return 0
        }

        let sourceOffset = max(startFrame, 0)
        let availableFrames = Int(sourceBuffer.frameLength) - sourceOffset
        guard availableFrames > 0 else { return 0 }
        return min(requestedFrameCount, availableFrames)
    }

    private static func renderedFrameCount(
        matrix: RendererMatrix,
        inputSamples: [[Float]],
        requestedFrameCount: Int
    ) -> Int {
        guard requestedFrameCount > 0,
              matrix.inputCount > 0,
              matrix.outputCount > 0,
              inputSamples.count == matrix.inputCount
        else {
            return 0
        }

        var frames = requestedFrameCount
        for samples in inputSamples {
            guard !samples.isEmpty else { return 0 }
            frames = min(frames, samples.count)
        }
        return max(frames, 0)
    }

    private static func renderInput(
        _ input: UnsafePointer<Float>,
        matrix: RendererMatrix,
        inputIndex: Int,
        frameCount: Int,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        outputLimit: Int
    ) {
        let gains = matrix.gains[inputIndex]
        for outputIndex in 0..<outputLimit {
            guard gains.indices.contains(outputIndex) else { continue }
            let gain = Float(gains[outputIndex])
            guard abs(gain) > 0.000_001,
                  let rawData = outputBuffers[outputIndex].mData
            else {
                continue
            }

            let writableFrames = min(
                frameCount,
                Int(outputBuffers[outputIndex].mDataByteSize) / MemoryLayout<Float>.stride
            )
            guard writableFrames > 0 else { continue }
            let output = rawData.assumingMemoryBound(to: Float.self)
            for frame in 0..<writableFrames {
                output[frame] += input[frame] * gain
            }
        }
    }

    private static func clear(outputBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0 else { return }

        for buffer in outputBuffers {
            guard let rawData = buffer.mData else { continue }
            let writableFrames = min(
                frameCount,
                Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            )
            guard writableFrames > 0 else { continue }
            rawData.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: writableFrames)
        }
    }

    private static func normalize(outputBuffers: inout [[Float]], outputCount: Int, frameCount: Int) {
        if outputBuffers.count != outputCount {
            outputBuffers = Array(repeating: [], count: outputCount)
        }

        for outputIndex in outputBuffers.indices {
            outputBuffers[outputIndex] = Array(repeating: 0, count: frameCount)
        }
    }
}
