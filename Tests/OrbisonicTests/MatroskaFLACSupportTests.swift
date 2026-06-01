import AVFoundation
import XCTest
@testable import Orbisonic

final class MatroskaFLACSupportTests: XCTestCase {
    func testProbeParserAcceptsPrimaryFLACAudioAndMetadata() throws {
        let json = """
        {
          "streams": [
            {
              "index": 1,
              "codec_type": "audio",
              "codec_name": "flac",
              "sample_rate": "96000",
              "channels": 8,
              "bits_per_raw_sample": "24",
              "duration": "12.5",
              "tags": {
                "TITLE": "Auro Test Song"
              }
            }
          ],
          "format": {
            "duration": "12.5",
            "tags": {
              "ALBUM": "Auro Test Album",
              "ARTIST": "Auro Test Artist"
            }
          }
        }
        """

        let info = try MatroskaAudioProbe.parse(
            ffprobeData: Data(json.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/test.mka")
        )

        XCTAssertEqual(info.streamIndex, 1)
        XCTAssertEqual(info.codecName, "FLAC")
        XCTAssertEqual(info.streamTitle, "Auro Test Song")
        XCTAssertEqual(info.sampleRate, 96_000)
        XCTAssertEqual(info.channelCount, 8)
        XCTAssertEqual(info.bitDepth, 24)
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertEqual(info.tags.title, "Auro Test Song")
        XCTAssertEqual(info.tags.album, "Auro Test Album")
        XCTAssertEqual(info.tags.artist, "Auro Test Artist")
    }

    func testProbeParserRejectsNonFLACMatroskaAudio() {
        let json = """
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "audio",
              "codec_name": "aac",
              "sample_rate": "48000",
              "channels": 2
            }
          ]
        }
        """

        XCTAssertThrowsError(
            try MatroskaAudioProbe.parse(
                ffprobeData: Data(json.utf8),
                sourceURL: URL(fileURLWithPath: "/tmp/test.mkv")
            )
        ) { error in
            XCTAssertEqual(error as? MatroskaAudioProbeError, .unsupportedAudioCodec("aac"))
            XCTAssertTrue(error.localizedDescription.contains("FLAC, PCM, or Dolby/DTS surround"))
        }
    }

    func testProbeParserPrefersAuroPCMOverEarlierAtmosStream() throws {
        let json = """
        {
          "streams": [
            {
              "index": 1,
              "codec_type": "audio",
              "codec_name": "truehd",
              "sample_rate": "48000",
              "channels": 8,
              "bits_per_raw_sample": "24",
              "tags": {
                "title": "Dolby Atmos (48/24)"
              }
            },
            {
              "index": 2,
              "codec_type": "audio",
              "codec_name": "pcm_s24le",
              "sample_rate": "96000",
              "channels": 8,
              "bits_per_sample": 24,
              "bits_per_raw_sample": "24",
              "tags": {
                "title": "Auro-3D (96/24)"
              }
            },
            {
              "index": 3,
              "codec_type": "audio",
              "codec_name": "pcm_s24le",
              "sample_rate": "96000",
              "channels": 2,
              "bits_per_sample": 24,
              "tags": {
                "title": "Stereo (96/24)"
              }
            }
          ],
          "format": {
            "duration": "467.991",
            "tags": {
              "TITLE": "Flow",
              "ARTIST": "Justin Gray"
            }
          }
        }
        """

        let info = try MatroskaAudioProbe.parse(
            ffprobeData: Data(json.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/flow.mkv")
        )

        XCTAssertEqual(info.streamIndex, 2)
        XCTAssertEqual(info.codecName, "Auro-3D PCM")
        XCTAssertEqual(info.streamTitle, "Auro-3D (96/24)")
        XCTAssertEqual(info.sampleRate, 96_000)
        XCTAssertEqual(info.channelCount, 8)
        XCTAssertEqual(info.bitDepth, 24)
        XCTAssertEqual(info.tags.title, "Flow")
        XCTAssertEqual(info.tags.artist, "Justin Gray")
    }

    func testLocalLibraryAdmitsMatroskaExtensions() {
        XCTAssertTrue(LocalMusicLibrary.isSupportedAudioFile(URL(fileURLWithPath: "/tmp/album.mkv")))
        XCTAssertTrue(LocalMusicLibrary.isSupportedAudioFile(URL(fileURLWithPath: "/tmp/album.mka")))
    }

    func testFFmpegToolLocatorDoesNotDependOnBundleModule() {
        _ = FFmpegToolLocator.ffmpegURL()
        _ = FFmpegToolLocator.ffprobeURL()
    }

    func testLocalPlayerRowsSeparateTagsFormatChannelsAndLength() {
        let metadata = AudioSourceMetadata(
            fileName: "fallback-title.mka",
            containerName: "Matroska",
            codecName: "FLAC",
            layoutName: "7.1 Surround",
            channelSummary: "FL, FR, C, LFE, RL, RR, SL, SR",
            channelCount: 8,
            sampleRate: 96_000,
            bitDepth: 24,
            duration: 125,
            title: "Auro Fixture",
            album: "Matroska FLAC",
            artist: "Orbisonic Tests"
        )

        let rows = LocalFilePlayerRowsModel.rows(metadata: metadata)

        XCTAssertEqual(rows.map(\.title), ["Format", "Channels", "Layout", "Length"])
        XCTAssertEqual(rows[0].value, "Matroska FLAC")
        XCTAssertEqual(rows[1].value, "8")
        XCTAssertEqual(rows[2].value, "7.1 Surround")
        XCTAssertEqual(rows[3].value, "02:05")
    }

    func testLocalPlayerRowsMoveAtmosNoteToRendererAndPrefixLayout() {
        let metadata = AudioSourceMetadata(
            fileName: "atmos-bed.mka",
            containerName: "Matroska",
            codecName: "E-AC-3 5.1 bed",
            layoutName: "5.1 Surround",
            channelSummary: "FL, FR, C, LFE, SL, SR",
            channelCount: 6,
            sampleRate: 48_000,
            bitDepth: 24,
            duration: 180,
            formatNote: "Dolby Atmos metadata present; Orbisonic is using the decoded channel bed, not object rendering."
        )

        let rows = LocalFilePlayerRowsModel.rows(metadata: metadata)

        XCTAssertEqual(rows.map(\.title), ["Format", "Channels", "Layout", "Length"])
        XCTAssertFalse(rows.contains { $0.title == "Note" })
        XCTAssertEqual(rows[2].value, "Atmos 5.1")
        XCTAssertEqual(
            LocalFilePlayerRowsModel.rendererAtmosNote(metadata.formatNote),
            "Atmos bed decoded; object metadata not rendered"
        )
    }

    func testCompressedAudioProbeRecognizesEAC3AtmosBedMetadata() {
        let info = CompressedAudioStreamInfo(
            codecName: "eac3",
            profile: "Dolby Digital Plus + Dolby Atmos",
            channels: 6,
            channelLayout: "5.1(side)"
        )

        XCTAssertTrue(info.hasDolbyAtmos)
        XCTAssertEqual(info.channels, 6)
        XCTAssertEqual(info.channelLayout, "5.1(side)")
    }

    func testGeneratedMatroskaFLACFixtureDemuxesThroughAudioFileLoader() throws {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL(),
              FFmpegToolLocator.ffprobeURL() != nil
        else {
            throw XCTSkip("ffmpeg/ffprobe unavailable")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbisonic-matroska-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let fixtureURL = directory.appendingPathComponent("auro-style-flac.mka")
        let result = try MatroskaAudioProbe.runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-v", "error",
                "-y",
                "-f", "lavfi",
                "-i", "anullsrc=channel_layout=7.1:sample_rate=96000",
                "-t", "0.1",
                "-metadata", "title=Auro Fixture",
                "-metadata", "album=Matroska FLAC",
                "-metadata", "artist=Orbisonic Tests",
                "-c:a", "flac",
                fixtureURL.path
            ]
        )

        guard result.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg fixture generation failed: \(result.errorText)")
        }

        let info = try MatroskaAudioProbe().probe(url: fixtureURL)
        XCTAssertEqual(info.codecName, "FLAC")
        XCTAssertEqual(info.channelCount, 8)
        XCTAssertEqual(info.sampleRate, 96_000)

        let loaded = try AudioFileLoader().load(url: fixtureURL)
        XCTAssertEqual(loaded.url, fixtureURL)
        XCTAssertEqual(loaded.metadata.containerName, "Matroska")
        XCTAssertEqual(loaded.metadata.codecName, "FLAC")
        XCTAssertEqual(loaded.metadata.title, "Auro Fixture")
        XCTAssertEqual(loaded.metadata.album, "Matroska FLAC")
        XCTAssertEqual(loaded.metadata.artist, "Orbisonic Tests")
        XCTAssertEqual(loaded.metadata.channelCount, 8)
        XCTAssertEqual(loaded.metadata.sampleRate, 96_000, accuracy: 0.5)
        XCTAssertEqual(loaded.monoBuffers.count, 8)
        XCTAssertGreaterThan(loaded.duration, 0)
    }

    func testGeneratedMatroskaPCMFixtureDemuxesThroughAudioFileLoader() throws {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL(),
              FFmpegToolLocator.ffprobeURL() != nil
        else {
            throw XCTSkip("ffmpeg/ffprobe unavailable")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbisonic-matroska-pcm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let fixtureURL = directory.appendingPathComponent("auro-pcm.mkv")
        let result = try MatroskaAudioProbe.runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-v", "error",
                "-y",
                "-f", "lavfi",
                "-i", "anullsrc=channel_layout=7.1:sample_rate=96000",
                "-t", "0.1",
                "-metadata", "title=Flow",
                "-metadata", "artist=Justin Gray",
                "-metadata:s:a:0", "title=Auro-3D (96/24)",
                "-c:a", "pcm_s24le",
                fixtureURL.path
            ]
        )

        guard result.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg PCM fixture generation failed: \(result.errorText)")
        }

        let info = try MatroskaAudioProbe().probe(url: fixtureURL)
        XCTAssertEqual(info.codecName, "Auro-3D PCM")
        XCTAssertEqual(info.streamTitle, "Auro-3D (96/24)")
        XCTAssertEqual(info.channelCount, 8)

        let loaded = try AudioFileLoader().load(url: fixtureURL)
        XCTAssertEqual(loaded.metadata.containerName, "Matroska")
        XCTAssertEqual(loaded.metadata.codecName, "Auro-3D PCM")
        XCTAssertEqual(loaded.metadata.title, "Flow")
        XCTAssertEqual(loaded.metadata.artist, "Justin Gray")
        XCTAssertEqual(loaded.metadata.channelCount, 8)
        XCTAssertEqual(loaded.metadata.sampleRate, 96_000, accuracy: 0.5)
        XCTAssertEqual(loaded.monoBuffers.count, 8)
    }

    func testProbeParserAcceptsAC3SurroundBed() throws {
        let json = """
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "audio",
              "codec_name": "ac3",
              "sample_rate": "48000",
              "channels": 6,
              "channel_layout": "5.1(side)"
            }
          ],
          "format": { "duration": "252.9" }
        }
        """

        let info = try MatroskaAudioProbe.parse(
            ffprobeData: Data(json.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/fight-test.mkv")
        )

        XCTAssertEqual(info.streamIndex, 0)
        XCTAssertEqual(info.codecName, "Dolby Digital (AC-3)")
        XCTAssertEqual(info.channelCount, 6)
        XCTAssertEqual(info.sampleRate, 48_000)
    }

    func testProbeParserAcceptsTrueHDBedWhenNoLosslessAlternative() throws {
        let json = """
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "audio",
              "codec_name": "truehd",
              "sample_rate": "48000",
              "channels": 8,
              "bits_per_raw_sample": "24",
              "tags": { "title": "Dolby Atmos (48/24)" }
            }
          ]
        }
        """

        let info = try MatroskaAudioProbe.parse(
            ffprobeData: Data(json.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/atmos-only.mkv")
        )

        XCTAssertEqual(info.streamIndex, 0)
        XCTAssertEqual(info.codecName, "Dolby TrueHD")
        XCTAssertEqual(info.channelCount, 8)
    }

    func testProbeParserPrefersLosslessPCMOverDolbyBed() throws {
        let json = """
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "audio",
              "codec_name": "eac3",
              "sample_rate": "48000",
              "channels": 6,
              "tags": { "title": "Dolby Atmos" }
            },
            {
              "index": 1,
              "codec_type": "audio",
              "codec_name": "pcm_s24le",
              "sample_rate": "96000",
              "channels": 8,
              "bits_per_sample": 24,
              "bits_per_raw_sample": "24",
              "tags": { "title": "PCM 7.1" }
            }
          ]
        }
        """

        let info = try MatroskaAudioProbe.parse(
            ffprobeData: Data(json.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/eac3-plus-pcm.mkv")
        )

        XCTAssertEqual(info.streamIndex, 1)
        XCTAssertEqual(info.codecName, "PCM")
        XCTAssertEqual(info.channelCount, 8)
    }
}
