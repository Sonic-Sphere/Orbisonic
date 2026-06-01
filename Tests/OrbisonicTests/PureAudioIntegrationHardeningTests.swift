@testable import Orbisonic
import Foundation
import XCTest

final class PureAudioIntegrationHardeningTests: XCTestCase {
    func testLegacyLocalFileProductionGateAllowsMismatchedFileViaManagedImportWhenRendererSelected() {
        // A resolvable sample-rate mismatch is no longer hard-blocked: playback
        // prepares an offline managed session-rate copy before the engine sees
        // it, so the gate admits the file with a managed-import notice.
        let admission = LegacyLocalFileProductionGate.admission(
            for: localSource(sampleRate: 44_100, channels: 2),
            monitorRoute: desktopRoute(sampleRate: 48_000),
            systemOutputRoute: desktopRoute(sampleRate: 48_000),
            rendererRoute: danteRoute(sampleRate: 48_000, channels: 32),
            rendererOutputSelected: true,
            isSessionRunning: true
        )

        guard case .allowed(let reason) = admission else {
            return XCTFail("Expected mismatched production file to be admitted via managed import.")
        }
        XCTAssertTrue(reason.contains("managed"), reason)
        XCTAssertTrue(reason.contains("This file is 44.1 kHz"), reason)
        XCTAssertTrue(reason.contains("Current Orbisonic Dante session is 48 kHz"), reason)
    }

    func testLegacyLocalFileProductionGateAllowsMatchingFileWhenRendererSelected() {
        let admission = LegacyLocalFileProductionGate.admission(
            for: localSource(sampleRate: 48_000, channels: 2),
            monitorRoute: desktopRoute(sampleRate: 48_000),
            systemOutputRoute: desktopRoute(sampleRate: 48_000),
            rendererRoute: danteRoute(sampleRate: 48_000, channels: 32),
            rendererOutputSelected: true,
            isSessionRunning: true
        )

        guard case .allowed(let reason) = admission else {
            return XCTFail("Expected matching production file to be allowed.")
        }
        XCTAssertTrue(reason.contains("matches the Pure Audio production session rate"), reason)
    }

    func testLegacyLocalFileProductionGateAllowsLegacyDesktopOnlyWhenRendererNotSelected() {
        let admission = LegacyLocalFileProductionGate.admission(
            for: localSource(sampleRate: 44_100, channels: 2),
            monitorRoute: desktopRoute(sampleRate: 48_000),
            systemOutputRoute: desktopRoute(sampleRate: 48_000),
            rendererRoute: .unavailable,
            rendererOutputSelected: false,
            isSessionRunning: true
        )

        guard case .allowed(let reason) = admission else {
            return XCTFail("Expected desktop-only legacy monitor playback to remain available.")
        }
        XCTAssertTrue(reason.contains("Legacy Normal Monitor desktop-only playback"), reason)
    }

    func testLegacyLocalFileProductionGateRejectsSourceChannelCountOverLimit() {
        let admission = LegacyLocalFileProductionGate.admission(
            for: localSource(sampleRate: 48_000, channels: 65),
            monitorRoute: desktopRoute(sampleRate: 48_000),
            systemOutputRoute: desktopRoute(sampleRate: 48_000),
            rendererRoute: danteRoute(sampleRate: 48_000, channels: 32),
            rendererOutputSelected: true,
            isSessionRunning: true
        )

        guard case .blocked(let reason) = admission else {
            return XCTFail("Expected over-limit source channel count to be blocked.")
        }
        XCTAssertTrue(reason.contains("1...64"), reason)
    }

    func testSonicSphereAnalysisLabelIsNotActiveDanteOutputLabel() {
        let contentView = packageRoot()
            .appendingPathComponent("Sources/Orbisonic/ContentView.swift")
        let source = (try? String(contentsOf: contentView, encoding: .utf8)) ?? ""

        XCTAssertTrue(source.contains("Sonic Sphere Analysis Meter"))
        XCTAssertFalse(source.contains("Dante Output Meter"))
    }

    private func localSource(sampleRate: Double, channels: Int) -> LegacyLocalFileSourceDescription {
        LegacyLocalFileSourceDescription(
            id: "test-source",
            displayName: "test-source",
            sampleRate: sampleRate,
            channelCount: channels,
            durationFrames: 48_000,
            codecDescription: "PCM",
            containerDescription: "WAV"
        )
    }

    private func desktopRoute(sampleRate: Double) -> OutputRouteInfo {
        OutputRouteInfo(
            deviceID: 1,
            uid: "desktop",
            deviceName: "Desktop Monitor",
            manufacturer: "Hardware",
            transportName: "Built-In",
            outputChannelCount: 2,
            nominalSampleRate: sampleRate
        )
    }

    private func danteRoute(sampleRate: Double, channels: Int) -> OutputRouteInfo {
        OutputRouteInfo(
            deviceID: 2,
            uid: "dante",
            deviceName: "Dante Virtual Soundcard",
            manufacturer: "Audinate",
            transportName: "Virtual",
            outputChannelCount: channels,
            nominalSampleRate: sampleRate
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
