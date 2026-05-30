import XCTest
@testable import Orbisonic

final class OrbisonicWebStateTests: XCTestCase {
    @MainActor
    func testControlStateIncludesDiagnosticsAndErrorsWhilePublicStateDoesNot() {
        let model = OrbisonicViewModel()

        model.lastError = "Desktop route error"
        model.selectDiagnosticSpeakerChannel(12)

        let controlState = model.webStateForTesting(controlEnabled: true)
        let publicState = model.webStateForTesting(controlEnabled: false)

        XCTAssertTrue(controlState.controlEnabled)
        XCTAssertNotNil(controlState.urls.controlPage)
        XCTAssertEqual(controlState.urls.controlPage?.hasSuffix("/control"), true)
        XCTAssertEqual(controlState.diagnostics.availableTests, ["monitorWalk", "rendererWalk", "testTone"])
        XCTAssertEqual(controlState.diagnostics.selectedChannel, 12)
        XCTAssertEqual(controlState.build.lastError, "Desktop route error")

        XCTAssertFalse(publicState.controlEnabled)
        XCTAssertEqual(publicState.diagnostics.availableTests, [])
        XCTAssertNil(publicState.build.lastError)
        XCTAssertNil(publicState.urls.controlPage)
        XCTAssertNil(publicState.player.artworkURL)
    }

    @MainActor
    func testPublicAndControlStatesExposeCurrentSpotifyArtwork() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.spotify)
        model.setSpotifyReceiverStatusForTesting(Self.spotifyReceiverRunningStatus())
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(
            title: "Artwork Track",
            isPlaying: true,
            coverURL: "https://example.com/artwork.jpg"
        ))

        let publicState = model.webStateForTesting(controlEnabled: false)
        let controlState = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(publicState.player.artworkURL, controlState.player.artworkURL)
        XCTAssertTrue(publicState.player.artworkURL?.hasPrefix("/Orbisonic/api/artwork/current?v=") == true)
        XCTAssertFalse(publicState.player.artworkURL?.contains("token=") == true)
    }

    @MainActor
    func testPublicStateExposesCurrentLocalArtwork() {
        let model = OrbisonicViewModel()
        let artworkPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbisonic-web-artwork-test.jpg", isDirectory: false)
            .path
        let track = Self.localTrack(title: "Local Artwork Track", artworkPath: artworkPath)

        model.setSourceModeForTesting(.filePlayback)
        model.replaceLocalMusicQueueForTesting(tracks: [track], currentIndex: 0, selectedIndex: nil)

        let state = model.webStateForTesting(controlEnabled: false)

        XCTAssertTrue(state.player.artworkURL?.hasPrefix("/Orbisonic/api/artwork/current?v=") == true)
        XCTAssertFalse(state.player.artworkURL?.contains("token=") == true)
    }

    @MainActor
    func testPublicPlayerSummaryUsesVisitorFacingFields() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.spotify)
        model.setSpotifyReceiverStatusForTesting(Self.spotifyReceiverRunningStatus())
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(
            title: "The Lady",
            isPlaying: true
        ))

        let state = model.webStateForTesting(controlEnabled: false)

        XCTAssertEqual(state.player.title, "The Lady")
        XCTAssertEqual(state.player.artist, "Artist")
        XCTAssertEqual(state.player.album, "Album")
        XCTAssertEqual(state.player.sourceName, "Spotify")
        XCTAssertEqual(state.player.outputChannels, "30.1 channels")
        XCTAssertTrue(state.player.hasMedia)
        XCTAssertEqual(state.player.details.map(\.title), [
            "Source",
            "Playback",
            "Input",
            "Sphere output",
            "Renderer",
            "Routing",
            "Endpoint",
            "Signal quality",
            "System state"
        ])
    }

    @MainActor
    func testWebPlayerDetailsIncludeLocalFileFormat() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.filePlayback)
        model.sourceMetadata = Self.localMetadata(
            title: "Local FLAC",
            fileExtension: "flac",
            containerName: "FLAC",
            codecName: "FLAC"
        )

        let state = model.webStateForTesting(controlEnabled: false)

        XCTAssertEqual(state.player.outputChannels, "30.1 channels")
        XCTAssertEqual(state.player.details.first { $0.title == "Format" }?.value, "FLAC")
        XCTAssertTrue(state.player.details.contains { $0.title == "Renderer" })
        XCTAssertTrue(state.player.details.contains { $0.title == "Routing" })
        XCTAssertTrue(state.player.details.contains { $0.title == "Endpoint" })
        XCTAssertTrue(state.player.details.contains { $0.title == "System state" })
    }

    @MainActor
    func testWebPlayerDetailsIncludeRoonStreamFormat() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.roon)
        model.setRoonNowPlayingForTesting(Self.roonNowPlaying(title: "Roon FLAC"))

        let state = model.webStateForTesting(controlEnabled: false)

        XCTAssertEqual(state.player.details.first { $0.title == "Format" }?.value, "FLAC")
    }

    @MainActor
    func testAtmosDRPWebStateExposesTrackAndBitstreamMetadata() {
        let model = OrbisonicViewModel()
        let track = Self.localTrack(title: "Atmos Track", artworkPath: nil, fileExtension: "ec3")
        let bitstream = DolbyBitstreamInfo(
            codec: "Dolby Digital Plus",
            bitRateKbps: 768,
            codedChannels: "L, R, C, LFE, Ls, Rs",
            hasAtmos: true,
            sampleRateHz: 48_000,
            dynamicObjectCount: 12,
            objectInfoBlockCount: nil,
            bedObjectConfiguration: nil,
            complexityIndex: 15
        )

        model.setInputRouteForTesting(Self.inputRoute(for: .auxCable))
        model.setAtmosDRPStateForTesting(track: track, state: .playing, bitstreamInfo: bitstream)
        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(state.player.source, SourceMode.atmosDRP.rawValue)
        XCTAssertEqual(state.player.sourceName, "Atmos")
        XCTAssertEqual(state.player.title, "Atmos Track")
        XCTAssertEqual(state.player.status, "Atmos playing")
        XCTAssertTrue(state.player.isPlaying)
        XCTAssertEqual(state.input.sourcePanel.title, "Atmos")
        XCTAssertEqual(state.player.details.first { $0.title == "DRP codec" }?.value, "Dolby Digital Plus")
        XCTAssertEqual(state.player.details.first { $0.title == "Dolby Atmos" }?.value, "Yes")
        XCTAssertEqual(state.player.details.first { $0.title == "Data rate" }?.value, "768 kbps")
        XCTAssertEqual(state.player.details.first { $0.title == "Coded channels" }?.value, "L, R, C, LFE, Ls, Rs")
        XCTAssertEqual(state.player.details.first { $0.title == "Sample rate" }?.value, "48 kHz")
        XCTAssertEqual(state.player.details.first { $0.title == "Dynamic objects" }?.value, "12")
        XCTAssertEqual(state.player.details.first { $0.title == "Complexity index" }?.value, "15")
    }

    func testRoonPlayerRowsUseChannelsInsteadOfSignalPath() {
        let stereoRows = RoonPlayerRowsModel.rows(
            nowPlaying: Self.roonNowPlaying(title: "Roon Stereo"),
            signalPath: Self.roonSignalPath(sourceChannelCount: 2)
        )
        let surroundRows = RoonPlayerRowsModel.rows(
            nowPlaying: Self.roonNowPlaying(title: "Roon Surround"),
            signalPath: Self.roonSignalPath(sourceChannelCount: 6)
        )

        XCTAssertEqual(stereoRows.first { $0.title == "Channels" }?.value, "Stereo")
        XCTAssertEqual(surroundRows.first { $0.title == "Channels" }?.value, "5.1")
        XCTAssertFalse(stereoRows.contains { $0.title == "Signal path" })
        XCTAssertFalse(surroundRows.contains { $0.title == "Signal path" })
    }

    func testPublicPlayerScriptHidesOutputChannelsAndTechnicalNerdRows() {
        let script = OrbisonicWebServer.publicPageJSForTesting

        XCTAssertFalse(script.contains("${source} · ${channels}"))
        XCTAssertFalse(script.contains("outputChannels)||'30.1 channels'"))
        XCTAssertTrue(script.contains("setText('sourceLine',media?source:"))
        XCTAssertTrue(script.contains("hiddenNerdRows"))
        XCTAssertTrue(script.contains("'Renderer'"))
        XCTAssertTrue(script.contains("'Routing'"))
        XCTAssertTrue(script.contains("'Endpoint'"))
        XCTAssertTrue(script.contains("'System state'"))
    }

    @MainActor
    func testPublicPlayerIdleStateUsesCalmCopy() {
        let model = OrbisonicViewModel()

        let state = model.webStateForTesting(controlEnabled: false)

        XCTAssertFalse(state.player.hasMedia)
        XCTAssertEqual(state.player.title, "Nothing playing right now")
        XCTAssertEqual(state.player.subtitle, "Choose Roon, Spotify, Atmos, Aux, or Local Music.")
        XCTAssertEqual(state.player.sourceName, "Local Music")
        XCTAssertEqual(state.player.outputChannels, "30.1 channels")
        XCTAssertFalse(state.player.title.localizedCaseInsensitiveContains("no source"))
        XCTAssertFalse(state.player.subtitle.localizedCaseInsensitiveContains("no local file"))
    }

    @MainActor
    func testVolumeStateUsesPlainZeroToOneHundredValues() {
        let model = OrbisonicViewModel()

        model.setSphereOutputVolume(88.4)
        model.sphereOutputSafetyLimitPercent = 40.2

        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(state.player.volume, 88)
        XCTAssertEqual(model.sphereOutputVolumeText, "88")
        XCTAssertEqual(model.sphereMaxOutputVolumeText, "40")
        XCTAssertEqual(model.sphereEffectiveOutputVolumeText, "40")
        XCTAssertFalse(model.sphereOutputVolumeText.contains("%"))
        XCTAssertFalse(model.sphereMaxOutputVolumeText.contains("%"))
        XCTAssertFalse(model.sphereEffectiveOutputVolumeText.contains("%"))
    }

    @MainActor
    func testControlStateUsesPrimarySourcePanelModel() {
        let model = OrbisonicViewModel()

        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(state.input.sourceButtons.map(\.title), ["Local Music", "Spotify", "Roon", "Aux Cable", "Off"])
        XCTAssertEqual(state.input.sourceButtons.map(\.value), ["Local Files", "Spotify", "Roon", "Aux Cable", "Off"])
        XCTAssertEqual(state.input.sourceButtons.map(\.subtitle), ["", "", "", "", ""])
        XCTAssertFalse(state.input.sourceButtons.map(\.title).contains("Atmos"))
        XCTAssertFalse(state.input.availableSources.contains("Atmos DRP"))
        XCTAssertFalse(state.input.sourceButtons.map(\.title).contains("Test Tone"))
        XCTAssertEqual(state.input.sourcePanel.title, "Local Music")
        XCTAssertEqual(state.input.sourcePanel.headline, "Use the Local Music tab to play music.")
        XCTAssertTrue(state.input.sourcePanel.rows.isEmpty)
    }

    @MainActor
    func testControlStateUsesSourceSpecificInstructions() {
        let model = OrbisonicViewModel()

        model.sourceMode = .spotify
        let spotifyState = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(spotifyState.input.sourcePanel.title, "Spotify")
        XCTAssertEqual(spotifyState.input.sourcePanel.headline, "Spotify Connect is unavailable")
        XCTAssertEqual(spotifyState.input.sourcePanel.body, "Open Diagnostics for setup details.")
        XCTAssertEqual(
            spotifyState.input.sourcePanel.rows.map(\.title),
            [
                "Spotify Connect",
                "Connection",
                "Audio",
                "Now playing"
            ]
        )
        XCTAssertEqual(spotifyState.player.controls, ["previous", "play", "pause", "next"])
        XCTAssertTrue(spotifyState.player.enabledControls.isEmpty)

        model.sourceMode = .roon
        let roonState = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(roonState.input.sourcePanel.title, "Roon")
        XCTAssertEqual(roonState.input.sourcePanel.headline, "Roon input is unavailable")
        XCTAssertEqual(roonState.input.sourcePanel.body, "Open Diagnostics for setup details.")
        XCTAssertEqual(
            roonState.input.sourcePanel.rows.map(\.title),
            ["Roon input", "Roon server", "Playback", "Audio", "Now playing"]
        )

        model.sourceMode = .aux
        let auxState = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(auxState.input.sourcePanel.title, "Aux Cable")
        XCTAssertEqual(auxState.input.sourcePanel.headline, "Aux input unavailable")
        XCTAssertEqual(auxState.input.sourcePanel.body, "Open Diagnostics for setup details.")
        XCTAssertEqual(
            auxState.input.sourcePanel.rows.map(\.title),
            ["Aux Cable", "Input", "Audio"]
        )
    }

    @MainActor
    func testWebPlayerControlsStayStable() {
        let model = OrbisonicViewModel()

        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(state.player.controls, ["previous", "play", "pause", "next"])
        XCTAssertFalse(state.player.controls.contains("playAll"))
        XCTAssertFalse(state.player.controls.contains("shuffle"))
        XCTAssertFalse(state.player.controls.contains("seekBackward"))
        XCTAssertFalse(state.player.controls.contains("seekForward"))
        XCTAssertFalse(state.player.controls.contains("playPause"))
    }

    @MainActor
    func testSpotifyStatusUsesDebouncedBackendStateWithDisabledControls() async throws {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.spotify)
        model.setSpotifyReceiverStatusForTesting(SpotifyReceiverStatus(
            state: .waitingForConnection,
            message: "Spotify Connect receiver is advertising as Orbisonic Spotify."
        ))
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(title: "Stable Track", isPlaying: true))

        var state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "Spotify playing")
        XCTAssertTrue(state.player.isPlaying)
        XCTAssertTrue(state.player.enabledControls.isEmpty)
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Connection" }?.value,
            "Connected to Orbisonic"
        )

        model.applySpotifyNowPlayingForTesting(Self.spotifyNowPlaying(title: "Stable Track", isPlaying: false))

        state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "Spotify playing")
        XCTAssertTrue(state.player.isPlaying)
        XCTAssertTrue(state.player.enabledControls.isEmpty)

        await model.waitForSpotifyPlaybackStatusDebounceForTesting()
        state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(state.player.status, "Spotify paused")
        XCTAssertFalse(state.player.isPlaying)
        XCTAssertTrue(state.player.enabledControls.isEmpty)
    }

    @MainActor
    func testStaleSpotifyMetadataDoesNotMarkConnectionActive() {
        let model = OrbisonicViewModel()
        let spotifyRoute = Self.inputRoute(for: .spotifyInput)
        model.setSourceModeForTesting(.spotify)
        model.setInputRouteForTesting(spotifyRoute, availableRoutes: [spotifyRoute])
        model.setSpotifyReceiverStatusForTesting(SpotifyReceiverStatus(
            state: .waitingForConnection,
            message: "Spotify Connect receiver is advertising as Orbisonic Spotify."
        ))
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(
            title: "Stale Track",
            isPlaying: false,
            sessionActive: nil
        ))
        model.setLiveAudioSignalStateForTesting(.noSignal)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "No Spotify track")
        XCTAssertFalse(state.player.isPlaying)
        XCTAssertEqual(state.input.sourcePanel.headline, "Open Spotify and choose Orbisonic")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Connection" }?.value,
            "Choose Orbisonic in Spotify"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "Waiting for audio"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Now playing" }?.value,
            "Waiting for Spotify"
        )
    }

    @MainActor
    func testActiveSpotifySessionCanBePaused() {
        let model = OrbisonicViewModel()
        let spotifyRoute = Self.inputRoute(for: .spotifyInput)
        model.setSourceModeForTesting(.spotify)
        model.setInputRouteForTesting(spotifyRoute, availableRoutes: [spotifyRoute])
        model.setSpotifyReceiverStatusForTesting(SpotifyReceiverStatus(
            state: .waitingForConnection,
            message: "Spotify Connect receiver is advertising as Orbisonic Spotify."
        ))
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(
            title: "Paused Track",
            isPlaying: false,
            sessionActive: true
        ))

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "Spotify paused")
        XCTAssertEqual(state.input.sourcePanel.headline, "Spotify is paused")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Connection" }?.value,
            "Connected to Orbisonic"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "Paused or silent"
        )
    }

    @MainActor
    func testSpotifyReceivingAudioOverridesStalePausedMetadata() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.spotify)
        model.setSpotifyReceiverStatusForTesting(SpotifyReceiverStatus(
            state: .waitingForConnection,
            message: "Spotify Connect receiver is advertising as Orbisonic Spotify."
        ))
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(
            title: "Audible Track",
            isPlaying: false,
            sessionActive: nil
        ))
        model.setLiveMonitorStateForTesting(.monitoring)
        model.setLiveAudioSignalStateForTesting(.receiving)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "Spotify playing")
        XCTAssertTrue(state.player.isPlaying)
        XCTAssertEqual(state.input.sourcePanel.headline, "Receiving Spotify audio")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Connection" }?.value,
            "Connected to Orbisonic"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "Receiving"
        )
    }

    @MainActor
    func testRoonPlaybackActiveSurvivesBriefSilence() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.roon)
        model.setInputRouteForTesting(Self.inputRoute(for: .roonInput), availableRoutes: [Self.inputRoute(for: .roonInput)])
        model.setRoonBridgeSnapshotForTesting(Self.roonBridgeSnapshot(state: "playing"))
        model.setLiveMonitorStateForTesting(.monitoring)
        model.setLiveAudioSignalStateForTesting(.briefSilence, silenceDuration: 1)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "Roon playing")
        XCTAssertTrue(state.player.isPlaying)
        XCTAssertEqual(state.input.sourcePanel.headline, "Receiving Roon audio")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Playback" }?.value,
            "Playing"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "Receiving"
        )
    }

    @MainActor
    func testRoonPlaybackActiveWithNoSignalShowsAudioProblem() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.roon)
        model.setInputRouteForTesting(Self.inputRoute(for: .roonInput), availableRoutes: [Self.inputRoute(for: .roonInput)])
        model.setRoonBridgeSnapshotForTesting(Self.roonBridgeSnapshot(state: "playing"))
        model.setLiveMonitorStateForTesting(.silent)
        model.setLiveAudioSignalStateForTesting(.noSignal, silenceDuration: 16)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "No Roon audio")
        XCTAssertFalse(state.player.isPlaying)
        XCTAssertEqual(state.input.sourcePanel.headline, "Waiting for Roon audio")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Playback" }?.value,
            "Playing"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Roon input" }?.value,
            "Ready"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "No signal"
        )
        XCTAssertEqual(state.input.sourcePanel.severity, "waiting")
        XCTAssertTrue(state.input.sourcePanel.body.contains("playing to Orbisonic"))
        XCTAssertNotEqual(
            state.input.sourcePanel.rows.first { $0.title == "Playback" }?.value,
            "Waiting"
        )
    }

    @MainActor
    func testRoonPausedKeepsPlaybackAndSignalSeparate() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.roon)
        model.setInputRouteForTesting(Self.inputRoute(for: .roonInput), availableRoutes: [Self.inputRoute(for: .roonInput)])
        model.setRoonBridgeSnapshotForTesting(Self.roonBridgeSnapshot(state: "paused"))
        model.setLiveMonitorStateForTesting(.silent)
        model.setLiveAudioSignalStateForTesting(.noSignal, silenceDuration: 16)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.status, "Roon paused")
        XCTAssertFalse(state.player.isPlaying)
        XCTAssertEqual(state.input.sourcePanel.headline, "Roon is paused")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Playback" }?.value,
            "Paused"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "Waiting for audio"
        )
    }

    @MainActor
    func testActiveSpotifySessionWithNoSignalKeepsAudioProblemVisible() {
        let model = OrbisonicViewModel()
        let spotifyRoute = Self.inputRoute(for: .spotifyInput)
        model.setSourceModeForTesting(.spotify)
        model.setInputRouteForTesting(spotifyRoute, availableRoutes: [spotifyRoute])
        model.setSpotifyReceiverStatusForTesting(Self.spotifyReceiverRunningStatus())
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(
            title: "Signal Lost",
            isPlaying: true,
            sessionActive: true
        ))
        model.setLiveMonitorStateForTesting(.silent)
        model.setLiveAudioSignalStateForTesting(.noSignal, silenceDuration: 16)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.source, SourceMode.spotify.rawValue)
        XCTAssertEqual(state.player.status, "Spotify playing")
        XCTAssertEqual(state.input.sourcePanel.headline, "Spotify is connected - waiting for audio")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Connection" }?.value,
            "Connected to Orbisonic"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "No signal"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Now playing" }?.value,
            "Signal Lost - Artist"
        )
        XCTAssertEqual(state.input.sourcePanel.severity, "waiting")
    }

    @MainActor
    func testAuxReadyWithNoSignalReportsAuxOnlyRouteAndAudioState() {
        let model = OrbisonicViewModel()
        let auxRoute = Self.inputRoute(for: .auxCable)
        model.setSourceModeForTesting(.aux)
        model.setInputRouteForTesting(auxRoute, availableRoutes: [auxRoute])
        model.setLiveMonitorStateForTesting(.silent)
        model.setLiveAudioSignalStateForTesting(.noSignal, silenceDuration: 16)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.source, SourceMode.aux.rawValue)
        XCTAssertEqual(state.player.status, "Aux has no transport")
        XCTAssertFalse(state.player.isPlaying)
        XCTAssertEqual(state.input.sourcePanel.title, "Aux Cable")
        XCTAssertEqual(state.input.sourcePanel.headline, "Waiting for Aux audio")
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Aux Cable" }?.value,
            "Ready"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Input" }?.value,
            "64 channels"
        )
        XCTAssertEqual(
            state.input.sourcePanel.rows.first { $0.title == "Audio" }?.value,
            "No signal"
        )
        XCTAssertFalse(state.input.sourcePanel.rows.contains { $0.title.contains("Roon") })
        XCTAssertFalse(state.input.sourcePanel.rows.contains { $0.title.contains("Spotify") })
        XCTAssertEqual(state.player.details.first { $0.title == "Endpoint" }?.value, "Aux input ready")
        XCTAssertEqual(state.player.details.first { $0.title == "Signal quality" }?.value, "44.1 kHz input")
        XCTAssertEqual(state.input.sourcePanel.severity, "waiting")
    }

    @MainActor
    func testInactiveSpotifyStateDoesNotOverwriteLocalPlayerStatus() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.spotify)
        model.setSpotifyReceiverStatusForTesting(SpotifyReceiverStatus(
            state: .waitingForConnection,
            message: "Spotify Connect receiver is advertising as Orbisonic Spotify."
        ))
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(title: "Spotify Track", isPlaying: true))
        XCTAssertEqual(model.webStateForTesting(controlEnabled: true).player.status, "Spotify playing")

        model.setSourceModeForTesting(.filePlayback)
        model.sourceMetadata = Self.localMetadata(title: "Local Track")
        model.statusMessage = "Local playback paused"
        model.applySpotifyNowPlayingForTesting(Self.spotifyNowPlaying(title: "Spotify Track", isPlaying: false))

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.source, SourceMode.filePlayback.rawValue)
        XCTAssertEqual(state.player.title, "Local Track")
        XCTAssertEqual(state.player.status, "Local paused")
        XCTAssertFalse(state.player.isPlaying)
    }

    @MainActor
    func testActiveSpotifyPlayerIgnoresStaleLocalPlaybackState() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.filePlayback)
        model.sourceMetadata = Self.localMetadata(title: "Local Track")
        model.statusMessage = "Local playback playing"
        model.isPlaying = true

        model.setSourceModeForTesting(.spotify)
        model.setSpotifyReceiverStatusForTesting(SpotifyReceiverStatus(
            state: .waitingForConnection,
            message: "Spotify Connect receiver is advertising as Orbisonic Spotify."
        ))
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(title: "Spotify Track", isPlaying: false))

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.source, SourceMode.spotify.rawValue)
        XCTAssertEqual(state.player.title, "Spotify Track")
        XCTAssertEqual(state.player.status, "Spotify paused")
        XCTAssertFalse(state.player.isPlaying)
        XCTAssertTrue(state.player.enabledControls.isEmpty)
    }

    @MainActor
    func testActiveLocalPlayerIgnoresStaleRoonNowPlayingState() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.roon)
        model.setRoonNowPlayingForTesting(Self.roonNowPlaying(title: "Roon Track"))
        XCTAssertEqual(model.webStateForTesting(controlEnabled: true).player.title, "Roon Track")

        model.setSourceModeForTesting(.filePlayback)
        model.sourceMetadata = Self.localMetadata(title: "Local Track")
        model.statusMessage = "Local playback paused"
        model.isPlaying = false

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.source, SourceMode.filePlayback.rawValue)
        XCTAssertEqual(state.player.title, "Local Track")
        XCTAssertEqual(state.player.status, "Local paused")
        XCTAssertFalse(state.player.isPlaying)
    }

    @MainActor
    func testActiveRoonPlayerIgnoresStaleLocalPlaybackState() {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.filePlayback)
        model.sourceMetadata = Self.localMetadata(title: "Local Track")
        model.statusMessage = "Local playback playing"
        model.isPlaying = true

        model.setSourceModeForTesting(.roon)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(state.player.source, SourceMode.roon.rawValue)
        XCTAssertEqual(state.player.title, "Roon")
        XCTAssertEqual(state.player.status, "Waiting for Roon")
        XCTAssertFalse(state.player.isPlaying)
    }

    @MainActor
    func testSwitchingOffClearsStaleLocalPlaybackSnapshot() async throws {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.filePlayback)
        model.sourceMetadata = Self.localMetadata(title: "Local Track")
        model.statusMessage = "Local playback paused"
        XCTAssertNotNil(model.visibleLocalSourceMetadata)

        model.selectSourceMode(.off, reason: "test", requestedBy: "test")
        try await Self.waitForSourceMode(model, .off)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertNil(model.visibleLocalSourceMetadata)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(state.player.source, SourceMode.off.rawValue)
        XCTAssertEqual(state.player.title, "Nothing playing right now")
        XCTAssertFalse(state.player.title.localizedCaseInsensitiveContains("Local Track"))
        XCTAssertFalse(state.player.details.contains { $0.value.localizedCaseInsensitiveContains("Local Track") })
    }

    @MainActor
    func testSwitchingToTestToneClearsStaleLocalPlaybackSnapshot() async throws {
        let model = OrbisonicViewModel()
        model.setSourceModeForTesting(.filePlayback)
        model.sourceMetadata = Self.localMetadata(title: "Local Track")
        model.statusMessage = "Local playback paused"
        XCTAssertNotNil(model.visibleLocalSourceMetadata)

        model.selectSourceMode(.testTone, reason: "test", requestedBy: "test")
        try await Self.waitForSourceMode(model, .testTone)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertNil(model.visibleLocalSourceMetadata)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(state.player.source, SourceMode.testTone.rawValue)
        XCTAssertEqual(state.player.title, model.selectedTestTonePoint.rawValue)
        XCTAssertFalse(state.player.title.localizedCaseInsensitiveContains("Local Track"))
        XCTAssertFalse(state.player.details.contains { $0.value.localizedCaseInsensitiveContains("Local Track") })
    }

    @MainActor
    func testSpotifyHealthUsesStereoBoundaryWhenLocalMetadataIsStale() {
        let model = OrbisonicViewModel()
        let spotifyRoute = Self.inputRoute(for: .spotifyInput)
        model.setSourceModeForTesting(.spotify)
        model.setInputRouteForTesting(spotifyRoute, availableRoutes: [spotifyRoute])
        model.setLiveMonitorStateForTesting(.monitoring)
        model.sourceMetadata = Self.localMetadata(
            title: "Local 5.1 Track",
            layoutName: "5.1",
            channelCount: 6,
            sampleRate: 96_000
        )

        let streamRead = model.spotifySourceHealthLines
            .first { $0.title == "Spotify input stream" }?
            .value

        XCTAssertEqual(streamRead, "Receiving format: 2 channels, 96.0 kHz stereo")
        XCTAssertFalse(streamRead?.contains("6 channels") == true)
        XCTAssertFalse(streamRead?.contains("5.1") == true)
    }

    private static func localMetadata(
        title: String,
        fileExtension: String = "wav",
        containerName: String = "WAV",
        codecName: String = "PCM",
        layoutName: String = "Stereo",
        channelCount: Int = 2,
        sampleRate: Double = 48_000
    ) -> AudioSourceMetadata {
        AudioSourceMetadata(
            fileName: "\(title).\(fileExtension)",
            containerName: containerName,
            codecName: codecName,
            layoutName: layoutName,
            channelSummary: "FL, FR",
            channelCount: channelCount,
            sampleRate: sampleRate,
            bitDepth: 24,
            duration: 180,
            title: title,
            album: "Local Album",
            artist: "Local Artist"
        )
    }

    private static func roonNowPlaying(title: String) -> RoonNowPlaying {
        RoonNowPlaying(
            zoneName: "Orbisonic",
            qualityFormat: "HighQuality, 24/96 FLAC => 24/96",
            bufferStatus: "100%",
            state: "PLAYING",
            positionText: "1:23",
            durationText: "4:56",
            title: title,
            artist: "Roon Artist",
            updatedText: "test",
            rawLine: "test"
        )
    }

    private static func roonSignalPath(sourceChannelCount: Int?) -> RoonSignalPath {
        RoonSignalPath(
            sourceFormat: "Flac 96000/24/\(sourceChannelCount ?? 0) Quality=Lossless",
            sourceChannelCount: sourceChannelCount,
            channelMapping: sourceChannelCount == 2 ? "2.0 -> 2.0" : "\(sourceChannelCount ?? 0).0 -> \(sourceChannelCount ?? 0).0",
            device: "Orbisonic Roon Input",
            output: "BlackHole 64ch"
        )
    }

    private static func roonBridgeSnapshot(state: String) -> RoonBridgeSnapshot {
        let zone = RoonBridgeZone(
            zoneId: "zone-orbisonic",
            displayName: "Orbisonic",
            state: state,
            isPlayAllowed: state != "playing",
            isPauseAllowed: state == "playing" || state == "loading",
            isPreviousAllowed: true,
            isNextAllowed: true,
            isSeekAllowed: true,
            outputs: [
                RoonBridgeOutput(
                    outputId: "output-orbisonic",
                    displayName: "Orbisonic Roon Input",
                    state: nil
                )
            ],
            nowPlaying: nil,
            controls: nil
        )

        return RoonBridgeSnapshot(
            ok: true,
            updatedAt: "test",
            bridge: RoonBridgeInfo(
                state: "paired",
                message: "Connected to Roon Server.",
                zoneHint: "Orbisonic Roon Input"
            ),
            core: RoonBridgeCore(
                coreId: "core",
                displayName: "Roon Server",
                displayVersion: nil
            ),
            selectedZoneId: zone.zoneId,
            selectedZone: zone,
            zones: [zone]
        )
    }

    @MainActor
    private static func waitForSourceMode(
        _ model: OrbisonicViewModel,
        _ mode: SourceMode,
        timeout: TimeInterval = 20
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while (model.sourceMode != mode || model.isLiveMonitorTransitioning), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.sourceMode, mode)
        XCTAssertFalse(model.isLiveMonitorTransitioning)
    }

    private static func inputRoute(for device: OrbisonicLoopbackDevice) -> InputRouteInfo {
        InputRouteInfo(
            deviceID: 101,
            uid: device.deviceUID,
            deviceName: device.displayName,
            manufacturer: "Orbisonic",
            transportName: "Virtual",
            inputChannelCount: device == .auxCable ? 64 : 2,
            nominalSampleRate: 44_100
        )
    }

    private static func spotifyReceiverRunningStatus() -> SpotifyReceiverStatus {
        SpotifyReceiverStatus(
            state: .waitingForConnection,
            message: "Spotify Connect receiver is advertising as Orbisonic Spotify."
        )
    }

    private static func localTrack(title: String, artworkPath: String?, fileExtension: String = "flac") -> LocalMusicTrack {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title.replacingOccurrences(of: " ", with: "-")).\(fileExtension)", isDirectory: false)
        return LocalMusicTrack(
            path: url.path,
            rootPath: url.deletingLastPathComponent().path,
            fileName: url.lastPathComponent,
            title: title,
            artist: "Local Artist",
            album: "Local Album",
            channelCount: 2,
            channelSummary: "FL, FR",
            layoutName: "Stereo",
            sampleRate: 48_000,
            duration: 180,
            artworkPath: artworkPath
        )
    }

    private static func spotifyNowPlaying(
        title: String,
        isPlaying: Bool,
        coverURL: String? = nil,
        sessionActive: Bool? = true
    ) -> SpotifyNowPlaying {
        SpotifyNowPlaying(
            title: title,
            album: "Album",
            artists: ["Artist"],
            albumArtists: ["Artist"],
            uri: "spotify:track:\(title.replacingOccurrences(of: " ", with: "-"))",
            durationMs: 180_000,
            positionMs: isPlaying ? 42_000 : 43_000,
            isPlaying: isPlaying,
            isExplicit: false,
            popularity: nil,
            trackNumber: nil,
            discNumber: nil,
            coverURL: coverURL,
            volume: nil,
            shuffle: nil,
            repeatContext: nil,
            repeatTrack: nil,
            autoPlay: nil,
            clientName: sessionActive == true ? "Spotify" : nil,
            sessionActive: sessionActive,
            updatedAt: isPlaying ? "playing" : "paused"
        )
    }
}
