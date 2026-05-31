import XCTest

final class ExistingUIFreezeTests: XCTestCase {
    func testPrimaryStageTabsRemainAtBaseline() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let enumBlock = try block(
            named: "enum StageTab",
            endingBefore: "private enum LocalMusicPanel",
            in: source
        )

        for expectedCase in [
            #"case input = "Input""#,
            #"case renderer = "Renderer""#,
            #"case output = "Output""#,
            #"case analyzerVU = "VU""#,
            #"case localMusic = "Local Music""#,
            #"case diagnostics = "Diagnostics""#,
            #"case settings = "Settings""#
        ] {
            XCTAssertTrue(enumBlock.contains(expectedCase), "Missing baseline tab: \(expectedCase)")
        }

        XCTAssertEqual(enumBlock.components(separatedBy: #"case "#).count - 1, 7)
    }

    func testPrimarySourceSelectorWorkflowRemainsAtBaseline() throws {
        let content = try source("Sources/Orbisonic/ContentView.swift")
        let sourceSupport = try source("Sources/Orbisonic/LoopbackSourceSupport.swift")
        let sourceModeBlock = try block(
            named: "enum SourceMode",
            endingBefore: "struct SourceSwitchRequestState",
            in: sourceSupport
        )

        XCTAssertTrue(content.contains("private var primarySourceModes: [SourceMode]"))
        XCTAssertTrue(content.contains("SourceMode.musicInputs"))
        XCTAssertTrue(sourceModeBlock.contains("static var musicInputs: [SourceMode]"))
        XCTAssertTrue(sourceModeBlock.contains("[.filePlayback, .spotify, .roon, .aux, .off]"))

        for visibleName in [
            #"case filePlayback = "Local Files""#,
            #"case spotify = "Spotify""#,
            #"case roon = "Roon""#,
            #"case aux = "Aux Cable""#,
            #"case off = "Off""#
        ] {
            XCTAssertTrue(sourceModeBlock.contains(visibleName), "Missing source mode: \(visibleName)")
        }
        XCTAssertFalse(sourceModeBlock.contains("[.filePlayback, .atmosDRP"))
    }

    func testLocalMusicPanelBaselineRemainsStable() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let enumBlock = try block(
            named: "private enum LocalMusicPanel",
            endingBefore: "private enum PlayerTransportKind",
            in: source
        )

        XCTAssertTrue(enumBlock.contains(#"case music = "Music""#))
        XCTAssertTrue(enumBlock.contains(#"case playlists = "Playlists""#))
        XCTAssertTrue(enumBlock.contains(#"case queue = "Session Queue""#))
        XCTAssertEqual(enumBlock.components(separatedBy: #"case "#).count - 1, 3)
    }

    func testVisiblePlayerTransportRemainsBackPlayPauseForwardOnly() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let enumBlock = try block(
            named: "private enum PlayerTransportKind",
            endingBefore: "enum AppBuildInfo",
            in: source
        )
        let controlsBlock = try block(
            named: "private var playerTransportControls",
            endingBefore: "private func performPlayerTransport",
            in: source
        )

        XCTAssertTrue(enumBlock.contains("static let allCases: [PlayerTransportKind] = [.back, .play, .pause, .forward]"))
        XCTAssertFalse(enumBlock.contains("static let allCases: [PlayerTransportKind] = [.back, .play, .pause, .stop, .forward]"))
        XCTAssertTrue(controlsBlock.contains("ForEach(PlayerTransportKind.allCases)"))
        XCTAssertFalse(controlsBlock.contains("Button(\"Stop\""))
    }

    func testNormalContentViewDoesNotExposeAudioRewriteImplementationTerms() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let forbiddenNormalUIStrings = [
            "VLC",
            "libVLC",
            "amem",
            "FL32",
            "SRC",
            "Dither",
            "DanteOutputFormatter",
            "OutputSession",
            "AudioConversionLedger",
            "Audio Chain"
        ]

        for forbidden in forbiddenNormalUIStrings {
            XCTAssertFalse(source.contains(forbidden), "Normal UI exposes forbidden implementation term: \(forbidden)")
        }
    }

    func testPureSphericalLosslessIsTheOnlyAllowedNewBadgeLabel() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")

        XCTAssertFalse(source.contains("True Spherical Lossless"))

        let allowedBadgeLabels = [
            "Pure Spherical Lossless",
            "Pure Spherical Lossless, different sphere",
            "Pure Spherical Lossless, route not ready"
        ]
        let pureMentions = source.components(separatedBy: "Pure Spherical Lossless").count - 1
        if pureMentions > 0 {
            XCTAssertTrue(allowedBadgeLabels.contains { source.contains($0) })
        }
    }

    func testUIFilesDoNotImportProtectedAudioRewriteModules() throws {
        let uiFiles = [
            "Sources/Orbisonic/ContentView.swift",
            "Sources/Orbisonic/DiagnosticsView.swift",
            "Sources/Orbisonic/InputSourceStatusPanelModel.swift",
            "Sources/Orbisonic/OrbisonicApp.swift",
            "Sources/Orbisonic/OrbisonicDisclosureTray.swift",
            "Sources/Orbisonic/OrbisonicViewModel.swift",
            "Sources/Orbisonic/OrbisonicWebServer.swift"
        ]
        let protectedImports = [
            "import OrbisonicVLCReference",
            "import CLibVLCBridge"
        ]
        let protectedSymbols = [
            "CLibVLCBridge",
            "VlcLocalStereoMonitorSource",
            "DanteOutputFormatter",
            "ProductionOutputSession",
            "SourceRateConverter"
        ]

        for file in uiFiles {
            let source = try source(file)
            for protectedImport in protectedImports {
                XCTAssertFalse(source.contains(protectedImport), "\(file) imports \(protectedImport)")
            }
            for protectedSymbol in protectedSymbols {
                XCTAssertFalse(source.contains(protectedSymbol), "\(file) references \(protectedSymbol)")
            }
        }
    }

    func testUnitTestDetectionDoesNotEnumerateBundlesOnMainActor() throws {
        for file in [
            "Sources/Orbisonic/OrbisonicViewModel.swift",
            "Sources/Orbisonic/OrbisonicEngine.swift"
        ] {
            let source = try source(file)
            XCTAssertFalse(source.contains("Bundle.allBundles"), "\(file) should not enumerate bundles for unit-test detection.")
            XCTAssertTrue(source.contains("private static let isRunningUnitTests"))
        }
    }

    func testRouteEnumerationIsNotDoneInsideMainActorRefreshApplication() throws {
        let source = try source("Sources/Orbisonic/OrbisonicViewModel.swift")
        let schedulerBlock = try block(
            named: "private func refreshRoutesIfNeeded",
            endingBefore: "private func applyRouteRefreshSnapshot",
            in: source
        )
        let applicationBlock = try block(
            named: "private func applyRouteRefreshSnapshot",
            endingBefore: "private func publishTuning",
            in: source
        )

        XCTAssertTrue(schedulerBlock.contains("guard !Self.isRunningUnitTests else { return }"))
        XCTAssertTrue(schedulerBlock.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(schedulerBlock.contains("OutputRouteMonitor.availableOutputRoutes()"))
        XCTAssertTrue(schedulerBlock.contains("OutputRouteMonitor.availableInputRoutes()"))
        XCTAssertFalse(applicationBlock.contains("OutputRouteMonitor.availableOutputRoutes()"))
        XCTAssertFalse(applicationBlock.contains("OutputRouteMonitor.availableInputRoutes()"))
        XCTAssertFalse(applicationBlock.contains("OutputRouteMonitor.currentRoute()"))
        XCTAssertFalse(applicationBlock.contains("OutputRouteMonitor.currentInputRoute()"))
    }

    func testRendererMeterDisplayReusesSceneOutputSpeakers() throws {
        let source = try source("Sources/Orbisonic/OrbisonicViewModel.swift")
        let rendererMeterBlock = try block(
            named: "enum RendererMeterDisplayModel",
            endingBefore: "enum MonitorMeterDisplayModel",
            in: source
        )

        XCTAssertTrue(rendererMeterBlock.contains("return scene.outputSpeakers.enumerated().map"))
        XCTAssertFalse(rendererMeterBlock.contains("SonicSphereTopology.outputSpeakers(for: scene.preset"))
    }

    func testRefreshedOutputDeviceApplyIsNonBlockingOnMainActor() throws {
        let engine = try source("Sources/Orbisonic/OrbisonicEngine.swift")
        let vm = try source("Sources/Orbisonic/OrbisonicViewModel.swift")

        // Engine exposes an async apply that isolates the blocking CoreAudio
        // syscall on a dedicated serial queue via a continuation.
        XCTAssertTrue(engine.contains("func setOutputDeviceAsync"))
        XCTAssertTrue(engine.contains("outputDeviceApplyQueue"))
        XCTAssertTrue(
            engine.contains("withCheckedContinuation") || engine.contains("withCheckedThrowingContinuation"))
        let asyncBlock = try block(named: "func setOutputDeviceAsync", endingBefore: "func stop()", in: engine)
        XCTAssertTrue(asyncBlock.contains("outputDeviceApplyQueue"))
        XCTAssertTrue(asyncBlock.contains(".async {"))
        XCTAssertTrue(asyncBlock.contains("AudioUnitSetProperty"))

        // The route-refresh application path must not block the MainActor on the
        // synchronous setOutputDevice anymore.
        let refreshBlock = try block(
            named: "private func applyRouteRefreshSnapshot",
            endingBefore: "private func publishTuning",
            in: vm
        )
        XCTAssertFalse(refreshBlock.contains("try engine.setOutputDevice(refreshedActiveRoute.deviceID)"))
        XCTAssertTrue(refreshBlock.contains("planOutputDeviceApply"))
        XCTAssertTrue(refreshBlock.contains("beginAsyncOutputDeviceApply"))
        XCTAssertTrue(vm.contains("setOutputDeviceAsync"))
    }

    func testUserInitiatedRendererOutputSwitchIsNonBlockingOnMainActor() throws {
        let vm = try source("Sources/Orbisonic/OrbisonicViewModel.swift")

        // The shared apply helper gains an async mode that hands the blocking
        // CoreAudio syscall to the non-blocking begin-apply path.
        let applyBlock = try block(
            named: "private func applyOutputRouteIfAvailable",
            endingBefore: "private func applyMonitorOutputRouteIfAvailable",
            in: vm
        )
        XCTAssertTrue(applyBlock.contains("applyAsynchronously"))
        XCTAssertTrue(applyBlock.contains("beginAsyncOutputDeviceApply"))

        // The user-initiated renderer picker requests the async apply.
        let rendererBlock = try block(
            named: "func selectRendererOutputRoute",
            endingBefore: "func chooseWatchFolder",
            in: vm
        )
        XCTAssertTrue(rendererBlock.contains("applyAsynchronously: true"))

        // Playback-precondition callers must stay synchronous so audio never
        // starts before the output device is actually applied.
        let prepareBlock = try block(
            named: "private func prepareOutputForMusicPlayback",
            endingBefore: "private func ensureOutputForAction",
            in: vm
        )
        XCTAssertFalse(prepareBlock.contains("applyAsynchronously: true"))
        let ensureBlock = try block(
            named: "private func ensureOutputForAction",
            endingBefore: "private func resolvedSelectedInputRoute",
            in: vm
        )
        XCTAssertFalse(ensureBlock.contains("applyAsynchronously: true"))
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
