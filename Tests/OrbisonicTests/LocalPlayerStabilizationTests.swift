import AVFoundation
import Foundation
import XCTest
@testable import Orbisonic

final class LocalPlayerStabilizationTests: XCTestCase {
    func testMultiNodeLocalResumeUsesSharedHostTimeInsteadOfSequentialPlayCalls() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Orbisonic/OrbisonicEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("playerNodes.forEach { $0.play() }"))
        XCTAssertTrue(source.contains("playerNodes.forEach { $0.play(at: startTime) }"))
    }

    func testLocalMonitorPlaybackUsesSingleReferenceStereoPlayer() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Orbisonic/OrbisonicEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("playerNodes = loadedFile.layout.channels.map { _ in AVAudioPlayerNode() }"))
        XCTAssertFalse(source.contains("let sourceBuffer = loadedFile.monoBuffers[index]"))
        XCTAssertTrue(source.contains("playerNodes = [player]"))
        XCTAssertTrue(source.contains("Self.slice(buffer: loadedFile.monitorBuffer"))
        XCTAssertTrue(source.contains("reference-stereo-monitor"))
    }

    func testLoadedLocalFilePreparesReferenceStereoMonitorBuffer() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("reference-monitor.wav")
        try Self.writeSilentAudioFile(to: audioURL, frames: 512)

        let loaded = try AudioFileLoader().load(url: audioURL)

        XCTAssertEqual(loaded.monitorFormat.channelCount, 2)
        XCTAssertEqual(loaded.monitorBuffer.format.channelCount, 2)
        XCTAssertEqual(loaded.monitorBuffer.frameLength, AVAudioFrameCount(loaded.frameCount))
        XCTAssertEqual(loaded.monoBuffers.count, loaded.layout.channelCount)
    }

    func testScanExcludesMissingM3UEntries() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("playable.wav")
        try Self.writeSilentAudioFile(to: audioURL)
        let missingURL = fixture.directory.appendingPathComponent("missing.flac")
        let playlistURL = fixture.directory.appendingPathComponent("session.m3u")
        try [
            "#EXTM3U",
            audioURL.path,
            missingURL.path
        ].joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let result = library.scan(settings: LocalMusicSettings(
            watchFolderPaths: [],
            m3uPlaylistPaths: [playlistURL.path],
            scansSubfolders: true,
            importsM3UPlaylists: true,
            extractsAlbumArt: false
        ))

        XCTAssertEqual(result.tracks.map(\.path), [audioURL.path])
        XCTAssertEqual(result.playlists.count, 1)
        XCTAssertEqual(result.playlists[0].trackPaths, [audioURL.path])
        XCTAssertEqual(result.skippedMissingFiles, 1)
    }

    func testLoadPrunesPersistedMissingTracksAndPlaylistEntries() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let existingURL = fixture.directory.appendingPathComponent("existing.wav")
        try Data().write(to: existingURL)
        let missingURL = fixture.directory.appendingPathComponent("missing.wav")

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [
                Self.track(url: existingURL),
                Self.track(url: missingURL)
            ],
            playlists: [
                LocalMusicPlaylist(
                    name: "Mixed",
                    path: fixture.directory.appendingPathComponent("mixed.m3u").path,
                    trackPaths: [existingURL.path, missingURL.path]
                ),
                LocalMusicPlaylist(
                    name: "Missing",
                    path: fixture.directory.appendingPathComponent("missing.m3u").path,
                    trackPaths: [missingURL.path]
                )
            ]
        ))

        let loaded = library.load()

        XCTAssertEqual(loaded.tracks.map(\.path), [existingURL.path])
        XCTAssertEqual(loaded.playlists.map(\.name), ["Mixed"])
        XCTAssertEqual(loaded.playlists[0].trackPaths, [existingURL.path])
    }

    func testAppManagedPlaylistMutationsPersistM3U() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        let secondURL = fixture.directory.appendingPathComponent("second.wav")
        try Self.writeSilentAudioFile(to: firstURL)
        try Self.writeSilentAudioFile(to: secondURL)

        let first = Self.track(url: firstURL)
        let second = Self.track(url: secondURL)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)

        let playlist = try library.createPlaylist(name: "Favorites", tracks: [first])
        XCTAssertTrue(library.isEditablePlaylist(playlist))

        let appended = try library.appendTrack(second, to: playlist, knownTracks: [first, second])
        XCTAssertEqual(appended.trackPaths, [first.path, second.path])
        XCTAssertThrowsError(try library.appendTrack(first, to: appended, knownTracks: [first, second])) { error in
            XCTAssertEqual(error as? LocalMusicPlaylistMutationError, .duplicateTrack)
        }

        let reordered = try library.updateEditablePlaylist(
            appended,
            trackPaths: [second.path, first.path],
            knownTracks: [first, second]
        )
        XCTAssertEqual(reordered.trackPaths, [second.path, first.path])

        let removed = try library.updateEditablePlaylist(
            reordered,
            trackPaths: [first.path],
            knownTracks: [first, second]
        )
        XCTAssertEqual(removed.trackPaths, [first.path])

        let renamed = try library.renameEditablePlaylist(removed, to: "Renamed")
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))

        let contents = try String(contentsOf: URL(fileURLWithPath: renamed.path), encoding: .utf8)
        XCTAssertTrue(contents.contains("#EXTM3U"))
        XCTAssertTrue(contents.contains(first.path))
        XCTAssertFalse(contents.contains(second.path))
    }

    func testImportedPlaylistIsReadOnlyAndRenameConflictsAreBlocked() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("track.wav")
        try Self.writeSilentAudioFile(to: audioURL)
        let track = Self.track(url: audioURL)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)

        let importedURL = fixture.directory.appendingPathComponent("imported.m3u")
        try ["#EXTM3U", track.path].joined(separator: "\n").write(to: importedURL, atomically: true, encoding: .utf8)
        let imported = LocalMusicPlaylist(name: "Imported", path: importedURL.path, trackPaths: [track.path])

        XCTAssertFalse(library.isEditablePlaylist(imported))
        XCTAssertThrowsError(try library.appendTrack(track, to: imported, knownTracks: [track])) { error in
            XCTAssertEqual(error as? LocalMusicPlaylistMutationError, .readOnly)
        }

        let first = try library.createPlaylist(name: "Existing", tracks: [track])
        let second = try library.createPlaylist(name: "Other", tracks: [track])
        XCTAssertThrowsError(try library.renameEditablePlaylist(second, to: first.name)) { error in
            XCTAssertEqual(error as? LocalMusicPlaylistMutationError, .nameConflict(first.name))
        }
    }

    @MainActor
    func testViewModelAddsTracksToNewAndExistingPlaylists() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        let secondURL = fixture.directory.appendingPathComponent("second.wav")
        try Self.writeSilentAudioFile(to: firstURL)
        try Self.writeSilentAudioFile(to: secondURL)

        let first = Self.track(url: firstURL)
        let second = Self.track(url: secondURL)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [first, second],
            playlists: []
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library
        )

        model.addLocalMusicTrackToNewPlaylist(first, named: "Road")
        model.addLocalMusicTrackToNewPlaylist(second, named: "Road")

        XCTAssertEqual(model.localMusicPlaylists.map(\.name), ["Road"])
        XCTAssertEqual(model.selectedLocalMusicPlaylist?.trackPaths, [first.path, second.path])
        XCTAssertEqual(model.localMusicSettings.m3uPlaylistPaths.count, 1)

        let playlist = try XCTUnwrap(model.selectedLocalMusicPlaylist)
        model.addLocalMusicTrackToPlaylist(first, playlist)

        XCTAssertEqual(model.selectedLocalMusicPlaylist?.trackPaths, [first.path, second.path])
        XCTAssertTrue(model.statusMessage.localizedCaseInsensitiveContains("already"))
    }

    @MainActor
    func testViewModelReordersRemovesAndRenamesEditablePlaylistTracks() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        let secondURL = fixture.directory.appendingPathComponent("second.wav")
        try Self.writeSilentAudioFile(to: firstURL)
        try Self.writeSilentAudioFile(to: secondURL)

        let first = Self.track(url: firstURL)
        let second = Self.track(url: secondURL)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let playlist = try library.createPlaylist(name: "Editable", tracks: [first, second])
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(m3uPlaylistPaths: [playlist.path]),
            tracks: [first, second],
            playlists: [playlist]
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library
        )

        let loaded = try XCTUnwrap(model.localMusicPlaylists.first)
        model.moveLocalMusicPlaylistTrackUp(loaded, index: 1)
        XCTAssertEqual(model.selectedLocalMusicPlaylist?.trackPaths, [second.path, first.path])

        let reordered = try XCTUnwrap(model.selectedLocalMusicPlaylist)
        model.removeLocalMusicPlaylistTrack(reordered, index: 0)
        XCTAssertEqual(model.selectedLocalMusicPlaylist?.trackPaths, [first.path])

        let edited = try XCTUnwrap(model.selectedLocalMusicPlaylist)
        let oldPath = edited.path
        model.renameLocalMusicPlaylist(edited, named: "Renamed Editable")

        XCTAssertEqual(model.selectedLocalMusicPlaylist?.name, "Renamed Editable")
        XCTAssertNotEqual(model.selectedLocalMusicPlaylist?.path, oldPath)
        XCTAssertEqual(model.localMusicSettings.m3uPlaylistPaths, [model.selectedLocalMusicPlaylist?.path].compactMap { $0 })
    }

    @MainActor
    func testViewModelKeepsLocalMusicAlbumArtExtractionAlwaysOn() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(importsM3UPlaylists: false, extractsAlbumArt: false),
            tracks: [],
            playlists: []
        ))

        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library
        )

        XCTAssertTrue(model.localMusicSettings.extractsAlbumArt)
        XCTAssertTrue(model.localMusicSettings.importsM3UPlaylists)

        model.setLocalMusicExtractsAlbumArt(false)
        model.setLocalMusicImportsM3UPlaylists(false)

        XCTAssertTrue(model.localMusicSettings.extractsAlbumArt)
        XCTAssertTrue(model.localMusicSettings.importsM3UPlaylists)
        XCTAssertTrue(library.load().settings.extractsAlbumArt)
        XCTAssertTrue(library.load().settings.importsM3UPlaylists)
    }

    @MainActor
    func testAlbumSortFallsBackToFolderBeforeTitleWhenAlbumIsMissing() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let firstFolderURL = fixture.directory.appendingPathComponent("A Folder", isDirectory: true)
        let secondFolderURL = fixture.directory.appendingPathComponent("Z Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolderURL, withIntermediateDirectories: true)

        let titleFirstURL = secondFolderURL.appendingPathComponent("alpha-title.wav")
        let folderFirstURL = firstFolderURL.appendingPathComponent("zulu-title.wav")
        try Data().write(to: titleFirstURL)
        try Data().write(to: folderFirstURL)

        let titleFirst = Self.track(
            url: titleFirstURL,
            rootURL: fixture.directory,
            title: "Alpha Title",
            artist: "Artist",
            album: nil
        )
        let folderFirst = Self.track(
            url: folderFirstURL,
            rootURL: fixture.directory,
            title: "Zulu Title",
            artist: "Artist",
            album: nil
        )
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(settings: LocalMusicSettings(), tracks: [titleFirst, folderFirst], playlists: []))

        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library,
            preloadFirstLocalMusicTrack: false
        )
        model.localMusicSortMode = .album

        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayTitle), ["Zulu Title", "Alpha Title"])
    }

    @MainActor
    func testAlbumSortKeepsAlbumTagsAndExistingSecondaryFallbacks() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let folderURL = fixture.directory.appendingPathComponent("Shared Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let albumZURL = fixture.directory.appendingPathComponent("album-z.wav")
        let albumAURL = fixture.directory.appendingPathComponent("album-a.wav")
        let missingArtistZURL = folderURL.appendingPathComponent("artist-z.wav")
        let missingArtistAURL = folderURL.appendingPathComponent("artist-a.wav")
        try Data().write(to: albumZURL)
        try Data().write(to: albumAURL)
        try Data().write(to: missingArtistZURL)
        try Data().write(to: missingArtistAURL)

        let albumZ = Self.track(url: albumZURL, rootURL: fixture.directory, title: "Album Z Track", artist: "Artist", album: "Z Album")
        let albumA = Self.track(url: albumAURL, rootURL: fixture.directory, title: "Album A Track", artist: "Artist", album: "A Album")
        let missingArtistZ = Self.track(url: missingArtistZURL, rootURL: fixture.directory, title: "Missing Z Artist Track", artist: "Zulu Artist", album: nil)
        let missingArtistA = Self.track(url: missingArtistAURL, rootURL: fixture.directory, title: "Missing A Artist Track", artist: "Alpha Artist", album: nil)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [albumZ, albumA, missingArtistZ, missingArtistA],
            playlists: []
        ))

        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library,
            preloadFirstLocalMusicTrack: false
        )
        model.localMusicSortMode = .album

        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayTitle), [
            "Album A Track",
            "Missing A Artist Track",
            "Missing Z Artist Track",
            "Album Z Track"
        ])

        model.localMusicSortMode = .name
        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayTitle), [
            "Album A Track",
            "Album Z Track",
            "Missing A Artist Track",
            "Missing Z Artist Track"
        ])

        model.localMusicSortMode = .artist
        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayArtist), [
            "Alpha Artist",
            "Artist",
            "Artist",
            "Zulu Artist"
        ])
    }

    func testMatroskaScanUsesAttachedCoverInsteadOfFirstVideoFrame() throws {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL(),
              FFmpegToolLocator.ffprobeURL() != nil
        else {
            throw XCTSkip("ffmpeg/ffprobe unavailable")
        }

        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let matroskaURL = fixture.directory.appendingPathComponent("iaa-style-cover.mkv")
        try Self.writeMatroskaFixture(
            to: matroskaURL,
            ffmpegURL: ffmpegURL,
            includesNormalVideo: true,
            includesAttachedCover: true
        )

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let result = library.scan(settings: LocalMusicSettings(
            watchFolderPaths: [fixture.directory.path],
            extractsAlbumArt: true
        ))

        let track = try XCTUnwrap(result.tracks.first { $0.fileName == matroskaURL.lastPathComponent })
        let artworkPath = try XCTUnwrap(track.artworkPath)
        XCTAssertTrue(artworkPath.hasSuffix("-cover.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkPath))

        let artworkData = try Data(contentsOf: URL(fileURLWithPath: artworkPath))
        XCTAssertTrue(artworkData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testMatroskaScanDoesNotCreateArtworkFromOrdinaryVideoStream() throws {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL(),
              FFmpegToolLocator.ffprobeURL() != nil
        else {
            throw XCTSkip("ffmpeg/ffprobe unavailable")
        }

        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let matroskaURL = fixture.directory.appendingPathComponent("renderer-display-only.mkv")
        try Self.writeMatroskaFixture(
            to: matroskaURL,
            ffmpegURL: ffmpegURL,
            includesNormalVideo: true,
            includesAttachedCover: false
        )

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let result = library.scan(settings: LocalMusicSettings(
            watchFolderPaths: [fixture.directory.path],
            extractsAlbumArt: true
        ))

        let track = try XCTUnwrap(result.tracks.first { $0.fileName == matroskaURL.lastPathComponent })
        XCTAssertNil(track.artworkPath)
    }

    func testLoadRepairsLegacyMatroskaArtworkCachePath() throws {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL(),
              FFmpegToolLocator.ffprobeURL() != nil
        else {
            throw XCTSkip("ffmpeg/ffprobe unavailable")
        }

        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let matroskaURL = fixture.directory.appendingPathComponent("legacy-black-cache.mkv")
        try Self.writeMatroskaFixture(
            to: matroskaURL,
            ffmpegURL: ffmpegURL,
            includesNormalVideo: true,
            includesAttachedCover: true
        )

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let legacyArtworkURL = fixture.supportDirectory
            .appendingPathComponent("Album Artwork", isDirectory: true)
            .appendingPathComponent(Self.stableIdentifier(for: matroskaURL.path), isDirectory: false)
            .appendingPathExtension("jpg")
        try FileManager.default.createDirectory(
            at: legacyArtworkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00, 0x01, 0x02]).write(to: legacyArtworkURL)

        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(extractsAlbumArt: true),
            tracks: [
                LocalMusicTrack(
                    path: matroskaURL.path,
                    rootPath: fixture.directory.path,
                    fileName: matroskaURL.lastPathComponent,
                    title: "Legacy Cache",
                    artist: nil,
                    album: nil,
                    channelCount: 2,
                    channelSummary: "FL, FR",
                    layoutName: "Stereo",
                    sampleRate: 48_000,
                    duration: 0.1,
                    artworkPath: legacyArtworkURL.path
                )
            ],
            playlists: []
        ))

        let loaded = library.load()
        let repairedTrack = try XCTUnwrap(loaded.tracks.first)
        let artworkPath = try XCTUnwrap(repairedTrack.artworkPath)
        XCTAssertNotEqual(artworkPath, legacyArtworkURL.path)
        XCTAssertTrue(artworkPath.hasSuffix("-cover.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkPath))
    }

    @MainActor
    func testAppleSpatialHeadphonesPreferenceCannotActivateModule() throws {
        UserDefaults.standard.set(true, forKey: "Orbisonic.appleSpatialHeadphonesEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "Orbisonic.appleSpatialHeadphonesEnabled") }

        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: LocalMusicLibrary(supportURL: fixture.supportDirectory)
        )

        XCTAssertFalse(model.appleSpatialHeadphonesEnabled)
        XCTAssertEqual(model.appleSpatialHeadphoneMonitorStatus.mode, .referenceStereo)

        model.setAppleSpatialHeadphonesEnabled(true)

        XCTAssertFalse(model.appleSpatialHeadphonesEnabled)
        XCTAssertEqual(model.appleSpatialHeadphoneMonitorStatus.mode, .referenceStereo)
        XCTAssertTrue(model.statusMessage.contains("disabled in this build"))
    }

    @MainActor
    func testViewModelReordersAndDeletesPlaylists() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let trackURL = fixture.directory.appendingPathComponent("track.wav")
        try Self.writeSilentAudioFile(to: trackURL)
        let track = Self.track(url: trackURL)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        let first = try library.createPlaylist(name: "First", tracks: [track])
        let second = try library.createPlaylist(name: "Second", tracks: [track])
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(m3uPlaylistPaths: [first.path, second.path]),
            tracks: [track],
            playlists: [first, second]
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library
        )

        model.moveLocalMusicPlaylistDown(first)

        XCTAssertEqual(model.localMusicPlaylists.map(\.name), ["Second", "First"])
        XCTAssertEqual(model.localMusicSettings.m3uPlaylistPaths, [second.path, first.path])

        model.deleteLocalMusicPlaylist(first)

        XCTAssertEqual(model.localMusicPlaylists.map(\.name), ["Second"])
        XCTAssertEqual(model.localMusicSettings.m3uPlaylistPaths, [second.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testViewModelRemovesImportedPlaylistWithoutDeletingExternalFile() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let trackURL = fixture.directory.appendingPathComponent("track.wav")
        try Self.writeSilentAudioFile(to: trackURL)
        let track = Self.track(url: trackURL)
        let importedURL = fixture.directory.appendingPathComponent("imported.m3u")
        try ["#EXTM3U", track.path].joined(separator: "\n").write(to: importedURL, atomically: true, encoding: .utf8)
        let imported = LocalMusicPlaylist(name: "Imported", path: importedURL.path, trackPaths: [track.path])
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(m3uPlaylistPaths: [imported.path]),
            tracks: [track],
            playlists: [imported]
        ))
        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library
        )

        model.deleteLocalMusicPlaylist(imported)

        XCTAssertTrue(model.localMusicPlaylists.isEmpty)
        XCTAssertTrue(model.localMusicSettings.m3uPlaylistPaths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
    }

    @MainActor
    func testStartupPreloadsFirstLibraryTrackPaused() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let firstURL = fixture.directory.appendingPathComponent("01-first.wav")
        let secondURL = fixture.directory.appendingPathComponent("02-second.wav")
        try Self.writeSilentAudioFile(to: firstURL)
        try Self.writeSilentAudioFile(to: secondURL)

        let first = Self.track(url: firstURL)
        let second = Self.track(url: secondURL)
        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [second, first],
            playlists: []
        ))

        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            localMusicLibrary: library,
            preloadFirstLocalMusicTrack: true
        )
        try await Self.waitForCurrentFile(model, path: first.path)

        XCTAssertEqual(model.sessionQueue.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.currentQueueTrack?.id, first.id)
        XCTAssertFalse(model.isPlaying)
    }

    func testGeneratedFLACCanUseFFmpegFallbackDecodePath() throws {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL() else {
            throw XCTSkip("ffmpeg unavailable")
        }

        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let flacURL = fixture.directory.appendingPathComponent("surround.flac")
        let result = try MatroskaAudioProbe.runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-v", "error",
                "-y",
                "-f", "lavfi",
                "-i", "anullsrc=channel_layout=5.1:sample_rate=96000",
                "-t", "0.1",
                "-c:a", "flac",
                flacURL.path
            ]
        )

        guard result.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg FLAC fixture generation failed: \(result.errorText)")
        }

        let loaded = try AudioFileLoader().load(url: flacURL, forceFFmpegFLACFallback: true)

        XCTAssertEqual(loaded.metadata.codecName, "FLAC")
        XCTAssertEqual(loaded.metadata.channelCount, 6)
        XCTAssertEqual(loaded.metadata.sampleRate, 96_000, accuracy: 0.5)
        XCTAssertEqual(loaded.monoBuffers.count, 6)
    }

    func testPreparedPCMEstimateUsesFloat32Samples() {
        XCTAssertEqual(
            PreparedPCMPolicy.estimatedDecodedPCMBytes(
                durationSeconds: 2,
                sampleRate: 48_000,
                channelCount: 6
            ),
            2 * 48_000 * 6 * MemoryLayout<Float>.size
        )
        XCTAssertEqual(
            PreparedPCMPolicy.estimatedDecodedPCMBytes(
                frameCount: 96_000,
                channelCount: 2
            ),
            96_000 * 2 * MemoryLayout<Float>.size
        )
    }

    func testExceedsFullPrepareBudgetOnlyRefusesConcreteOverBudget() {
        let cap = 100
        XCTAssertFalse(
            PreparedPCMPolicy.exceedsFullPrepareBudget(estimatedDecodedBytes: nil, maxBytes: cap),
            "Unknown estimate must not be refused"
        )
        XCTAssertFalse(
            PreparedPCMPolicy.exceedsFullPrepareBudget(estimatedDecodedBytes: cap - 1, maxBytes: cap),
            "Under budget must not be refused"
        )
        XCTAssertFalse(
            PreparedPCMPolicy.exceedsFullPrepareBudget(estimatedDecodedBytes: cap, maxBytes: cap),
            "Exactly at budget must not be refused"
        )
        XCTAssertTrue(
            PreparedPCMPolicy.exceedsFullPrepareBudget(estimatedDecodedBytes: cap + 1, maxBytes: cap),
            "Over budget must be refused"
        )
    }

    func testDefaultMaxFullPreparedPCMBytesScalesWithInstalledRAM() {
        struct StubMemory: SystemMemoryProviding {
            let total: Int
            func snapshot() -> SystemMemorySnapshot {
                SystemMemorySnapshot(availableBytes: total, totalBytes: total)
            }
        }
        let eightGiB = 8 * 1_024 * 1_024 * 1_024
        XCTAssertEqual(
            PreparedPCMPolicy.defaultMaxFullPreparedPCMBytes(provider: StubMemory(total: eightGiB)),
            Int(Double(eightGiB) * PreparedPCMPolicy.fullPreparePhysicalMemoryFraction)
        )
        XCTAssertEqual(
            PreparedPCMPolicy.defaultMaxFullPreparedPCMBytes(provider: StubMemory(total: 0)),
            PreparedPCMPolicy.unknownMemoryFullPreparedPCMBytes,
            "Unknown reading must fall back, not refuse everything"
        )
        XCTAssertEqual(
            PreparedPCMPolicy.defaultMaxFullPreparedPCMBytes(provider: StubMemory(total: 100 * 1_024 * 1_024)),
            PreparedPCMPolicy.minFullPreparedPCMBytes,
            "Tiny machine still honors the floor"
        )
    }

    func testLoadRefusesFileExceedingInjectedPrepareBudget() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("oversized.wav")
        try Self.writeSilentAudioFile(to: audioURL, frames: 48_000)
        let loader = AudioFileLoader(maxFullPreparedPCMBytes: 1)

        XCTAssertThrowsError(try loader.load(url: audioURL)) { error in
            guard case AudioFileLoaderError.fileTooLargeToPrepare = error else {
                XCTFail("Expected fileTooLargeToPrepare, got \(error)")
                return
            }
        }
    }

    func testLoadAllowsFileWithinDefaultPrepareBudget() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("within-budget.wav")
        try Self.writeSilentAudioFile(to: audioURL, frames: 48_000)

        XCTAssertNoThrow(try AudioFileLoader().load(url: audioURL))
    }

    @MainActor
    func testAdjacentFullPCMPreloadIsDisabledByDefault() {
        let model = OrbisonicViewModel(localAudioLoader: Self.delayedLoader(delays: [:]))

        XCTAssertFalse(OrbisonicViewModel.adjacentFullLocalPCMPreloadEnabledByDefaultForTesting)
        XCTAssertFalse(model.adjacentFullLocalPCMPreloadEnabledForTesting)
    }

    @MainActor
    func testPreparedCacheRejectsEntriesAboveByteCap() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("cache-budget.wav")
        try Self.writeSilentAudioFile(to: audioURL, frames: 48_000)
        let loaded = try AudioFileLoader().load(url: audioURL)
        let model = OrbisonicViewModel(
            localAudioLoader: Self.delayedLoader(delays: [:]),
            preparedCacheByteLimit: max(loaded.preparedPCMByteCount - 1, 1)
        )

        let reason = model.cachePreparedLocalFileForTesting(loaded)

        XCTAssertEqual(reason, "prepared PCM exceeds cache budget")
        XCTAssertFalse(model.hasPreparedLocalFileForTesting(path: audioURL.path))
    }

    @MainActor
    func testFailedQueueLoadDoesNotCommitSelection() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let missingURL = fixture.directory.appendingPathComponent("missing.wav")
        try Self.writeSilentAudioFile(to: currentURL)

        let model = OrbisonicViewModel()
        let current = Self.track(url: currentURL)
        let missing = Self.track(url: missingURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, missing],
            currentIndex: 0,
            selectedIndex: 0
        )

        XCTAssertTrue(model.playQueueIndexForTesting(1))
        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.selectedSessionQueueIndex, 0)
        XCTAssertEqual(model.currentQueueTrack?.id, current.id)
        XCTAssertEqual(model.pendingSessionQueueIndex, 1)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.selectedSessionQueueIndex, 0)
        XCTAssertEqual(model.currentQueueTrack?.id, current.id)
        XCTAssertNil(model.pendingSessionQueueIndex)
        XCTAssertFalse(model.isLocalFileLoading)
        XCTAssertTrue(model.lastError?.contains("Could not load missing.wav") == true)
    }

    @MainActor
    func testQueueSelectionDoesNotChangeWebNowPlaying() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let selectedURL = fixture.directory.appendingPathComponent("selected.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: selectedURL)

        let model = OrbisonicViewModel()
        let current = Self.track(url: currentURL)
        let selected = Self.track(url: selectedURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, selected],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.selectSessionQueueIndex(1)

        let state = model.webStateForTesting(controlEnabled: true)
        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.selectedSessionQueueIndex, 1)
        XCTAssertEqual(state.player.title, current.displayTitle)
        XCTAssertEqual(state.player.subtitle, current.displaySubtitle)
    }

    @MainActor
    func testFirstPendingQueueLoadUsesPendingPlayerBeforeDecodeFinishes() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        try Self.writeSilentAudioFile(to: firstURL)

        let model = OrbisonicViewModel(localAudioLoader: Self.delayedLoader(delays: ["first.wav": 0.3]))
        let first = Self.track(url: firstURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [first],
            currentIndex: nil,
            selectedIndex: nil
        )

        XCTAssertTrue(model.playQueueIndexForTesting(0))
        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertNil(model.sessionQueueIndex)
        XCTAssertNil(model.currentFileURL)
        XCTAssertEqual(model.pendingSessionQueueIndex, 0)
        XCTAssertTrue(model.isLocalFileLoading)
        XCTAssertEqual(model.visibleLocalPlaybackTrack?.id, first.id)
        XCTAssertEqual(model.visibleLocalSourceMetadata?.fileName, first.fileName)
        XCTAssertEqual(state.player.title, first.displayTitle)
        XCTAssertEqual(state.player.subtitle, first.displaySubtitle)
        XCTAssertEqual(state.player.status, "Loading")

        try await Self.waitForCurrentFile(model, path: first.path)
        XCTAssertEqual(model.visibleLocalPlaybackTrack?.id, first.id)
    }

    @MainActor
    func testPendingQueueLoadKeepsVisiblePlayerOnAudibleTrackBeforeDecodeFinishes() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let model = OrbisonicViewModel(localAudioLoader: Self.delayedLoader(delays: ["next.wav": 0.3]))
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.skipLocalTransport(offset: 1)
        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.currentFileURL?.path, current.path)
        XCTAssertEqual(model.pendingSessionQueueIndex, 1)
        XCTAssertTrue(model.isLocalFileLoading)
        XCTAssertEqual(model.visibleLocalPlaybackTrack?.id, current.id)
        XCTAssertEqual(model.visibleLocalSourceMetadata?.fileName, current.fileName)
        XCTAssertEqual(state.player.title, current.displayTitle)
        XCTAssertEqual(state.player.subtitle, current.displaySubtitle)
        XCTAssertEqual(state.player.status, "Loading")
        XCTAssertFalse(state.player.status.contains(next.displayTitle))
        XCTAssertFalse(state.player.details.contains { $0.title == "Pending" })

        try await Self.waitForCurrentFile(model, path: next.path)
        XCTAssertEqual(model.visibleLocalPlaybackTrack?.id, next.id)
        XCTAssertEqual(model.visibleLocalSourceMetadata?.fileName, next.fileName)
    }

    @MainActor
    func testPlayNowSwitchesFromSpotifyBeforeLoadingLocalTrack() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let localURL = fixture.directory.appendingPathComponent("local.wav")
        try Self.writeSilentAudioFile(to: localURL)

        let model = OrbisonicViewModel()
        let localTrack = Self.track(url: localURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [localTrack],
            currentIndex: nil,
            selectedIndex: nil
        )
        model.setSourceModeForTesting(.spotify)
        model.setSpotifyNowPlayingForTesting(Self.spotifyNowPlaying(title: "Paused Spotify Track", isPlaying: false))

        model.playLocalMusicTrackNow(localTrack)
        try await Self.waitForCurrentFile(model, path: localTrack.path)

        XCTAssertEqual(model.sourceMode, .filePlayback)
        XCTAssertEqual(model.currentFileURL?.path, localTrack.path)
        XCTAssertEqual(model.currentQueueTrack?.id, localTrack.id)
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.webStateForTesting(controlEnabled: true).player.title, localTrack.displayTitle)
        XCTAssertFalse(model.statusMessage.localizedCaseInsensitiveContains("Spotify"))
        XCTAssertFalse(model.lastError?.contains("source mode changed") == true)
    }

    @MainActor
    func testPlayNowSwitchesFromRoonBeforeLoadingLocalTrack() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let localURL = fixture.directory.appendingPathComponent("local.wav")
        try Self.writeSilentAudioFile(to: localURL)

        let model = OrbisonicViewModel()
        let localTrack = Self.track(url: localURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [localTrack],
            currentIndex: nil,
            selectedIndex: nil
        )
        model.setSourceModeForTesting(.roon)

        model.playLocalMusicTrackNow(localTrack)
        try await Self.waitForCurrentFile(model, path: localTrack.path)

        XCTAssertEqual(model.sourceMode, .filePlayback)
        XCTAssertEqual(model.currentFileURL?.path, localTrack.path)
        XCTAssertEqual(model.currentQueueTrack?.id, localTrack.id)
        XCTAssertTrue(model.isPlaying)
        XCTAssertFalse(model.lastError?.contains("source mode changed") == true)
    }

    @MainActor
    func testPauseCancelsPendingQueueLoadWithoutAdvancing() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let model = OrbisonicViewModel(localAudioLoader: Self.delayedLoader(delays: ["next.wav": 0.25]))
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.skipLocalTransport(offset: 1)
        XCTAssertEqual(model.pendingSessionQueueIndex, 1)
        XCTAssertTrue(model.isLocalFileLoading)

        model.pauseLocalTransport()
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.currentFileURL?.path, current.path)
        XCTAssertNil(model.pendingSessionQueueIndex)
        XCTAssertFalse(model.isLocalFileLoading)
        XCTAssertFalse(model.isPlaying)
    }

    @MainActor
    func testStalePlaybackEndedAfterPauseDoesNotAdvanceQueueOrResetPosition() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let model = OrbisonicViewModel()
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        for _ in 0..<3 {
            model.currentTime = max(model.duration - 0.01, 0)
            let pausedTime = model.currentTime
            model.pauseLocalTransport()
            model.triggerPlaybackEndedForTesting()

            XCTAssertEqual(model.sessionQueueIndex, 0)
            XCTAssertEqual(model.currentFileURL?.path, current.path)
            XCTAssertEqual(model.currentQueueTrack?.id, current.id)
            XCTAssertEqual(model.currentTime, pausedTime)
            XCTAssertFalse(model.isPlaying)

            model.playLocalTransport()

            XCTAssertEqual(model.sessionQueueIndex, 0)
            XCTAssertEqual(model.currentFileURL?.path, current.path)
            XCTAssertEqual(model.currentQueueTrack?.id, current.id)
            XCTAssertTrue(model.isPlaying)
        }
    }

    @MainActor
    func testLocalGaplessLogicalTrackStartCommitsQueueIndexWithoutLoadingNext() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let recorder = LocalLoadRecorder()
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(localAudioLoader: loader)
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)
        recorder.reset()

        model.triggerLocalGaplessLogicalTrackStartedForTesting(Self.descriptor(for: next, queueIndex: 1))

        XCTAssertTrue(model.isLocalGaplessEngineQueueActiveForTesting)
        XCTAssertEqual(model.sessionQueueIndex, 1)
        XCTAssertEqual(model.selectedSessionQueueIndex, 1)
        XCTAssertEqual(model.currentFileURL?.path, next.path)
        XCTAssertEqual(model.currentQueueTrack?.id, next.id)
        XCTAssertTrue(model.isPlaying)
        XCTAssertFalse(model.isLocalFileLoading)
        XCTAssertNil(model.pendingSessionQueueIndex)
        XCTAssertEqual(recorder.fileNames, [])
    }

    @MainActor
    func testLocalGaplessPlaybackEndedDoesNotNaturalAdvanceAgain() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let urls = (0..<3).map { fixture.directory.appendingPathComponent("track-\($0).wav") }
        try urls.forEach { try Self.writeSilentAudioFile(to: $0) }

        let recorder = LocalLoadRecorder()
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(localAudioLoader: loader)
        let tracks = urls.map { Self.track(url: $0) }
        model.replaceLocalMusicQueueForTesting(
            tracks: tracks,
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)
        recorder.reset()

        model.triggerLocalGaplessLogicalTrackStartedForTesting(Self.descriptor(for: tracks[1], queueIndex: 1))
        model.triggerLocalGaplessQueueEndedForTesting()
        model.triggerPlaybackEndedForTesting()

        XCTAssertFalse(model.isLocalGaplessEngineQueueActiveForTesting)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.sessionQueueIndex, 1)
        XCTAssertEqual(model.currentFileURL?.path, tracks[1].path)
        XCTAssertEqual(model.currentQueueTrack?.id, tracks[1].id)
        XCTAssertNil(model.pendingSessionQueueIndex)
        XCTAssertFalse(model.isLocalFileLoading)
        XCTAssertEqual(recorder.fileNames, [])
    }

    @MainActor
    func testLocalGaplessLogicalTrackEndedFinalizesProgressWithoutStopping() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let model = OrbisonicViewModel()
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.currentTime = 0.25
        model.scrubProgress = 0.25
        model.triggerLocalGaplessLogicalTrackStartedForTesting(Self.descriptor(for: current, queueIndex: 0))
        model.currentTime = 0.25
        model.scrubProgress = 0.25
        model.triggerLocalGaplessLogicalTrackEndedForTesting(Self.descriptor(for: current, queueIndex: 0))

        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.currentTime, current.duration)
        XCTAssertEqual(model.scrubProgress, 1)

        model.triggerLocalGaplessLogicalTrackEndedForTesting(Self.descriptor(for: current, queueIndex: 0))
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.sessionQueueIndex, 0)

        model.triggerLocalGaplessLogicalTrackStartedForTesting(Self.descriptor(for: next, queueIndex: 1))
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.sessionQueueIndex, 1)
        XCTAssertEqual(model.currentFileURL?.path, next.path)
        XCTAssertEqual(model.currentTime, 0)
        XCTAssertEqual(model.scrubProgress, 0)
    }

    func testPausedEngineDefersRendererGraphRebuildAndReschedulesAfterPausedSeek() throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let audioURL = fixture.directory.appendingPathComponent("paused-resume.wav")
        try Self.writeSilentAudioFile(to: audioURL, frames: 48_000)

        let engine = OrbisonicEngine()
        defer { engine.stop() }

        let loaded = try engine.loadFile(url: audioURL)
        let scene = RendererMatrixBuilder.sceneModel(
            for: loaded.layout,
            preset: .sonicSphere30Point1,
            renderMode: .stereo
        )

        try engine.play()
        engine.pause()

        XCTAssertEqual(engine.state, .paused)
        let graphBuildCountAfterPause = engine.debugPlaybackGraphBuildCount

        engine.updateRenderer(mode: scene.renderMode, scene: scene)
        XCTAssertEqual(engine.debugPlaybackGraphBuildCount, graphBuildCountAfterPause)

        engine.seek(toProgress: 0.5)
        XCTAssertTrue(engine.debugPausedPlaybackNeedsReschedule)
        let scheduleCountBeforeResume = engine.debugScheduleFromCurrentPositionCount

        try engine.play()

        XCTAssertEqual(engine.state, .playing)
        XCTAssertFalse(engine.debugPausedPlaybackNeedsReschedule)
        XCTAssertGreaterThan(engine.debugScheduleFromCurrentPositionCount, scheduleCountBeforeResume)
        XCTAssertGreaterThanOrEqual(engine.currentTime(), 0.5)
    }

    @MainActor
    func testStopCancelsPendingQueueLoadWithoutAdvancing() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let model = OrbisonicViewModel(localAudioLoader: Self.delayedLoader(delays: ["next.wav": 0.25]))
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.skipLocalTransport(offset: 1)
        XCTAssertEqual(model.pendingSessionQueueIndex, 1)
        XCTAssertTrue(model.isLocalFileLoading)

        model.stopLocalTransport()
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.currentFileURL?.path, current.path)
        XCTAssertNil(model.pendingSessionQueueIndex)
        XCTAssertFalse(model.isLocalFileLoading)
        XCTAssertFalse(model.isPlaying)
    }

    @MainActor
    func testRapidForwardCoalescesToLatestPendingTarget() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let urls = (0..<4).map { fixture.directory.appendingPathComponent("track-\($0).wav") }
        try urls.forEach { try Self.writeSilentAudioFile(to: $0) }

        let model = OrbisonicViewModel(localAudioLoader: Self.delayedLoader(delays: ["track-1.wav": 0.25]))
        let tracks = urls.map { Self.track(url: $0) }
        model.replaceLocalMusicQueueForTesting(
            tracks: tracks,
            currentIndex: nil,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.skipLocalTransport(offset: 1)
        model.skipLocalTransport(offset: 1)
        model.skipLocalTransport(offset: 1)

        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.pendingSessionQueueIndex, 3)

        try await Self.waitForLocalLoadToFinish(model)

        XCTAssertEqual(model.sessionQueueIndex, 3)
        XCTAssertEqual(model.currentFileURL?.path, tracks[3].path)
        XCTAssertEqual(model.selectedSessionQueueIndex, 0)
        XCTAssertNil(model.pendingSessionQueueIndex)
        XCTAssertFalse(model.isLocalFileLoading)
    }

    @MainActor
    func testRapidForwardStartsOnlyFinalDebouncedDecode() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let urls = (0..<4).map { fixture.directory.appendingPathComponent("track-\($0).wav") }
        try urls.forEach { try Self.writeSilentAudioFile(to: $0) }

        let recorder = LocalLoadRecorder()
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(localAudioLoader: loader)
        let tracks = urls.map { Self.track(url: $0) }
        model.replaceLocalMusicQueueForTesting(
            tracks: tracks,
            currentIndex: nil,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)
        recorder.reset()

        model.skipLocalTransport(offset: 1)
        model.skipLocalTransport(offset: 1)
        model.skipLocalTransport(offset: 1)

        XCTAssertEqual(model.sessionQueueIndex, 0)
        XCTAssertEqual(model.pendingSessionQueueIndex, 3)

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(recorder.fileNames, [])

        try await Self.waitForLocalLoadToFinish(model)

        XCTAssertEqual(recorder.fileNames, ["track-3.wav"])
        XCTAssertEqual(model.sessionQueueIndex, 3)
        XCTAssertEqual(model.currentFileURL?.path, tracks[3].path)
    }

    @MainActor
    func testStaleForegroundDecodeDoesNotCommitAfterNewerTrackSelected() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let urls = (0..<2).map { fixture.directory.appendingPathComponent("track-\($0).wav") }
        try urls.forEach { try Self.writeSilentAudioFile(to: $0) }

        let recorder = LocalLoadRecorder(delays: ["track-0.wav": 0.25])
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(localAudioLoader: loader)
        let tracks = urls.map { Self.track(url: $0) }
        model.replaceLocalMusicQueueForTesting(
            tracks: tracks,
            currentIndex: nil,
            selectedIndex: nil
        )

        XCTAssertTrue(model.playQueueIndexForTesting(0))
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(model.playQueueIndexForTesting(1))

        let deadline = Date().addingTimeInterval(3)
        var observedStaleCommit = false
        while model.currentFileURL?.path != tracks[1].path, Date() < deadline {
            if model.currentFileURL?.path == tracks[0].path {
                observedStaleCommit = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(observedStaleCommit)
        try await Self.waitForCurrentFile(model, path: tracks[1].path)
        XCTAssertEqual(model.sessionQueueIndex, 1)
    }

    @MainActor
    func testNextTrackUsesAdjacentMetadataDescriptorButStillForegroundDecodes() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let recorder = LocalLoadRecorder()
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(
            localAudioLoader: loader,
            preloadAdjacentLocalMusicTracks: true,
            adjacentFullPreloadPCMByteLimit: PreparedPCMPolicy.maxFullPreparedPCMBytes
        )
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)
        try await Self.waitForCachedLocalDescriptor(model, path: next.path)

        recorder.reset()
        XCTAssertFalse(model.hasPreparedLocalFileForTesting(path: next.path))
        XCTAssertFalse(recorder.fileNames.contains("next.wav"))

        model.skipLocalTransport(offset: 1)
        try await Self.waitForCurrentFile(model, path: next.path)

        XCTAssertEqual(recorder.fileNames, ["next.wav"])
        XCTAssertEqual(model.sessionQueueIndex, 1)
        XCTAssertTrue(model.isPlaying)
    }

    @MainActor
    func testAdjacentFullPreloadSkipsWhenCapIsZero() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let recorder = LocalLoadRecorder()
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(
            localAudioLoader: loader,
            preloadAdjacentLocalMusicTracks: true
        )
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(recorder.fileNames.contains("next.wav"))
        XCTAssertFalse(model.hasPreparedLocalFileForTesting(path: next.path))
        XCTAssertTrue(model.hasCachedLocalDescriptorForTesting(path: next.path))
    }

    @MainActor
    func testAdjacentMetadataPreloadDoesNotStorePreparedPCMAfterNewerTrackSelected() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let urls = (0..<5).map { fixture.directory.appendingPathComponent("track-\($0).wav") }
        try urls.forEach { try Self.writeSilentAudioFile(to: $0) }

        let recorder = LocalLoadRecorder(delays: ["track-1.wav": 0.35])
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(
            localAudioLoader: loader,
            preloadAdjacentLocalMusicTracks: true,
            adjacentFullPreloadPCMByteLimit: PreparedPCMPolicy.maxFullPreparedPCMBytes
        )
        let tracks = urls.map { Self.track(url: $0) }
        model.replaceLocalMusicQueueForTesting(
            tracks: tracks,
            currentIndex: nil,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        try await Self.waitForCachedLocalDescriptor(model, path: tracks[1].path)
        XCTAssertFalse(recorder.fileNames.contains("track-1.wav"))

        model.playQueueIndexForTesting(3)
        try await Self.waitForCurrentFile(model, path: tracks[3].path)
        try await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertFalse(model.hasPreparedLocalFileForTesting(path: tracks[1].path))
    }

    @MainActor
    func testAdjacentMetadataDescriptorInvalidatesWhenFileChanges() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let recorder = LocalLoadRecorder()
        let loader: @Sendable (URL) throws -> LoadedAudioFile = { url in
            try recorder.load(url: url)
        }
        let model = OrbisonicViewModel(
            localAudioLoader: loader,
            preloadAdjacentLocalMusicTracks: true,
            adjacentFullPreloadPCMByteLimit: PreparedPCMPolicy.maxFullPreparedPCMBytes
        )
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)
        try await Self.waitForCachedLocalDescriptor(model, path: next.path)

        try Self.writeSilentAudioFile(to: nextURL, frames: 960)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: nextURL.path
        )
        XCTAssertFalse(model.hasPreparedLocalFileForTesting(path: next.path))
        XCTAssertFalse(model.hasCachedLocalDescriptorForTesting(path: next.path))

        recorder.reset()
        model.skipLocalTransport(offset: 1)
        try await Self.waitForCurrentFile(model, path: next.path)

        XCTAssertEqual(recorder.fileNames.first, "next.wav")
        XCTAssertEqual(model.sessionQueueIndex, 1)
        XCTAssertTrue(model.isPlaying)
    }

    @MainActor
    func testWebPlayerControlsRemainUsableDuringPendingLocalLoad() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }

        let currentURL = fixture.directory.appendingPathComponent("current.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: currentURL)
        try Self.writeSilentAudioFile(to: nextURL)

        let model = OrbisonicViewModel(localAudioLoader: Self.delayedLoader(delays: ["next.wav": 0.25]))
        let current = Self.track(url: currentURL)
        let next = Self.track(url: nextURL)
        model.replaceLocalMusicQueueForTesting(
            tracks: [current, next],
            currentIndex: nil,
            selectedIndex: nil
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)
        model.skipLocalTransport(offset: 1)

        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(state.player.controls, ["previous", "play", "pause", "next"])
        XCTAssertTrue(state.player.enabledControls.contains("pause"))
        XCTAssertTrue(state.player.enabledControls.contains("next"))
        XCTAssertFalse(state.player.enabledControls.contains("play"))
    }

    private static func writeSilentAudioFile(to url: URL, frames: AVAudioFrameCount = 480) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else {
            XCTFail("Could not create test audio format")
            return
        }
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func track(url: URL) -> LocalMusicTrack {
        track(
            url: url,
            rootURL: url.deletingLastPathComponent(),
            title: url.deletingPathExtension().lastPathComponent,
            artist: nil,
            album: nil
        )
    }

    private static func track(
        url: URL,
        rootURL: URL,
        title: String?,
        artist: String?,
        album: String?
    ) -> LocalMusicTrack {
        LocalMusicTrack(
            path: url.path,
            rootPath: rootURL.path,
            fileName: url.lastPathComponent,
            title: title,
            artist: artist,
            album: album,
            channelCount: 2,
            channelSummary: "FL, FR",
            layoutName: "Stereo",
            sampleRate: 48_000,
            duration: 1,
            artworkPath: nil
        )
    }

    private static func descriptor(
        for track: LocalMusicTrack,
        queueIndex: Int
    ) -> LocalGaplessTrackDescriptor {
        LocalGaplessTrackDescriptor(
            id: track.id,
            url: track.url,
            queueIndex: queueIndex,
            displayName: track.displayTitle
        )
    }

    private static func writeMatroskaFixture(
        to url: URL,
        ffmpegURL: URL,
        includesNormalVideo: Bool,
        includesAttachedCover: Bool
    ) throws {
        let directory = url.deletingLastPathComponent()
        let coverURL = directory.appendingPathComponent("cover-\(UUID().uuidString).png")
        if includesAttachedCover {
            let coverResult = try MatroskaAudioProbe.runProcess(
                executableURL: ffmpegURL,
                arguments: [
                    "-v", "error",
                    "-y",
                    "-f", "lavfi",
                    "-i", "color=c=red:s=32x32",
                    "-frames:v", "1",
                    coverURL.path
                ]
            )
            guard coverResult.terminationStatus == 0 else {
                throw XCTSkip("ffmpeg cover fixture generation failed: \(coverResult.errorText)")
            }
        }

        var arguments = [
            "-v", "error",
            "-y"
        ]
        if includesNormalVideo {
            arguments += [
                "-f", "lavfi",
                "-i", "color=c=black:s=64x64:r=1"
            ]
        }
        arguments += [
            "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"
        ]
        if includesAttachedCover {
            arguments += [
                "-loop", "1",
                "-i", coverURL.path
            ]
        }
        arguments += [
            "-t", "0.1"
        ]
        if includesNormalVideo {
            arguments += [
                "-map", "0:v",
                "-map", "1:a"
            ]
            if includesAttachedCover {
                arguments += ["-map", "2:v"]
            }
        } else {
            arguments += ["-map", "0:a"]
            if includesAttachedCover {
                arguments += ["-map", "1:v"]
            }
        }
        if includesNormalVideo {
            arguments += ["-c:v:0", "libx264"]
        }
        arguments += [
            "-c:a", "flac",
            "-metadata", "title=Matroska Artwork Fixture"
        ]
        if includesAttachedCover {
            let attachedVideoIndex = includesNormalVideo ? "1" : "0"
            arguments += [
                "-metadata:s:v:\(attachedVideoIndex)", "filename=cover.png",
                "-metadata:s:v:\(attachedVideoIndex)", "mimetype=image/png",
                "-disposition:v:\(attachedVideoIndex)", "attached_pic",
                "-c:v:\(attachedVideoIndex)", "png"
            ]
        }
        arguments.append(url.path)

        let result = try MatroskaAudioProbe.runProcess(
            executableURL: ffmpegURL,
            arguments: arguments
        )
        guard result.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg Matroska artwork fixture generation failed: \(result.errorText)")
        }
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func spotifyNowPlaying(title: String, isPlaying: Bool) -> SpotifyNowPlaying {
        SpotifyNowPlaying(
            title: title,
            album: "Album",
            artists: ["Artist"],
            albumArtists: ["Artist"],
            uri: "spotify:track:test",
            durationMs: 180_000,
            positionMs: 42_000,
            isPlaying: isPlaying,
            isExplicit: false,
            popularity: nil,
            trackNumber: nil,
            discNumber: nil,
            coverURL: nil,
            volume: nil,
            shuffle: nil,
            repeatContext: nil,
            repeatTrack: nil,
            autoPlay: nil,
            clientName: "Spotify",
            sessionActive: true,
            updatedAt: "test"
        )
    }

    private static func delayedLoader(delays: [String: TimeInterval]) -> @Sendable (URL) throws -> LoadedAudioFile {
        { url in
            if let delay = delays[url.lastPathComponent] {
                Thread.sleep(forTimeInterval: delay)
            }
            return try AudioFileLoader().load(url: url)
        }
    }

    @MainActor
    private static func waitForLocalLoadToFinish(
        _ model: OrbisonicViewModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isLocalFileLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.isLocalFileLoading)
    }

    @MainActor
    private static func waitForPreparedLocalFile(
        _ model: OrbisonicViewModel,
        path: String,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !model.hasPreparedLocalFileForTesting(path: path), Date() < deadline {
            if let lastError = model.lastError, !lastError.isEmpty {
                XCTFail("Unexpected local preload error: \(lastError)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(model.hasPreparedLocalFileForTesting(path: path))
    }

    @MainActor
    private static func waitForCachedLocalDescriptor(
        _ model: OrbisonicViewModel,
        path: String,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !model.hasCachedLocalDescriptorForTesting(path: path), Date() < deadline {
            if let lastError = model.lastError, !lastError.isEmpty {
                XCTFail("Unexpected local metadata preload error: \(lastError)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(model.hasCachedLocalDescriptorForTesting(path: path))
    }

    @MainActor
    private static func waitForCurrentFile(
        _ model: OrbisonicViewModel,
        path: String,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.currentFileURL?.path != path, Date() < deadline {
            if let lastError = model.lastError, !lastError.isEmpty {
                XCTFail("Unexpected local Play Now error: \(lastError)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }


        XCTAssertEqual(model.currentFileURL?.path, path)
        XCTAssertFalse(model.isLocalFileLoading)
        XCTAssertNil(model.pendingSessionQueueIndex)
    }

    @MainActor
    func testNextTrackPreloadPreparesNextWhenBudgetAllows() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }
        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: firstURL, frames: 48_000)
        try Self.writeSilentAudioFile(to: nextURL, frames: 48_000)

        let model = OrbisonicViewModel(
            systemMemoryProvider: StubMemoryProvider(availableBytes: 16_000_000_000, totalBytes: 32_000_000_000)
        )
        model.setSourceModeForTesting(.filePlayback)
        model.replaceLocalMusicQueueForTesting(
            tracks: [Self.track(url: firstURL), Self.track(url: nextURL)],
            currentIndex: 0,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.preloadNextTrackEnabled = true
        await model.awaitNextTrackPreloadForTesting()

        XCTAssertTrue(model.hasPreparedLocalFileForTesting(path: nextURL.path))
        XCTAssertEqual(model.nextTrackPreloadStatus, .ready)
    }

    @MainActor
    func testNextTrackPreloadSkipsWhenMemoryIsTight() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }
        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: firstURL, frames: 48_000)
        try Self.writeSilentAudioFile(to: nextURL, frames: 48_000)

        let model = OrbisonicViewModel(
            systemMemoryProvider: StubMemoryProvider(availableBytes: 1_024, totalBytes: 32_000_000_000)
        )
        model.setSourceModeForTesting(.filePlayback)
        model.replaceLocalMusicQueueForTesting(
            tracks: [Self.track(url: firstURL), Self.track(url: nextURL)],
            currentIndex: 0,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.preloadNextTrackEnabled = true
        await model.awaitNextTrackPreloadForTesting()

        XCTAssertFalse(model.hasPreparedLocalFileForTesting(path: nextURL.path))
        XCTAssertEqual(model.nextTrackPreloadStatus, .skippedLowMemory)
    }
}

private struct StubMemoryProvider: SystemMemoryProviding {
    let availableBytes: Int
    let totalBytes: Int
    func snapshot() -> SystemMemorySnapshot {
        SystemMemorySnapshot(availableBytes: availableBytes, totalBytes: totalBytes)
    }
}

private final class LocalLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let delays: [String: TimeInterval]
    private var loadedFileNames: [String] = []

    init(delays: [String: TimeInterval] = [:]) {
        self.delays = delays
    }

    var fileNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedFileNames
    }

    func reset() {
        lock.lock()
        loadedFileNames.removeAll()
        lock.unlock()
    }

    func load(url: URL) throws -> LoadedAudioFile {
        lock.lock()
        loadedFileNames.append(url.lastPathComponent)
        lock.unlock()
        if let delay = delays[url.lastPathComponent] {
            Thread.sleep(forTimeInterval: delay)
        }
        return try AudioFileLoader().load(url: url)
    }
}

private final class TemporaryLocalMusicFixture {
    let directory: URL
    let supportDirectory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbisonic-local-player-tests-\(UUID().uuidString)", isDirectory: true)
        supportDirectory = directory.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
