import XCTest

final class DiagnosticRoutingRegressionTests: XCTestCase {
    func testRendererDiagnosticPreparationUsesRendererRoute() throws {
        let source = try source("Sources/Orbisonic/OrbisonicViewModel.swift")
        let function = try block(
            named: "private func prepareDiagnosticOutput",
            endingBefore: "private func configureDiagnosticMonitorDownmix",
            in: source
        )
        let monitorCase = try block(
            named: "case .monitor:",
            endingBefore: "case .renderer:",
            in: function
        )
        let rendererCaseStart = try XCTUnwrap(function.range(of: "case .renderer:"))
        let rendererCase = String(function[rendererCaseStart.lowerBound...])

        XCTAssertTrue(function.contains("rendererDiagnosticsUsingNormalMonitor = false"))
        XCTAssertTrue(function.contains("rendererDiagnosticsMonitorDownmixAvailable = false"))
        XCTAssertTrue(function.contains("try? engine.setDiagnosticMonitorOutputDevice(nil)"))

        XCTAssertTrue(monitorCase.contains("return ensureOutputForAction(.monitor)"))
        XCTAssertTrue(rendererCase.contains("return ensureOutputForAction(.renderer)"))
        XCTAssertFalse(rendererCase.contains("return ensureOutputForAction(.monitor)"))
    }

    func testPlaySpeakerToneUsesRendererRoute() throws {
        let source = try source("Sources/Orbisonic/OrbisonicViewModel.swift")
        let function = try block(
            named: "func playSelectedDiagnosticSpeakerTone()",
            endingBefore: "func stopTestTone(",
            in: source
        )

        XCTAssertTrue(function.contains("ensureOutputForAction(.renderer)"))
        XCTAssertFalse(function.contains("ensureOutputForAction(.monitor)"))
    }

    func testRendererOutputGraphBypassesMainMixer() throws {
        let source = try source("Sources/Orbisonic/OrbisonicEngine.swift")
        let function = try block(
            named: "private func configureRendererOutputGraph(format: AVAudioFormat) {",
            endingBefore: "private struct OutputDevicePlaybackSnapshot",
            in: source
        )

        XCTAssertTrue(function.contains("engine.connect(outputGainMixer, to: engine.outputNode, format: format)"))
        XCTAssertTrue(function.contains("engine.disconnectNodeOutput(engine.mainMixerNode)"))
        XCTAssertFalse(function.contains("engine.connect(outputGainMixer, to: engine.mainMixerNode"))
    }

    func testDiagnosticToneSizesOutputFromDeviceNativeChannelCount() throws {
        let source = try source("Sources/Orbisonic/OrbisonicEngine.swift")
        XCTAssertTrue(source.contains("func currentOutputDeviceConfiguration()"))

        let function = try block(
            named: "func playDiagnosticChannelTone(",
            endingBefore: "private func diagnosticChannelFormat(",
            in: source
        )
        XCTAssertTrue(function.contains("deviceConfig?.channelCount"))
    }

    private func block(named startMarker: String, endingBefore endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
