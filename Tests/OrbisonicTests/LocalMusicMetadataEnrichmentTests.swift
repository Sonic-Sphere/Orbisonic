import XCTest
@testable import Orbisonic

final class LocalMusicMetadataEnrichmentTests: XCTestCase {
    @MainActor
    func testEnhanceMetadataDefaultsOn() {
        XCTAssertTrue(LocalMusicSettings().enhancesMetadata)
    }

    @MainActor
    func testCachedOverlayCanBeDisabledAndRestored() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("missing-title.wav")
        try Data([1, 2, 3]).write(to: audioURL)
        let track = Self.track(url: audioURL, title: nil, artist: nil, album: nil)
        let overlay = LocalMusicMetadataOverlay(
            title: "Resolved Title",
            artist: "Resolved Artist",
            album: "Resolved Album",
            artworkPath: fixture.artworkURL.path,
            sourceName: "Test",
            confidence: 0.98
        )
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [track],
            playlists: [],
            metadataOverlays: [track.id: overlay]
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.stubLoader,
            localMusicLibrary: library,
            preloadFirstLocalMusicTrack: false
        )

        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayTitle, "Resolved Title")
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayArtist, "Resolved Artist")
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayAlbum, "Resolved Album")
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.artworkPath, fixture.artworkURL.path)

        model.setLocalMusicEnhancesMetadata(false)

        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayTitle, "missing-title")
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayArtist, "-")
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayAlbum, "-")
        XCTAssertNil(model.visibleLocalMusicTracks.first?.artworkPath)
        XCTAssertEqual(library.load().metadataOverlays[track.id], overlay)

        model.setLocalMusicEnhancesMetadata(true)
        await model.waitForLocalMusicMetadataEnrichmentForTesting()

        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayTitle, "Resolved Title")
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.artworkPath, fixture.artworkURL.path)
    }

    @MainActor
    func testDisabledEnhanceMetadataPreventsLookupWork() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("disabled.wav")
        try Data([1]).write(to: audioURL)
        let track = Self.track(url: audioURL, title: nil, artist: nil, album: nil)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(enhancesMetadata: false),
            tracks: [track],
            playlists: []
        ))
        let enricher = CountingMetadataEnricher()
        let model = OrbisonicViewModel(
            localAudioLoader: Self.stubLoader,
            localMusicLibrary: library,
            localMusicMetadataEnricher: enricher,
            preloadFirstLocalMusicTrack: false
        )

        await model.waitForLocalMusicMetadataEnrichmentForTesting()

        XCTAssertFalse(model.localMusicSettings.enhancesMetadata)
        XCTAssertEqual(enricher.callCount, 0)
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayTitle, "disabled")
    }

    @MainActor
    func testHighConfidenceLookupAppliesOverlayAndDoesNotModifyMusicFile() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("unknown.wav")
        try Data([1, 2, 3, 4]).write(to: audioURL)
        let originalModifiedAt = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: audioURL.path)[.modificationDate] as? Date)
        let track = Self.track(url: audioURL, title: nil, artist: nil, album: nil)
        let lookup = FakeLookupClient(results: [
            track.id: LocalMusicMetadataLookupResult(
                overlay: LocalMusicMetadataOverlay(
                    title: "Found Title",
                    artist: "Found Artist",
                    album: "Found Album",
                    sourceName: "FakeBrainz",
                    sourceIdentifier: "recording-1",
                    confidence: 0.97
                ),
                artworkData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                artworkSourceURL: URL(string: "https://example.invalid/cover.jpg")
            )
        ])
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(settings: LocalMusicSettings(), tracks: [track], playlists: []))
        let enricher = LocalMusicMetadataEnricher(
            library: library,
            lookupClient: lookup,
            lookupDelayNanoseconds: 0
        )
        let model = OrbisonicViewModel(
            localAudioLoader: Self.stubLoader,
            localMusicLibrary: library,
            localMusicMetadataEnricher: enricher,
            preloadFirstLocalMusicTrack: false
        )

        await model.waitForLocalMusicMetadataEnrichmentForTesting()

        let enhancedTrack = try XCTUnwrap(model.visibleLocalMusicTracks.first)
        XCTAssertEqual(enhancedTrack.displayTitle, "Found Title")
        XCTAssertEqual(enhancedTrack.displayArtist, "Found Artist")
        XCTAssertEqual(enhancedTrack.displayAlbum, "Found Album")
        let artworkPath = try XCTUnwrap(enhancedTrack.artworkPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkPath))
        XCTAssertEqual(lookup.lookupCount, 1)
        XCTAssertEqual(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: audioURL.path)[.modificationDate] as? Date), originalModifiedAt)
        XCTAssertEqual(library.load().metadataOverlays[track.id]?.sourceName, "FakeBrainz")
    }

    func testHighConfidenceLookupCheckpointsOverlayBeforeBatchCompletes() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("checkpoint.wav")
        try Data([1, 2, 3]).write(to: audioURL)
        let track = Self.track(url: audioURL, title: nil, artist: nil, album: nil)
        let lookup = FakeLookupClient(results: [
            track.id: LocalMusicMetadataLookupResult(
                overlay: LocalMusicMetadataOverlay(
                    title: "Checkpoint Title",
                    sourceName: "FakeBrainz",
                    sourceIdentifier: "recording-checkpoint",
                    confidence: 0.97
                ),
                artworkData: nil,
                artworkSourceURL: nil
            )
        ])
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(settings: LocalMusicSettings(), tracks: [track], playlists: []))
        let enricher = LocalMusicMetadataEnricher(
            library: library,
            lookupClient: lookup,
            lookupDelayNanoseconds: 0
        )

        _ = await enricher.enrich(tracks: [track], existingOverlays: [:], alreadyScannedTrackIDs: [], forceRescan: true).overlays

        let persistedOverlay = try XCTUnwrap(library.load().metadataOverlays[track.id])
        XCTAssertEqual(persistedOverlay.title, "Checkpoint Title")
        XCTAssertEqual(persistedOverlay.sourceIdentifier, "recording-checkpoint")
    }

    func testLocalMusicDatabaseDecodesWithoutStoredTrackNumbers() throws {
        let data = """
        {
          "settings": { "enhancesMetadata": true },
          "tracks": [
            {
              "path": "/tmp/old.wav",
              "rootPath": "/tmp",
              "fileName": "old.wav",
              "title": "Old",
              "artist": "Artist",
              "album": "Album",
              "channelCount": 2,
              "channelSummary": "FL, FR",
              "layoutName": "Stereo",
              "sampleRate": 48000,
              "duration": 1,
              "artworkPath": null
            }
          ],
          "playlists": [],
          "metadataOverlays": {}
        }
        """.data(using: .utf8)!

        let database = try JSONDecoder().decode(LocalMusicDatabase.self, from: data)

        XCTAssertNil(database.tracks.first?.trackNumber)
        XCTAssertNil(database.tracks.first?.discNumber)
    }

    @MainActor
    func testAlbumSortUsesEnhancedOverlayTrackNumbersInsteadOfCleanTitleAlphabeticalOrder() throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let speakURL = fixture.directory.appendingPathComponent("speak.flac")
        let breatheURL = fixture.directory.appendingPathComponent("breathe.flac")
        let moneyURL = fixture.directory.appendingPathComponent("money.flac")
        try Data([1]).write(to: speakURL)
        try Data([1]).write(to: breatheURL)
        try Data([1]).write(to: moneyURL)

        let speak = Self.track(url: speakURL, title: nil, artist: nil, album: nil)
        let breathe = Self.track(url: breatheURL, title: nil, artist: nil, album: nil)
        let money = Self.track(url: moneyURL, title: nil, artist: nil, album: nil)
        let overlays = [
            speak.id: Self.overlay(title: "Speak To Me", trackNumber: 1),
            breathe.id: Self.overlay(title: "Breathe (In The Air)", trackNumber: 2),
            money.id: Self.overlay(title: "Money", trackNumber: 6)
        ]
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [money, speak, breathe],
            playlists: [],
            metadataOverlays: overlays
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.stubLoader,
            localMusicLibrary: library,
            preloadFirstLocalMusicTrack: false
        )
        model.localMusicSortMode = .album

        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayTitle), [
            "Speak To Me",
            "Breathe (In The Air)",
            "Money"
        ])
    }

    @MainActor
    func testPinkFloydShapedEnhancedAlbumSortKeepsFilenameTrackOrder() throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let entries: [(String, String, Int)] = [
            ("01 - Speak To Me.flac", "Speak To Me", 1),
            ("02 - Breathe (In The Air).flac", "Breathe (In The Air)", 2),
            ("03 - On The Run.flac", "On The Run", 3),
            ("04 - Time.flac", "Time", 4),
            ("05 - The Great Gig In The Sky.flac", "The Great Gig In The Sky", 5),
            ("06 - Money.flac", "Money", 6),
            ("07 - Us And Them.flac", "Us And Them", 7),
            ("08 - Any Colour You Like.flac", "Any Colour You Like", 8),
            ("09 - Brain Damage.flac", "Brain Damage", 9),
            ("10 - Eclipse.flac", "Eclipse", 10)
        ]
        let tracks = try entries.map { fileName, _, _ in
            let url = fixture.directory.appendingPathComponent(fileName)
            try Data([1]).write(to: url)
            return Self.track(url: url, title: nil, artist: nil, album: nil)
        }
        let overlays = Dictionary(uniqueKeysWithValues: zip(tracks, entries).map { track, entry in
            (
                track.id,
                Self.overlay(title: entry.1, trackNumber: entry.2)
            )
        })
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: tracks.shuffled(),
            playlists: [],
            metadataOverlays: overlays
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.stubLoader,
            localMusicLibrary: library,
            preloadFirstLocalMusicTrack: false
        )
        model.localMusicSortMode = .album

        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.fileName), entries.map(\.0))
        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayTitle), entries.map(\.1))
    }

    @MainActor
    func testEmbeddedMetadataRemainsPreferredOverOverlay() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("embedded.wav")
        try Data([1]).write(to: audioURL)
        let track = Self.track(
            url: audioURL,
            title: "Embedded Title",
            artist: "Embedded Artist",
            album: "Embedded Album"
        )
        let overlay = LocalMusicMetadataOverlay(
            title: "Online Title",
            artist: "Online Artist",
            album: "Online Album",
            artworkPath: fixture.artworkURL.path,
            sourceName: "Test",
            confidence: 0.99
        )
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [track],
            playlists: [],
            metadataOverlays: [track.id: overlay]
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.stubLoader,
            localMusicLibrary: library,
            preloadFirstLocalMusicTrack: false
        )

        let enhancedTrack = try XCTUnwrap(model.visibleLocalMusicTracks.first)
        XCTAssertEqual(enhancedTrack.displayTitle, "Embedded Title")
        XCTAssertEqual(enhancedTrack.displayArtist, "Embedded Artist")
        XCTAssertEqual(enhancedTrack.displayAlbum, "Embedded Album")
        XCTAssertEqual(enhancedTrack.artworkPath, fixture.artworkURL.path)
    }

    func testLowConfidenceLookupIsRejectedByEnricher() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("ambiguous.wav")
        try Data([1]).write(to: audioURL)
        let track = Self.track(url: audioURL, title: nil, artist: nil, album: nil)
        let lookup = FakeLookupClient(results: [
            track.id: LocalMusicMetadataLookupResult(
                overlay: LocalMusicMetadataOverlay(
                    title: "Wrong Maybe",
                    sourceName: "FakeBrainz",
                    confidence: 0.42
                ),
                artworkData: nil,
                artworkSourceURL: nil
            )
        ])
        let enricher = LocalMusicMetadataEnricher(
            library: LocalMusicLibrary(supportURL: fixture.supportDirectory),
            lookupClient: lookup,
            lookupDelayNanoseconds: 0
        )

        let overlays = await enricher.enrich(tracks: [track], existingOverlays: [:], alreadyScannedTrackIDs: [], forceRescan: true).overlays

        XCTAssertTrue(overlays.isEmpty)
        XCTAssertEqual(lookup.lookupCount, 1)
    }

    func testCompositeLookupContinuesAfterProviderFailure() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("fallback.wav")
        try Data([1]).write(to: audioURL)
        let track = Self.track(url: audioURL, title: "Fallback", artist: "Artist", album: "Album")
        let fallback = FakeLookupClient(results: [
            track.id: LocalMusicMetadataLookupResult(
                overlay: LocalMusicMetadataOverlay(
                    album: "Album",
                    sourceName: "Apple",
                    sourceIdentifier: "album-1",
                    confidence: 0.97
                ),
                artworkData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                artworkSourceURL: URL(string: "https://example.invalid/fallback.jpg")
            )
        ])
        let composite = CompositeLocalMusicMetadataLookupClient(clients: [
            ThrowingLookupClient(),
            fallback
        ])

        let result = try await composite.lookup(track: track)

        XCTAssertEqual(result?.overlay.sourceName, "Apple")
        XCTAssertNotNil(result?.artworkData)
        XCTAssertEqual(fallback.lookupCount, 1)
    }

    func testAppleLookupUsesAlbumLevelQueryBeforeTrackSpecificQueryForArtwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleSearchMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        AppleSearchMockURLProtocol.requests = []
        AppleSearchMockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.host == "itunes.apple.com" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let term = components?.queryItems?.first(where: { $0.name == "term" })?.value
                XCTAssertEqual(term, "Tipper Surrounded")
                let data = """
                {
                  "resultCount": 1,
                  "results": [
                    {
                      "collectionId": 283227098,
                      "artistName": "Tipper",
                      "collectionName": "Surrounded",
                      "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music/test.jpg/100x100bb.jpg"
                    }
                  ]
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }

            let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        defer {
            AppleSearchMockURLProtocol.handler = nil
            AppleSearchMockURLProtocol.requests = []
        }

        let client = AppleITunesLocalMusicMetadataLookupClient(session: session)
        let track = Self.track(
            url: URL(fileURLWithPath: "/tmp/01 Middle of Nowhere.flac"),
            title: "Middle of Nowhere",
            artist: "Tipper",
            album: "Surrounded"
        )

        let result = try await client.lookup(track: track)

        XCTAssertEqual(result?.overlay.sourceName, "Apple")
        XCTAssertNotNil(result?.artworkData)
        XCTAssertEqual(
            AppleSearchMockURLProtocol.requests.filter { $0.url?.host == "itunes.apple.com" }.count,
            1
        )
    }

    func testPinkFloydImmersionFolderPreservesBluRayFiveOneEditionAndArtwork() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let albumFolder = fixture.directory.appendingPathComponent(
            "Pink Floyd - The Dark Side Of The Moon (1973) [SPECIAL] {Immersion Blu-Ray 2011 5.1 2003 Mix 16.44 FLAC}",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: albumFolder.appendingPathComponent("Folder.jpg"))
        let audioURL = albumFolder.appendingPathComponent("01 - Speak To Me.flac")
        try Data([1, 2, 3]).write(to: audioURL)
        let track = Self.track(
            url: audioURL,
            title: nil,
            artist: nil,
            album: nil,
            channelCount: 6,
            channelSummary: "FL, FR, FC, LFE, SL, SR",
            layoutName: "5.1"
        )
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let enricher = LocalMusicMetadataEnricher(
            library: library,
            lookupClient: FakeLookupClient(results: [:]),
            lookupDelayNanoseconds: 0
        )

        let overlays = await enricher.enrich(tracks: [track], existingOverlays: [:], alreadyScannedTrackIDs: [], forceRescan: true).overlays

        let overlay = try XCTUnwrap(overlays[track.id])
        XCTAssertEqual(overlay.title, "Speak To Me")
        XCTAssertEqual(overlay.artist, "Pink Floyd")
        let album = try XCTUnwrap(overlay.album)
        XCTAssertTrue(album.contains("The Dark Side Of The Moon"))
        XCTAssertTrue(album.contains("Immersion"))
        XCTAssertTrue(album.contains("Blu-Ray"))
        XCTAssertTrue(album.contains("5.1"))
        XCTAssertTrue(album.contains("2003 Mix"))
        XCTAssertFalse(album.contains("16.44"))
        XCTAssertEqual(overlay.trackNumber, 1)
        XCTAssertNotNil(overlay.artworkPath)
    }

    func testLocalSidecarAndFolderArtworkSurviveOnlineLookupFailure() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let albumFolder = fixture.directory.appendingPathComponent("Artist - Album {Atmos 7.1.4 Blu-Ray}", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: albumFolder.appendingPathComponent("Cover.jpg"))
        let audioURL = albumFolder.appendingPathComponent("01 - First Track.flac")
        try Data([1, 2, 3]).write(to: audioURL)
        let track = Self.track(
            url: audioURL,
            title: nil,
            artist: nil,
            album: nil,
            channelCount: 12,
            channelSummary: "7.1.4",
            layoutName: "Atmos 7.1.4"
        )
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let enricher = LocalMusicMetadataEnricher(
            library: library,
            lookupClient: ThrowingLookupClient(),
            lookupDelayNanoseconds: 0
        )

        let overlays = await enricher.enrich(tracks: [track], existingOverlays: [:], alreadyScannedTrackIDs: [], forceRescan: true).overlays

        let overlay = try XCTUnwrap(overlays[track.id])
        XCTAssertEqual(overlay.title, "First Track")
        XCTAssertEqual(overlay.artist, "Artist")
        XCTAssertEqual(overlay.album, "Album - Atmos 7.1.4 Blu-Ray")
        XCTAssertEqual(overlay.trackNumber, 1)
        XCTAssertNotNil(overlay.artworkPath)
    }

    func testManifestSidecarStoresTrackNumber() async throws {
        let overlay = try await Self.sidecarOverlay(
            fileName: "track.flac",
            sidecarName: "manifest.json",
            sidecarContents: """
            {
              "album": "Album",
              "album_artist": "Artist",
              "tracks": [
                { "track": 7, "title": "Sidecar Track" }
              ]
            }
            """
        )

        XCTAssertEqual(overlay.title, "Sidecar Track")
        XCTAssertEqual(overlay.trackNumber, 7)
    }

    func testRipReportSidecarStoresTrackNumber() async throws {
        let overlay = try await Self.sidecarOverlay(
            fileName: "track.flac",
            sidecarName: "rip-report.json",
            sidecarContents: """
            {
              "metadata": {
                "album": "Album",
                "album_artist": "Artist"
              },
              "tracks": [
                {
                  "track": 7,
                  "title": "Rip Track",
                  "output": "track.flac"
                }
              ]
            }
            """
        )

        XCTAssertEqual(overlay.title, "Rip Track")
        XCTAssertEqual(overlay.trackNumber, 7)
    }

    func testCueSidecarStoresTrackNumber() async throws {
        let overlay = try await Self.sidecarOverlay(
            fileName: "track.flac",
            sidecarName: "album.cue",
            sidecarContents: """
            PERFORMER "Artist"
            TITLE "Album"
            FILE "track.flac" WAVE
              TRACK 07 AUDIO
                TITLE "Cue Track"
            """
        )

        XCTAssertEqual(overlay.title, "Cue Track")
        XCTAssertEqual(overlay.trackNumber, 7)
    }

    func testTipperDVDAudioSidecarsPreserveDVDAudioFiveOneEdition() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let albumFolder = fixture.directory.appendingPathComponent("Tipper - Surrounded - 5.1", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        try """
        {
          "album": "Surrounded",
          "album_artist": "Tipper",
          "date": "2004",
          "tracks": [
            { "track": 1, "title": "Middle of Nowhere" }
          ]
        }
        """.data(using: .utf8)!.write(to: albumFolder.appendingPathComponent("manifest.json"))
        try """
        PERFORMER "Tipper"
        TITLE "Surrounded"
        REM DATE 2004
        FILE "01 Middle of Nowhere.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Middle of Nowhere"
            PERFORMER "Tipper"
        """.data(using: .utf8)!.write(to: albumFolder.appendingPathComponent("Surrounded.cue"))
        try """
        {
          "app": "dvda-flac-ripper",
          "metadata": {
            "album": "Surrounded",
            "album_artist": "Tipper",
            "date": "2004"
          },
          "tracks": [
            {
              "track": 1,
              "title": "Middle of Nowhere",
              "output": "01 Middle of Nowhere.flac",
              "ffprobe": {
                "streams": [
                  { "channel_layout": "5.1" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!.write(to: albumFolder.appendingPathComponent("rip-report.json"))
        let audioURL = albumFolder.appendingPathComponent("01 Middle of Nowhere.flac")
        try Data([1, 2, 3]).write(to: audioURL)
        let track = Self.track(
            url: audioURL,
            title: nil,
            artist: nil,
            album: nil,
            channelCount: 6,
            channelSummary: "FL, FR, FC, LFE, SL, SR",
            layoutName: "5.1"
        )
        let online = FakeLookupClient(results: [
            track.id: LocalMusicMetadataLookupResult(
                overlay: LocalMusicMetadataOverlay(
                    title: "Generic Stereo Title",
                    artist: "Tipper",
                    album: "Surrounded",
                    sourceName: "GenericOnline",
                    sourceIdentifier: "stereo-surrounded",
                    confidence: 0.98
                ),
                artworkData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                artworkSourceURL: URL(string: "https://example.invalid/tipper.jpg")
            )
        ])
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let enricher = LocalMusicMetadataEnricher(
            library: library,
            lookupClient: online,
            lookupDelayNanoseconds: 0
        )

        let overlays = await enricher.enrich(tracks: [track], existingOverlays: [:], alreadyScannedTrackIDs: [], forceRescan: true).overlays

        let overlay = try XCTUnwrap(overlays[track.id])
        XCTAssertEqual(overlay.title, "Middle of Nowhere")
        XCTAssertEqual(overlay.artist, "Tipper")
        XCTAssertEqual(overlay.album, "Surrounded - DVD-Audio 5.1")
        XCTAssertEqual(overlay.trackNumber, 1)
        XCTAssertNotNil(overlay.artworkPath)
        XCTAssertTrue(overlay.sourceName.contains("LocalSidecar"))
    }

    func testSpecialEditionOverlayKeepsLookingForMissingArtwork() async throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("01 - Time.flac")
        try Data([1, 2, 3]).write(to: audioURL)
        let track = Self.track(url: audioURL, title: nil, artist: nil, album: nil)
        let existing = LocalMusicMetadataOverlay(
            title: "Time",
            artist: "Pink Floyd",
            album: "The Dark Side Of The Moon - Immersion Blu-Ray 5.1",
            sourceName: "LocalFolder",
            confidence: 0.90
        )
        let lookup = FakeLookupClient(results: [
            track.id: LocalMusicMetadataLookupResult(
                overlay: LocalMusicMetadataOverlay(
                    album: "The Dark Side Of The Moon",
                    sourceName: "GenericOnline",
                    sourceIdentifier: "plain-stereo",
                    confidence: 0.96
                ),
                artworkData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                artworkSourceURL: URL(string: "https://example.invalid/dsotm.jpg")
            )
        ])
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let enricher = LocalMusicMetadataEnricher(
            library: library,
            lookupClient: lookup,
            lookupDelayNanoseconds: 0
        )

        let overlays = await enricher.enrich(tracks: [track], existingOverlays: [track.id: existing], alreadyScannedTrackIDs: [], forceRescan: true).overlays

        let overlay = try XCTUnwrap(overlays[track.id])
        XCTAssertEqual(overlay.title, "Time")
        XCTAssertEqual(overlay.artist, "Pink Floyd")
        XCTAssertEqual(overlay.album, "The Dark Side Of The Moon - Immersion Blu-Ray 5.1")
        XCTAssertNotNil(overlay.artworkPath)
        XCTAssertEqual(lookup.lookupCount, 1)
    }

    func testFolderEditionTokensAreNotTruncatedFromDisplayAlbum() {
        var atmos = LocalMusicAlbumEditionContext(folderName: "Artist - Album {Atmos 7.1.4 50th Anniversary Blu-Ray}")
        atmos.finalize()
        XCTAssertEqual(atmos.displayAlbum, "Album - Atmos 7.1.4 50th Anniversary Blu-Ray")

        var auro = LocalMusicAlbumEditionContext(folderName: "Artist - Album {Auro 9.1 2003 Mix}")
        auro.finalize()
        XCTAssertEqual(auro.displayAlbum, "Album - Auro 9.1 2003 Mix")

        var quad = LocalMusicAlbumEditionContext(folderName: "Artist - Album - Quad")
        quad.finalize()
        XCTAssertEqual(quad.displayAlbum, "Album - Quad")
    }

    private static func track(
        url: URL,
        title: String?,
        artist: String?,
        album: String?,
        channelCount: Int = 2,
        channelSummary: String = "FL, FR",
        layoutName: String = "Stereo"
    ) -> LocalMusicTrack {
        LocalMusicTrack(
            path: url.path,
            rootPath: url.deletingLastPathComponent().path,
            fileName: url.lastPathComponent,
            title: title,
            artist: artist,
            album: album,
            trackNumber: nil,
            discNumber: nil,
            channelCount: channelCount,
            channelSummary: channelSummary,
            layoutName: layoutName,
            sampleRate: 48_000,
            duration: 1,
            artworkPath: nil
        )
    }

    private static func overlay(title: String, trackNumber: Int) -> LocalMusicMetadataOverlay {
        LocalMusicMetadataOverlay(
            title: title,
            artist: "Pink Floyd",
            album: "The Dark Side Of The Moon",
            trackNumber: trackNumber,
            sourceName: "Test",
            confidence: 0.98
        )
    }

    private static func sidecarOverlay(
        fileName: String,
        sidecarName: String,
        sidecarContents: String
    ) async throws -> LocalMusicMetadataOverlay {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }

        let albumFolder = fixture.directory.appendingPathComponent("Artist - Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumFolder, withIntermediateDirectories: true)
        try sidecarContents.data(using: .utf8)!.write(to: albumFolder.appendingPathComponent(sidecarName))
        let audioURL = albumFolder.appendingPathComponent(fileName)
        try Data([1]).write(to: audioURL)
        let track = Self.track(url: audioURL, title: nil, artist: nil, album: nil)
        let enricher = LocalMusicMetadataEnricher(
            library: LocalMusicLibrary(supportURL: fixture.supportDirectory),
            lookupClient: FakeLookupClient(results: [:]),
            lookupDelayNanoseconds: 0
        )

        let overlays = await enricher.enrich(tracks: [track], existingOverlays: [:], alreadyScannedTrackIDs: [], forceRescan: true).overlays
        return try XCTUnwrap(overlays[track.id])
    }

    private static let stubLoader: @Sendable (URL) throws -> LoadedAudioFile = { _ in
        throw NSError(domain: "LocalMusicMetadataEnrichmentTests", code: 1)
    }
}

private final class CountingMetadataEnricher: LocalMusicMetadataEnriching, @unchecked Sendable {
    private(set) var callCount = 0

    func enrich(
        tracks: [LocalMusicTrack],
        existingOverlays: [String: LocalMusicMetadataOverlay],
        alreadyScannedTrackIDs: Set<String>,
        forceRescan: Bool
    ) async -> (overlays: [String: LocalMusicMetadataOverlay], scannedTrackIDs: Set<String>) {
        callCount += 1
        return (existingOverlays, alreadyScannedTrackIDs)
    }
}

private final class FakeLookupClient: LocalMusicMetadataLookupClient, @unchecked Sendable {
    private let results: [String: LocalMusicMetadataLookupResult]
    private(set) var lookupCount = 0

    init(results: [String: LocalMusicMetadataLookupResult]) {
        self.results = results
    }

    func lookup(track: LocalMusicTrack) async throws -> LocalMusicMetadataLookupResult? {
        lookupCount += 1
        return results[track.id]
    }
}

private struct ThrowingLookupClient: LocalMusicMetadataLookupClient {
    func lookup(track: LocalMusicTrack) async throws -> LocalMusicMetadataLookupResult? {
        throw URLError(.notConnectedToInternet)
    }
}

private final class AppleSearchMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    static var handler: Handler?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MetadataFixture {
    let directory: URL
    let supportDirectory: URL
    let artworkURL: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbisonic-metadata-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("Music", isDirectory: true)
        supportDirectory = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        artworkURL = supportDirectory.appendingPathComponent("cover.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: artworkURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: supportDirectory.deletingLastPathComponent())
    }
}
