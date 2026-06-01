import XCTest

final class OrbisonicUITweakTests: XCTestCase {
    func testRendererPanelIsSimpleTwoChannelControlAndTuningIsCollapsible() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let rendererStart = try XCTUnwrap(source.range(of: "private var rendererTab"))
        let rendererEnd = try XCTUnwrap(source.range(of: "private var rendererModeSelector", range: rendererStart.upperBound..<source.endIndex))
        let rendererTab = String(source[rendererStart.lowerBound..<rendererEnd.lowerBound])
        let selectorStart = rendererEnd
        let selectorEnd = try XCTUnwrap(source.range(of: "private func rendererModeButtonLabel", range: selectorStart.upperBound..<source.endIndex))
        let rendererSelector = String(source[selectorStart.lowerBound..<selectorEnd.lowerBound])

        XCTAssertFalse(source.contains("Safe Tuning"))
        XCTAssertTrue(source.contains("title: \"Tuning\""))
        XCTAssertTrue(source.contains("isExpanded: $rendererTuningExpanded"))
        XCTAssertFalse(rendererTab.contains("OrbitalSonicSphereMeterPanel("))
        XCTAssertFalse(rendererTab.contains("Orbital View"))
        XCTAssertFalse(rendererTab.contains("infoRow(title: \"Atmos\""))
        // New renderer I/O tab: Mode + Input row, then two clearly-labeled Output panels.
        XCTAssertTrue(rendererTab.contains("settingsPanel(title: \"Mode\", minHeight: selectedSourceCardMinHeight, fillsHeight: true)"))
        XCTAssertTrue(rendererTab.contains("settingsPanel(title: \"Input\", minHeight: selectedSourceCardMinHeight, fillsHeight: true)"))
        XCTAssertTrue(rendererTab.contains("settingsPanel(title: \"Output 1 Listen Locally\", fillsHeight: true)"))
        XCTAssertTrue(rendererTab.contains("settingsPanel(title: \"Output 2 Sonic Sphere\", fillsHeight: true)"))
        XCTAssertFalse(rendererTab.contains("settingsPanel(title: \"Monitor Downmix\""))
        XCTAssertFalse(rendererTab.contains("settingsPanel(title: \"Sonic Sphere Render\""))
        // Active renderer's exact name + stable ID surfaced in the Sonic Sphere output panel.
        XCTAssertTrue(rendererTab.contains("PlayerDetailRow(title: \"Renderer ID\", value: rendererID)"))
        XCTAssertTrue(rendererTab.contains("model.rendererScene.renderMode.rawValue"))
        // Multi-stream input presentation selector.
        XCTAssertTrue(rendererTab.contains("rendererInputStreamSelector"))
        XCTAssertTrue(rendererTab.contains("model.selectLocalAudioPresentation(streamIndex:"))
        XCTAssertFalse(source.contains("rendererPanelEqualHeight"))
        XCTAssertFalse(source.contains("EqualHeightPanelPreferenceKey"))
        XCTAssertFalse(source.contains("recordsEqualHeightPanel()"))
        XCTAssertTrue(rendererSelector.contains("Toggle(\"Mono\""))
        XCTAssertTrue(rendererSelector.contains("Picker(\"2-channel\""))
        XCTAssertFalse(rendererSelector.contains("LazyVGrid"))
        XCTAssertFalse(rendererSelector.contains("model.setRendererRenderMode(mode)"))
    }

    func testRendererTabNoLongerHostsOrbitalVUMeterPanel() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let rendererStart = try XCTUnwrap(source.range(of: "private var rendererTab"))
        let rendererEnd = try XCTUnwrap(source.range(of: "private var rendererModeSelector", range: rendererStart.upperBound..<source.endIndex))
        let rendererTab = String(source[rendererStart.lowerBound..<rendererEnd.lowerBound])

        XCTAssertFalse(rendererTab.contains("OrbitalSonicSphereMeterPanel("))
        XCTAssertFalse(rendererTab.contains("SonicSphereRendererSceneView("))
        XCTAssertFalse(rendererTab.contains("Orbital View"))
    }

    func testSettingsCleanupAndOutputWebpagePanel() throws {
        let contentSource = try source("Sources/Orbisonic/ContentView.swift")
        let themeSource = try source("Sources/Orbisonic/OrbisonicTheme.swift")
        let settingsStart = try XCTUnwrap(contentSource.range(of: "private var settingsTab"))
        let settingsEnd = try XCTUnwrap(contentSource.range(of: "private var vuMeterCalibrationControls", range: settingsStart.upperBound..<contentSource.endIndex))
        let settingsTab = String(contentSource[settingsStart.lowerBound..<settingsEnd.lowerBound])
        let watchFoldersStart = try XCTUnwrap(settingsTab.range(of: "title: \"Watch Folders\""))
        let watchFoldersEnd = try XCTUnwrap(settingsTab.range(of: "title: \"Sound Settings\"", range: watchFoldersStart.upperBound..<settingsTab.endIndex))
        let watchFoldersPanel = String(settingsTab[watchFoldersStart.lowerBound..<watchFoldersEnd.lowerBound])

        XCTAssertFalse(contentSource.contains("settingsPanel(title: \"Web Pages\")"))
        XCTAssertFalse(contentSource.contains("Album Art And Local Database"))
        XCTAssertFalse(contentSource.contains("Logs And Diagnostics"))
        XCTAssertFalse(contentSource.contains("infoRow(title: \"Status\", value: model.webServerStatus)"))
        XCTAssertTrue(contentSource.contains("settingsPanel(title: \"Now playing on Sonic Sphere webpage (local network only)\""))
        XCTAssertTrue(contentSource.contains("webURLRow(title: \"Link\", url: model.webPublicPageURL)"))
        XCTAssertFalse(contentSource.contains("outputLanePanelHeight"))
        XCTAssertTrue(contentSource.contains("OutputLaneNaturalHeightPreferenceKey"))
        XCTAssertTrue(contentSource.contains("outputLaneEqualHeight"))
        XCTAssertTrue(contentSource.contains("title: \"Watch Folders\""))
        XCTAssertFalse(contentSource.contains("settingsPanel(title: \"M3U Playlists\""))
        XCTAssertFalse(contentSource.contains("Label(\"Add Music Folder\""))
        XCTAssertFalse(contentSource.contains("Label(\"Add M3U\""))
        XCTAssertFalse(contentSource.contains("Import M3U files"))
        XCTAssertFalse(contentSource.contains("infoRow(title: \"Music\""))
        XCTAssertFalse(contentSource.contains("infoRow(title: \"M3U\""))
        XCTAssertTrue(contentSource.contains("Label(\"Add Folder\""))
        XCTAssertTrue(contentSource.contains("Search subfolders"))
        XCTAssertTrue(contentSource.contains("Enhance Metadata"))
        XCTAssertTrue(contentSource.contains("Use Orbisonic’s cached online names and artwork for missing local music info."))
        XCTAssertTrue(watchFoldersPanel.contains("settingsToggleRow(\n                        title: \"Search subfolders\""))
        XCTAssertTrue(watchFoldersPanel.contains("settingsToggleRow(\n                        title: \"Enhance Metadata\""))
        XCTAssertFalse(watchFoldersPanel.contains("HStack(spacing: 16)"))
        XCTAssertFalse(watchFoldersPanel.contains("Toggle(\n                            \"Search subfolders\""))
        XCTAssertTrue(contentSource.contains("infoRow(title: \"Folders\""))
        XCTAssertTrue(contentSource.contains("title: \"Sound Settings\""))
        XCTAssertFalse(contentSource.contains("settingsPanel(title: \"Max Volume Limiter\""))
        XCTAssertFalse(contentSource.contains("settingsPanel(title: \"Local Playback QA\""))
        XCTAssertFalse(contentSource.contains("Picker(\"Atmos DRP Layout\""))
        XCTAssertFalse(contentSource.contains("Dolby Reference Player output layout."))
        XCTAssertTrue(settingsTab.contains("EqualHeightPanelRow(spacing: 18)"))
        XCTAssertTrue(settingsTab.contains("title: \"Watch Folders\",\n                    fillsHeight: true"))
        XCTAssertTrue(settingsTab.contains("title: \"Sound Settings\",\n                    fillsHeight: true"))
        XCTAssertFalse(contentSource.contains("settingsTopPanelEqualHeight"))
        XCTAssertFalse(contentSource.contains("EqualHeightPanelPreferenceKey"))
        XCTAssertFalse(contentSource.contains("recordsEqualHeightPanel()"))
        XCTAssertFalse(contentSource.contains("localMusicSettingsPanelMinHeight"))
        XCTAssertFalse(settingsTab.contains("Current Effective Volume"))
        XCTAssertFalse(settingsTab.contains("Uses the feature-gated local gapless scheduler"))
        XCTAssertFalse(settingsTab.contains("Only applies trusted Core Audio trim metadata"))
        XCTAssertFalse(settingsTab.contains("infoRow(\n                        title: \"State\""))
        XCTAssertTrue(settingsTab.contains("settingsToggleRow(\n                        title: \"Gapless local playback\""))
        XCTAssertTrue(settingsTab.contains("settingsToggleRow(\n                        title: \"Compressed trim metadata\""))
        XCTAssertTrue(settingsTab.contains("colorThemePanel"))
        XCTAssertTrue(contentSource.contains("settingsPanel(title: \"Color Theme\""))
        XCTAssertTrue(contentSource.contains("@AppStorage(OrbisonicColorScheme.storageKey)"))
        XCTAssertTrue(themeSource.contains("static let defaultScheme: OrbisonicColorScheme = .lab"))
        XCTAssertTrue(themeSource.contains("if rawValue == \"techRainbow\""))
        XCTAssertTrue(themeSource.contains("private static let daftRainbowWell = rgb(52, 64, 71)"))
        XCTAssertTrue(themeSource.contains("var linearControlWell"))
        XCTAssertTrue(themeSource.contains("var linearControlThumb"))
        [
            "Orbisonic Lab",
            "Kimi Purple",
            "Daft Punk Bow",
            "Rack Mint",
            "Rack Pink",
            "Rack Blue",
            "Ember Console",
            "Graphite",
            "Flamingo Green",
            "Flamingo Pink",
            "Dusty Rose"
        ].forEach { name in
            XCTAssertTrue(themeSource.contains(name), "Missing imported theme name: \(name)")
        }
    }

    func testVUOptionsHideObsoleteColorModePicker() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let optionsStart = try XCTUnwrap(source.range(of: "private var vuOptionsPanel"))
        let optionsEnd = try XCTUnwrap(source.range(of: "private var analyzerVUStylePicker", range: optionsStart.upperBound..<source.endIndex))
        let optionsPanel = String(source[optionsStart.lowerBound..<optionsEnd.lowerBound])
        let appearanceStart = try XCTUnwrap(source.range(of: "private var vuMeterAppearanceSliders"))
        let appearanceEnd = try XCTUnwrap(source.range(of: "private func vuSliderRow", range: appearanceStart.upperBound..<source.endIndex))
        let appearancePanel = String(source[appearanceStart.lowerBound..<appearanceEnd.lowerBound])

        XCTAssertTrue(optionsPanel.contains("title: \"VU Options\""))
        XCTAssertFalse(source.contains("private var vuMeterColorModePicker"))
        XCTAssertFalse(appearancePanel.contains("System Green"))
        XCTAssertFalse(appearancePanel.contains("Sparkle"))
        XCTAssertFalse(appearancePanel.contains("Classic"))
    }

    func testThemeLinearControlsReplaceNativeTintedSliders() throws {
        let contentSource = try source("Sources/Orbisonic/ContentView.swift")
        let themeSource = try source("Sources/Orbisonic/OrbisonicTheme.swift")

        XCTAssertTrue(contentSource.contains("private struct OrbisonicLinearControl"))
        XCTAssertTrue(contentSource.contains("palette.linearControlWell"))
        XCTAssertTrue(contentSource.contains("palette.linearControlGradient"))
        XCTAssertTrue(contentSource.contains("palette.linearControlThumb"))
        XCTAssertTrue(themeSource.contains("compressesLinearControlRampIntoActiveSegment"))
        XCTAssertTrue(themeSource.contains("usesCompressedRainbowLinearControls ? compressedRainbowWell : toolbar.opacity(0.82)"))
        XCTAssertTrue(themeSource.contains("accent: Self.rgb(170, 136, 255)"))
        XCTAssertEqual(contentSource.components(separatedBy: "Slider(value:").count - 1, 1)

        let linearControlStart = try XCTUnwrap(contentSource.range(of: "private struct OrbisonicLinearControl"))
        let linearControlEnd = try XCTUnwrap(contentSource.range(of: "private struct PlayerArtworkView", range: linearControlStart.upperBound..<contentSource.endIndex))
        let linearControl = String(contentSource[linearControlStart.lowerBound..<linearControlEnd.lowerBound])
        XCTAssertTrue(linearControl.contains(".gesture(linearDragGesture(width: width))"))
        XCTAssertTrue(linearControl.contains("DragGesture(minimumDistance: 0)"))
        XCTAssertTrue(linearControl.contains("updateValue(at: gesture.location.x, width: width)"))
        XCTAssertTrue(linearControl.contains(".allowsHitTesting(false)"))

        let volumeStart = try XCTUnwrap(contentSource.range(of: "private var sphereVolumeControl"))
        let volumeEnd = try XCTUnwrap(contentSource.range(of: "private var playerProgressControl", range: volumeStart.upperBound..<contentSource.endIndex))
        let volumeControl = String(contentSource[volumeStart.lowerBound..<volumeEnd.lowerBound])
        XCTAssertTrue(volumeControl.contains("OrbisonicLinearControl(value: $model.sphereOutputVolumePercent"))
        XCTAssertFalse(volumeControl.contains(".tint(LabTheme.cyan)"))

        let progressStart = volumeEnd
        let progressEnd = try XCTUnwrap(contentSource.range(of: "private var isPlayerProgressEditable", range: progressStart.upperBound..<contentSource.endIndex))
        let progressControl = String(contentSource[progressStart.lowerBound..<progressEnd.lowerBound])
        XCTAssertTrue(progressControl.contains("OrbisonicLinearControl("))
        XCTAssertFalse(progressControl.contains(".tint(LabTheme.cyan)"))

        let vuSliderStart = try XCTUnwrap(contentSource.range(of: "private func vuSliderRow"))
        let vuSliderEnd = try XCTUnwrap(contentSource.range(of: "private func signedOffsetText", range: vuSliderStart.upperBound..<contentSource.endIndex))
        let vuSlider = String(contentSource[vuSliderStart.lowerBound..<vuSliderEnd.lowerBound])
        XCTAssertTrue(vuSlider.contains("OrbisonicLinearControl(value: binding, range: range)"))
        XCTAssertFalse(vuSlider.contains(".tint(LabTheme.cyan)"))

        let tuningStart = try XCTUnwrap(contentSource.range(of: "private func tuningSlider"))
        let tuningEnd = try XCTUnwrap(contentSource.range(of: "private func centeredTuningBinding", range: tuningStart.upperBound..<contentSource.endIndex))
        let tuningSliders = String(contentSource[tuningStart.lowerBound..<tuningEnd.lowerBound])
        XCTAssertTrue(tuningSliders.contains("OrbisonicLinearControl(value: value, range: range)"))
        XCTAssertTrue(tuningSliders.contains("OrbisonicLinearControl(\n                value: centeredTuningBinding"))
        XCTAssertFalse(tuningSliders.contains(".tint(LabTheme.cyan)"))
    }

    func testDaftPunkMetersUseCompressedActiveRamp() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")

        XCTAssertTrue(source.contains("private static func meterFillShading"))
        XCTAssertTrue(source.contains("palette.compressesLinearControlRampIntoActiveSegment"))
        XCTAssertTrue(source.contains("axis: .vertical"))
        XCTAssertTrue(source.contains("private func daftPunkOutputMeterVisual"))
        XCTAssertTrue(source.contains("private func daftPunkSceneMeterColor"))
    }

    func testPlaylistContextMenusCanAddCurrentAndQueuedTracksToPlaylist() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")

        XCTAssertTrue(source.contains("private func addToPlaylistMenu(for track: LocalMusicTrack) -> some View"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "addToPlaylistMenu(for: track)").count - 1, 3)
        XCTAssertTrue(source.contains("model.addLocalMusicTrackToPlaylist(track, playlist)"))
        XCTAssertTrue(source.contains("beginCreatePlaylist(for: track)"))
    }

    func testPlaylistRowsExposeReorderAndDeleteActions() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")

        XCTAssertTrue(source.contains("model.moveLocalMusicPlaylistUp(playlist)"))
        XCTAssertTrue(source.contains("model.moveLocalMusicPlaylistDown(playlist)"))
        XCTAssertTrue(source.contains("beginDeletePlaylist(playlist)"))
        XCTAssertTrue(source.contains("Delete Playlist"))
        XCTAssertTrue(source.contains("Remove Playlist"))
    }

    func testSelectedPlaylistPanelDoesNotShowVisibleReorderButtons() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let start = try XCTUnwrap(source.range(of: "private var localMusicSelectedPlaylistPanel"))
        let end = try XCTUnwrap(source.range(of: "private var localMusicQueuePanel", range: start.upperBound..<source.endIndex))
        let selectedPlaylistPanel = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(selectedPlaylistPanel.contains("model.moveLocalMusicPlaylistUp(playlist)"))
        XCTAssertFalse(selectedPlaylistPanel.contains("model.moveLocalMusicPlaylistDown(playlist)"))
        XCTAssertFalse(selectedPlaylistPanel.contains("Label(\"Move Up\""))
        XCTAssertFalse(selectedPlaylistPanel.contains("Label(\"Move Down\""))
    }

    func testLocalMusicListsPlaylistsAndQueueUseSpotifyStyleAlbumArtThumbnails() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let thumbnailStart = try XCTUnwrap(source.range(of: "private struct LocalMusicThumbnailView"))
        let thumbnailEnd = try XCTUnwrap(source.range(of: "struct ContentView", range: thumbnailStart.upperBound..<source.endIndex))
        let thumbnailView = String(source[thumbnailStart.lowerBound..<thumbnailEnd.lowerBound])
        let trackLibraryStart = try XCTUnwrap(source.range(of: "private func trackLibraryRow"))
        let trackLibraryEnd = try XCTUnwrap(source.range(of: "private func playlistLibraryRow", range: trackLibraryStart.upperBound..<source.endIndex))
        let trackLibraryRow = String(source[trackLibraryStart.lowerBound..<trackLibraryEnd.lowerBound])
        let playlistLibraryStart = try XCTUnwrap(source.range(of: "private func playlistLibraryRow"))
        let playlistLibraryEnd = try XCTUnwrap(source.range(of: "private func playlistTrackRow", range: playlistLibraryStart.upperBound..<source.endIndex))
        let playlistLibraryRow = String(source[playlistLibraryStart.lowerBound..<playlistLibraryEnd.lowerBound])
        let playlistTrackStart = playlistLibraryEnd
        let playlistTrackEnd = try XCTUnwrap(source.range(of: "private func queueTrackRow", range: playlistTrackStart.upperBound..<source.endIndex))
        let playlistTrackRow = String(source[playlistTrackStart.lowerBound..<playlistTrackEnd.lowerBound])
        let queueTrackStart = playlistTrackEnd
        let queueTrackEnd = try XCTUnwrap(source.range(of: "private func playlistArtworkPath", range: queueTrackStart.upperBound..<source.endIndex))
        let queueTrackRow = String(source[queueTrackStart.lowerBound..<queueTrackEnd.lowerBound])
        let playlistArtworkStart = queueTrackEnd
        let playlistArtworkEnd = try XCTUnwrap(source.range(of: "@ViewBuilder", range: playlistArtworkStart.upperBound..<source.endIndex))
        let playlistArtworkHelper = String(source[playlistArtworkStart.lowerBound..<playlistArtworkEnd.lowerBound])

        XCTAssertTrue(thumbnailView.contains("let artworkPath: String?"))
        XCTAssertTrue(thumbnailView.contains("private let size: CGFloat = 40"))
        XCTAssertTrue(thumbnailView.contains("NSImage(contentsOf: URL(fileURLWithPath: path))"))
        XCTAssertTrue(thumbnailView.contains("fallbackSystemImage"))
        XCTAssertTrue(trackLibraryRow.contains("LocalMusicThumbnailView(artworkPath: track.artworkPath)"))
        XCTAssertTrue(trackLibraryRow.contains(".frame(height: 56)"))
        XCTAssertTrue(playlistLibraryRow.contains("LocalMusicThumbnailView("))
        XCTAssertTrue(playlistLibraryRow.contains("playlistArtworkPath(for: playlist)"))
        XCTAssertTrue(playlistLibraryRow.contains(".frame(height: 56)"))
        XCTAssertTrue(playlistTrackRow.contains("LocalMusicThumbnailView(artworkPath: track?.artworkPath)"))
        XCTAssertTrue(playlistTrackRow.contains(".frame(height: 56)"))
        XCTAssertTrue(playlistTrackRow.contains("Button(\"Remove From Playlist\")"))
        XCTAssertTrue(queueTrackRow.contains("LocalMusicThumbnailView(artworkPath: track.artworkPath)"))
        XCTAssertTrue(queueTrackRow.contains(".frame(height: 56)"))
        XCTAssertTrue(queueTrackRow.contains("addToPlaylistMenu(for: track)"))
        XCTAssertTrue(playlistArtworkHelper.contains("model.localMusicTracks.first"))
        XCTAssertTrue(playlistArtworkHelper.contains("track.artworkPath?.trimmedNilIfBlank"))
    }

    func testDiagnosticsClosablePanelsDefaultCollapsed() throws {
        let source = try source("Sources/Orbisonic/DiagnosticsView.swift")

        XCTAssertFalse(source.contains("defaultExpanded: true"))
        XCTAssertFalse(source.contains("defaultExpanded: model.sourceMode"))
        XCTAssertFalse(source.contains("defaultExpanded || !warnings.isEmpty"))
        XCTAssertTrue(source.contains("expansionBinding(for: id, defaultExpanded: defaultExpanded)"))
    }

    func testLoadingStatusChipUsesAnimatedCrosshatch() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")

        XCTAssertTrue(source.contains("StatusChipBackground"))
        XCTAssertTrue(source.contains("LoadingCrosshatchStripePattern"))
        XCTAssertTrue(source.contains("TimelineView(.animation)"))
        XCTAssertTrue(source.contains("statusChipIsLoading"))
    }

    func testPlayerArtworkUsesLargeVerticalMediaLayout() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let artworkStart = try XCTUnwrap(source.range(of: "private struct PlayerArtworkView"))
        let artworkEnd = try XCTUnwrap(source.range(of: "private struct LocalMusicThumbnailView", range: artworkStart.upperBound..<source.endIndex))
        let artworkView = String(source[artworkStart.lowerBound..<artworkEnd.lowerBound])
        let mediaStart = try XCTUnwrap(source.range(of: "private var nowPlayingMediaBlock"))
        let mediaEnd = try XCTUnwrap(source.range(of: "private var playerTransportControls", range: mediaStart.upperBound..<source.endIndex))
        let mediaBlock = String(source[mediaStart.lowerBound..<mediaEnd.lowerBound])

        XCTAssertFalse(artworkView.contains("private let size: CGFloat = 58"))
        XCTAssertFalse(artworkView.contains(".frame(width: size, height: size)"))
        XCTAssertTrue(artworkView.contains(".aspectRatio(1, contentMode: .fit)"))
        XCTAssertTrue(artworkView.contains(".frame(maxWidth: .infinity)"))
        XCTAssertTrue(mediaBlock.contains("VStack(alignment: .leading, spacing: 8)"))
        XCTAssertTrue(mediaBlock.contains("PlayerRailLayout.artworkSize"))
        XCTAssertFalse(mediaBlock.contains("HStack(alignment: .center, spacing: 12)"))
        XCTAssertTrue(mediaBlock.contains("PlayerArtworkView(url: nowPlayingArtworkURL)"))
        XCTAssertTrue(mediaBlock.contains("Text(nowPlayingTitle)"))
        XCTAssertTrue(mediaBlock.contains("Text(nowPlayingSubtitle)"))
        XCTAssertTrue(mediaBlock.contains("addToPlaylistMenu(for: track)"))
    }

    func testPlayerRailIsFixedHeightAndNotScrollable() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let sidebarStart = try XCTUnwrap(source.range(of: "private var sidebar"))
        let sidebarEnd = try XCTUnwrap(source.range(of: "private var stage", range: sidebarStart.upperBound..<source.endIndex))
        let sidebar = String(source[sidebarStart.lowerBound..<sidebarEnd.lowerBound])
        let playerStart = try XCTUnwrap(source.range(of: "private var nowPlayingSessionCard"))
        let playerEnd = try XCTUnwrap(source.range(of: "private var nowPlayingMediaBlock", range: playerStart.upperBound..<source.endIndex))
        let playerCard = String(source[playerStart.lowerBound..<playerEnd.lowerBound])

        XCTAssertTrue(source.contains("private enum PlayerRailLayout"))
        XCTAssertTrue(source.contains("static let sidebarWidth: CGFloat = 360"))
        XCTAssertTrue(source.contains("static let artworkSize: CGFloat = 284"))
        XCTAssertTrue(source.contains(".frame(width: PlayerRailLayout.sidebarWidth, alignment: .topLeading)"))
        XCTAssertTrue(source.contains(".frame(maxHeight: .infinity, alignment: .topLeading)"))
        XCTAssertFalse(sidebar.contains("ScrollView"))
        XCTAssertTrue(sidebar.contains("VStack(alignment: .leading, spacing: 14)"))
        XCTAssertTrue(sidebar.contains("nowPlayingSessionCard\n                .frame(maxHeight: .infinity"))
        XCTAssertTrue(sidebar.contains(".clipped()"))
        XCTAssertTrue(playerCard.contains("playerRailCard"))
        XCTAssertTrue(playerCard.contains(".frame(maxHeight: .infinity, alignment: .topLeading)"))
        XCTAssertTrue(playerCard.contains("Spacer(minLength: 0)"))
    }

    func testPlayerDetailsAreCappedToFourSingleLineRows() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let detailStart = try XCTUnwrap(source.range(of: "private var playerDetailContent"))
        let detailEnd = try XCTUnwrap(source.range(of: "private var playerDetailRows", range: detailStart.upperBound..<source.endIndex))
        let detailContent = String(source[detailStart.lowerBound..<detailEnd.lowerBound])
        let rowStart = try XCTUnwrap(source.range(of: "private func playerDetailRowView"))
        let rowEnd = try XCTUnwrap(source.range(of: "private func nonEmptyPlayerRows", range: rowStart.upperBound..<source.endIndex))
        let rowView = String(source[rowStart.lowerBound..<rowEnd.lowerBound])
        let filterStart = rowEnd
        let filterEnd = try XCTUnwrap(source.range(of: "private var liveInputPlaybackErrorText", range: filterStart.upperBound..<source.endIndex))
        let rowFilter = String(source[filterStart.lowerBound..<filterEnd.lowerBound])

        XCTAssertTrue(source.contains("static let detailRowLimit = 4"))
        XCTAssertTrue(detailContent.contains("PlayerRailLayout.detailContentHeight"))
        XCTAssertTrue(detailContent.contains(".frame(height: PlayerRailLayout.detailContentHeight"))
        XCTAssertTrue(detailContent.contains(".clipped()"))
        XCTAssertTrue(rowFilter.contains("Array(filtered.prefix(PlayerRailLayout.detailRowLimit))"))
        XCTAssertTrue(rowView.contains(".lineLimit(1)"))
        XCTAssertTrue(rowView.contains(".truncationMode(.tail)"))
        XCTAssertTrue(rowView.contains(".truncationMode(.middle)"))
        XCTAssertTrue(rowView.contains("height: PlayerRailLayout.detailRowHeight"))
        XCTAssertFalse(rowView.contains(".lineLimit(2)"))
        XCTAssertFalse(rowView.contains("minHeight: 28"))
    }

    func testLocalMusicPlayerRowsStayOnFourVisibleFacts() throws {
        let source = try source("Sources/Orbisonic/ContentView.swift")
        let modelStart = try XCTUnwrap(source.range(of: "enum LocalFilePlayerRowsModel"))
        let modelEnd = try XCTUnwrap(source.range(of: "enum RoonPlayerRowsModel", range: modelStart.upperBound..<source.endIndex))
        let rowsModel = String(source[modelStart.lowerBound..<modelEnd.lowerBound])
        let localRowsStart = try XCTUnwrap(source.range(of: "private var localFilePlayerRows"))
        let localRowsEnd = try XCTUnwrap(source.range(of: "private func playerDetailRow", range: localRowsStart.upperBound..<source.endIndex))
        let localRows = String(source[localRowsStart.lowerBound..<localRowsEnd.lowerBound])

        XCTAssertTrue(rowsModel.contains("PlayerDetailRowContent(title: \"Format\""))
        XCTAssertTrue(rowsModel.contains("PlayerDetailRowContent(title: \"Channels\""))
        XCTAssertTrue(rowsModel.contains("PlayerDetailRowContent(title: \"Layout\""))
        XCTAssertTrue(rowsModel.contains("PlayerDetailRowContent(title: \"Length\""))
        XCTAssertFalse(rowsModel.contains("PlayerDetailRowContent(title: \"Note\""))
        XCTAssertTrue(localRows.contains("LocalFilePlayerRowsModel.rows(metadata: metadata).map(playerDetailRow)"))
        XCTAssertTrue(localRows.contains("LocalFilePlayerRowsModel.rows(track: track).map(playerDetailRow)"))
        XCTAssertTrue(source.contains("case .filePlayback:\n            return nonEmptyPlayerRows(localFilePlayerRows)"))
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
