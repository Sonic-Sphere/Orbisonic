import XCTest
@testable import Orbisonic

final class LocalMusicChannelFilterTests: XCTestCase {
    @MainActor
    func testChannelFilterShowsOnlyMatchingChannelCount() throws {
        let fixture = try ChannelFilterFixture()
        defer { fixture.remove() }

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [
                Self.track(dir: fixture.directory, name: "stereo.flac", title: "Stereo Song", channels: 2, layout: "Stereo"),
                Self.track(dir: fixture.directory, name: "surround.flac", title: "Surround Song", channels: 6, layout: "5.1 Surround"),
                Self.track(dir: fixture.directory, name: "atmos.flac", title: "Atmos Song", channels: 8, layout: "7.1 Surround"),
            ],
            playlists: []
        ))

        let model = OrbisonicViewModel(
            localAudioLoader: { _ in throw CocoaError(.fileReadNoSuchFile) },
            localMusicLibrary: library
        )

        XCTAssertEqual(model.localMusicTracks.count, 3)
        XCTAssertEqual(model.availableLocalMusicChannelCounts, [2, 6, 8])

        XCTAssertEqual(model.localMusicChannelFilter, 0)
        XCTAssertEqual(model.visibleLocalMusicTracks.count, 3)

        model.localMusicChannelFilter = 8
        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.channelCount), [8])
        XCTAssertEqual(model.visibleLocalMusicTracks.first?.displayTitle, "Atmos Song")

        model.localMusicChannelFilter = 6
        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.channelCount), [6])

        model.localMusicChannelFilter = 0
        XCTAssertEqual(model.visibleLocalMusicTracks.count, 3)
    }

    @MainActor
    func testChannelFilterCombinesWithSearch() throws {
        let fixture = try ChannelFilterFixture()
        defer { fixture.remove() }

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [
                Self.track(dir: fixture.directory, name: "a.flac", title: "Interstellar", channels: 8, layout: "7.1 Surround"),
                Self.track(dir: fixture.directory, name: "b.flac", title: "Out of Sight", channels: 8, layout: "7.1 Surround"),
                Self.track(dir: fixture.directory, name: "c.flac", title: "Interstellar Stereo", channels: 2, layout: "Stereo"),
            ],
            playlists: []
        ))

        let model = OrbisonicViewModel(
            localAudioLoader: { _ in throw CocoaError(.fileReadNoSuchFile) },
            localMusicLibrary: library
        )

        model.localMusicChannelFilter = 8
        model.localMusicSearchText = "Interstellar"
        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayTitle), ["Interstellar"])
    }

    @MainActor
    func testSortedLibraryIsMemoizedUntilInputsChange() throws {
        let fixture = try ChannelFilterFixture()
        defer { fixture.remove() }

        let library = LocalMusicLibrary(supportURL: fixture.supportDirectory)
        library.save(LocalMusicDatabase(
            settings: LocalMusicSettings(),
            tracks: [
                Self.track(dir: fixture.directory, name: "b.flac", title: "Bravo", channels: 2, layout: "Stereo"),
                Self.track(dir: fixture.directory, name: "a.flac", title: "Alpha", channels: 2, layout: "Stereo"),
                Self.track(dir: fixture.directory, name: "c.flac", title: "Charlie", channels: 2, layout: "Stereo"),
            ],
            playlists: []
        ))

        let model = OrbisonicViewModel(
            localAudioLoader: { _ in throw CocoaError(.fileReadNoSuchFile) },
            localMusicLibrary: library
        )

        model.localMusicSortMode = .name
        let baseline = model.localMusicSortComputeCountForTesting

        // Repeated reads must reuse one sort, not recompute on every access.
        XCTAssertEqual(model.visibleLocalMusicTracks.map(\.displayTitle), ["Alpha", "Bravo", "Charlie"])
        _ = model.visibleLocalMusicTracks
        _ = model.visibleLocalMusicTracks
        XCTAssertEqual(
            model.localMusicSortComputeCountForTesting, baseline + 1,
            "Library sort must be memoized; recomputing on every access saturates the main actor."
        )

        // Filtering and search must reuse the cached sort, not invalidate it.
        model.localMusicChannelFilter = 2
        model.localMusicSearchText = "a"
        _ = model.visibleLocalMusicTracks
        XCTAssertEqual(
            model.localMusicSortComputeCountForTesting, baseline + 1,
            "Filtering/search must reuse the cached sort."
        )

        // Changing the sort mode must invalidate and recompute exactly once.
        model.localMusicSortMode = .artist
        _ = model.visibleLocalMusicTracks
        _ = model.visibleLocalMusicTracks
        XCTAssertEqual(
            model.localMusicSortComputeCountForTesting, baseline + 2,
            "Changing sort mode must trigger exactly one recompute."
        )
    }

    private static func track(dir: URL, name: String, title: String, channels: Int, layout: String) -> LocalMusicTrack {
        let url = dir.appendingPathComponent(name)
        return LocalMusicTrack(
            path: url.path,
            rootPath: dir.path,
            fileName: name,
            title: title,
            artist: nil,
            album: nil,
            channelCount: channels,
            channelSummary: "",
            layoutName: layout,
            sampleRate: 48_000,
            duration: 1,
            artworkPath: nil
        )
    }
}

private final class ChannelFilterFixture {
    let directory: URL
    let supportDirectory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbisonic-channel-filter-tests-\(UUID().uuidString)", isDirectory: true)
        supportDirectory = directory.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
