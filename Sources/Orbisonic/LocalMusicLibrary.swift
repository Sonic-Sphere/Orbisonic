import AVFoundation
import Foundation

struct LocalMusicSettings: Codable, Equatable, Sendable {
    var watchFolderPaths: [String] = []
    var m3uPlaylistPaths: [String] = []
    var scansSubfolders = true
    var importsM3UPlaylists = true
    var extractsAlbumArt = true
    var enhancesMetadata = true

    init(
        watchFolderPaths: [String] = [],
        m3uPlaylistPaths: [String] = [],
        scansSubfolders: Bool = true,
        importsM3UPlaylists: Bool = true,
        extractsAlbumArt: Bool = true,
        enhancesMetadata: Bool = true
    ) {
        self.watchFolderPaths = watchFolderPaths
        self.m3uPlaylistPaths = m3uPlaylistPaths
        self.scansSubfolders = scansSubfolders
        self.importsM3UPlaylists = importsM3UPlaylists
        self.extractsAlbumArt = extractsAlbumArt
        self.enhancesMetadata = enhancesMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case watchFolderPaths
        case m3uPlaylistPaths
        case scansSubfolders
        case importsM3UPlaylists
        case extractsAlbumArt
        case enhancesMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchFolderPaths = try container.decodeIfPresent([String].self, forKey: .watchFolderPaths) ?? []
        m3uPlaylistPaths = try container.decodeIfPresent([String].self, forKey: .m3uPlaylistPaths) ?? []
        scansSubfolders = try container.decodeIfPresent(Bool.self, forKey: .scansSubfolders) ?? true
        importsM3UPlaylists = try container.decodeIfPresent(Bool.self, forKey: .importsM3UPlaylists) ?? true
        extractsAlbumArt = try container.decodeIfPresent(Bool.self, forKey: .extractsAlbumArt) ?? true
        enhancesMetadata = try container.decodeIfPresent(Bool.self, forKey: .enhancesMetadata) ?? true
    }
}

struct LocalMusicDatabase: Codable, Equatable, Sendable {
    var settings = LocalMusicSettings()
    var tracks: [LocalMusicTrack] = []
    var playlists: [LocalMusicPlaylist] = []
    var metadataOverlays: [String: LocalMusicMetadataOverlay] = [:]
    var metadataScannedTrackIDs: Set<String> = []

    init(
        settings: LocalMusicSettings = LocalMusicSettings(),
        tracks: [LocalMusicTrack] = [],
        playlists: [LocalMusicPlaylist] = [],
        metadataOverlays: [String: LocalMusicMetadataOverlay] = [:],
        metadataScannedTrackIDs: Set<String> = []
    ) {
        self.settings = settings
        self.tracks = tracks
        self.playlists = playlists
        self.metadataOverlays = metadataOverlays
        self.metadataScannedTrackIDs = metadataScannedTrackIDs
    }

    private enum CodingKeys: String, CodingKey {
        case settings
        case tracks
        case playlists
        case metadataOverlays
        case metadataScannedTrackIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = try container.decodeIfPresent(LocalMusicSettings.self, forKey: .settings) ?? LocalMusicSettings()
        tracks = try container.decodeIfPresent([LocalMusicTrack].self, forKey: .tracks) ?? []
        playlists = try container.decodeIfPresent([LocalMusicPlaylist].self, forKey: .playlists) ?? []
        metadataOverlays = try container.decodeIfPresent([String: LocalMusicMetadataOverlay].self, forKey: .metadataOverlays) ?? [:]
        metadataScannedTrackIDs = try container.decodeIfPresent(Set<String>.self, forKey: .metadataScannedTrackIDs) ?? []
    }
}

struct LocalMusicTrack: Identifiable, Codable, Equatable, Sendable {
    let path: String
    let rootPath: String?
    let fileName: String
    let title: String?
    let artist: String?
    let album: String?
    let trackNumber: Int?
    let discNumber: Int?
    let channelCount: Int
    let channelSummary: String
    let layoutName: String
    let sampleRate: Double
    let duration: TimeInterval
    let artworkPath: String?

    init(
        path: String,
        rootPath: String?,
        fileName: String,
        title: String?,
        artist: String?,
        album: String?,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        channelCount: Int,
        channelSummary: String,
        layoutName: String,
        sampleRate: Double,
        duration: TimeInterval,
        artworkPath: String?
    ) {
        self.path = path
        self.rootPath = rootPath
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.channelCount = channelCount
        self.channelSummary = channelSummary
        self.layoutName = layoutName
        self.sampleRate = sampleRate
        self.duration = duration
        self.artworkPath = artworkPath
    }

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var fallbackTitle: String { (fileName as NSString).deletingPathExtension }

    var displayTitle: String {
        title?.trimmedNilIfBlank ?? fallbackTitle
    }

    var displayArtist: String {
        artist?.trimmedNilIfBlank ?? "-"
    }

    var displayAlbum: String {
        album?.trimmedNilIfBlank ?? "-"
    }

    var displaySubtitle: String {
        let metadata = [artist?.trimmedNilIfBlank, album?.trimmedNilIfBlank].compactMap { $0 }
        return metadata.isEmpty ? displayPath : metadata.joined(separator: " • ")
    }

    var channelText: String {
        guard channelCount > 0 else { return "-" }
        return "\(channelCount) ch"
    }

    var channelDetailText: String {
        guard channelCount > 0 else { return "-" }
        return channelSummary.isEmpty ? "\(channelCount) ch" : "\(channelCount) (\(channelSummary))"
    }

    var sampleRateText: String {
        guard sampleRate > 0 else { return "-" }
        if sampleRate >= 1_000 {
            return String(format: "%.1f kHz", sampleRate / 1_000)
        }
        return String(format: "%.0f Hz", sampleRate)
    }

    var durationText: String {
        Self.formatDuration(duration)
    }

    var sortName: String { displayTitle }
    var sortArtist: String { artist?.trimmedNilIfBlank ?? "" }
    var sortAlbum: String { album?.trimmedNilIfBlank ?? "" }
    var sortFolder: String { displayPath }
    var sortAlbumOrFolder: String { album?.trimmedNilIfBlank ?? sortFolder }
    var sortDiscNumber: Int { effectiveDiscNumber ?? 1 }
    var sortTrackNumber: Int { effectiveTrackNumber ?? Int.max }
    var sortFilePath: String { path }
    var effectiveTrackNumber: Int? {
        trackNumber ?? Self.trackNumber(fromFileName: fileName)
    }
    var effectiveDiscNumber: Int? {
        discNumber ?? Self.discNumber(
            fromFileName: fileName,
            parentFolderName: url.deletingLastPathComponent().lastPathComponent
        )
    }
    var needsMetadataEnhancement: Bool {
        title?.trimmedNilIfBlank == nil ||
            artist?.trimmedNilIfBlank == nil ||
            album?.trimmedNilIfBlank == nil ||
            artworkPath?.trimmedNilIfBlank == nil
    }

    var displayPath: String {
        let folderPath = (path as NSString).deletingLastPathComponent
        guard let rootPath else { return folderPath }

        if folderPath == rootPath {
            return (rootPath as NSString).lastPathComponent
        }

        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        if folderPath.hasPrefix(prefix) {
            return String(folderPath.dropFirst(prefix.count))
        }

        return folderPath
    }

    func matches(_ query: String) -> Bool {
        let fields = [
            fileName,
            displayTitle,
            artist ?? "",
            album ?? "",
            channelText,
            layoutName,
            displayPath
        ]

        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    func applyingMetadataOverlay(_ overlay: LocalMusicMetadataOverlay?) -> LocalMusicTrack {
        guard let overlay, overlay.isDisplayEligible else { return self }

        return LocalMusicTrack(
            path: path,
            rootPath: rootPath,
            fileName: fileName,
            title: title?.trimmedNilIfBlank ?? overlay.title?.trimmedNilIfBlank,
            artist: artist?.trimmedNilIfBlank ?? overlay.artist?.trimmedNilIfBlank,
            album: album?.trimmedNilIfBlank ?? overlay.album?.trimmedNilIfBlank,
            trackNumber: trackNumber ?? overlay.trackNumber,
            discNumber: discNumber ?? overlay.discNumber,
            channelCount: channelCount,
            channelSummary: channelSummary,
            layoutName: layoutName,
            sampleRate: sampleRate,
            duration: duration,
            artworkPath: artworkPath?.trimmedNilIfBlank ?? overlay.artworkPath?.trimmedNilIfBlank
        )
    }

    private static func formatDuration(_ value: TimeInterval) -> String {
        let totalSeconds = max(Int(value.rounded(.down)), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func trackNumber(fromFileName fileName: String) -> Int? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        if let match = firstCaptureGroups(in: stem, pattern: #"^\s*(\d{1,2})[-._](\d{1,3})(?=\D|$)"#),
           match.count >= 2,
           let track = positiveTrackNumber(match[1]) {
            return track
        }
        if let match = firstCaptureGroups(in: stem, pattern: #"^\s*(\d{1,3})(?:\s*/\s*\d{1,3})?(?=\s*[-._ ]+)"#),
           let raw = match.first,
           let track = positiveTrackNumber(raw) {
            return track
        }
        return nil
    }

    static func discNumber(fromFileName fileName: String, parentFolderName: String? = nil) -> Int? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        if let match = firstCaptureGroups(in: stem, pattern: #"^\s*(\d{1,2})[-._](\d{1,3})(?=\D|$)"#),
           let raw = match.first,
           let disc = positiveDiscNumber(raw) {
            return disc
        }
        if let parentFolderName,
           let match = firstCaptureGroups(in: parentFolderName, pattern: #"(?i)\b(?:disc|disk|cd)\s*(\d{1,2})\b"#),
           let raw = match.first,
           let disc = positiveDiscNumber(raw) {
            return disc
        }
        return nil
    }

    private static func positiveTrackNumber(_ value: String) -> Int? {
        guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...999).contains(number)
        else { return nil }
        return number
    }

    private static func positiveDiscNumber(_ value: String) -> Int? {
        guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...99).contains(number)
        else { return nil }
        return number
    }

    private static func firstCaptureGroups(in value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else { return nil }
        let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound,
                  let swiftRange = Range(nsRange, in: value)
            else { return nil }
            return String(value[swiftRange])
        }
        return groups.isEmpty ? nil : groups
    }
}

struct LocalMusicPlaylist: Identifiable, Codable, Equatable, Sendable {
    let name: String
    let path: String
    let trackPaths: [String]

    var id: String { path }
    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum LocalMusicPlaylistMutationError: LocalizedError, Equatable {
    case duplicateTrack
    case invalidName
    case readOnly
    case playlistMissing
    case nameConflict(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .duplicateTrack:
            return "That song is already in this playlist."
        case .invalidName:
            return "Playlist name is required."
        case .readOnly:
            return "Imported playlists are read-only. Save or create an Orbisonic playlist to edit it."
        case .playlistMissing:
            return "The playlist file could not be found."
        case .nameConflict(let name):
            return "A playlist named \(name) already exists."
        case .deleteFailed(let name):
            return "Could not delete playlist \(name)."
        }
    }
}

struct LocalMusicScanResult: Sendable {
    let tracks: [LocalMusicTrack]
    let playlists: [LocalMusicPlaylist]
    let skippedMissingFiles: Int
}

private struct LocalMusicURLCollection {
    let urls: [URL]
    let skippedMissingFiles: Int
}

private struct M3UParseResult {
    let urls: [URL]
    let skippedMissingFiles: Int
}

private struct MatroskaArtworkProbeOutput: Decodable {
    let streams: [MatroskaArtworkProbeStream]
}

private struct MatroskaArtworkProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let disposition: [String: Int]?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case disposition
        case tags
    }

    var fileExtension: String? {
        let mimeType = Self.tagValue("mimetype", in: tags ?? [:])?.lowercased()
        switch mimeType {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        default:
            break
        }

        switch codecName?.lowercased() {
        case "png":
            return "png"
        case "mjpeg", "jpeg", "jpg":
            return "jpg"
        default:
            return nil
        }
    }

    var isAttachedPicture: Bool {
        disposition?["attached_pic"] == 1
    }

    var hasCoverMetadata: Bool {
        let filename = Self.tagValue("filename", in: tags ?? [:])?.lowercased() ?? ""
        let mimeType = Self.tagValue("mimetype", in: tags ?? [:])?.lowercased() ?? ""
        return filename.contains("cover") || mimeType.hasPrefix("image/")
    }

    var isArtworkCandidate: Bool {
        codecType == "video" && fileExtension != nil && (isAttachedPicture || hasCoverMetadata)
    }

    var preferenceScore: Int {
        var score = 0
        if isAttachedPicture {
            score += 100
        }
        if hasCoverMetadata {
            score += 20
        }
        return score
    }

    private static func tagValue(_ key: String, in tags: [String: String]) -> String? {
        tags.first { $0.key.localizedCaseInsensitiveCompare(key) == .orderedSame }?
            .value
            .trimmedNilIfBlank
    }
}

final class LocalMusicLibrary: @unchecked Sendable {
    private let fileManager: FileManager
    private let databaseURL: URL
    private let artworkDirectoryURL: URL
    private let enrichedArtworkDirectoryURL: URL
    private let playlistDirectoryURL: URL

    init(fileManager: FileManager = .default, supportURL: URL? = nil) {
        self.fileManager = fileManager
        let supportURL = supportURL ?? Self.applicationSupportURL(fileManager: fileManager)
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        databaseURL = supportURL.appendingPathComponent("local-music-library.json", isDirectory: false)
        artworkDirectoryURL = supportURL.appendingPathComponent("Album Artwork", isDirectory: true)
        enrichedArtworkDirectoryURL = supportURL.appendingPathComponent("Enriched Artwork", isDirectory: true)
        playlistDirectoryURL = supportURL.appendingPathComponent("Playlists", isDirectory: true)
        try? fileManager.createDirectory(at: artworkDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: enrichedArtworkDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: playlistDirectoryURL, withIntermediateDirectories: true)
    }

    var databasePath: String {
        databaseURL.path
    }

    var artworkDirectoryPath: String {
        artworkDirectoryURL.path
    }

    var enrichedArtworkDirectoryPath: String {
        enrichedArtworkDirectoryURL.path
    }

    var playlistDirectoryPath: String {
        playlistDirectoryURL.path
    }

    func isEditablePlaylist(_ playlist: LocalMusicPlaylist) -> Bool {
        isManagedPlaylistURL(URL(fileURLWithPath: playlist.path))
    }

    func load() -> LocalMusicDatabase {
        guard let data = try? Data(contentsOf: databaseURL) else {
            return LocalMusicDatabase()
        }

        do {
            let database = try JSONDecoder().decode(LocalMusicDatabase.self, from: data)
            let pruned = pruneMissingFiles(in: database)
            let indexed = repairMissingTrackIndexMetadata(in: pruned)
            if indexed != database {
                save(indexed)
            }
            return indexed
        } catch {
            AppLogger.shared.error(category: "local-music", "Failed to decode local music database: \(error.localizedDescription)")
            return LocalMusicDatabase()
        }
    }

    func save(_ database: LocalMusicDatabase) {
        do {
            try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(database)
            try data.write(to: databaseURL, options: .atomic)
        } catch {
            AppLogger.shared.error(category: "local-music", "Failed to save local music database: \(error.localizedDescription)")
        }
    }

    func cacheEnrichedArtwork(
        _ data: Data,
        sourceURL: URL?,
        trackID: String
    ) -> String? {
        guard !data.isEmpty else { return nil }

        let ext = Self.artworkExtension(for: data, sourceURL: sourceURL)
        let filename = "\(Self.stableIdentifier(for: trackID))-metadata.\(ext)"
        let destinationURL = enrichedArtworkDirectoryURL.appendingPathComponent(filename, isDirectory: false)

        do {
            try fileManager.createDirectory(at: enrichedArtworkDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: destinationURL, options: .atomic)
            return destinationURL.path
        } catch {
            AppLogger.shared.error(category: "local-music", "Metadata artwork cache failed track=\(trackID) error=\(error.localizedDescription)")
            return nil
        }
    }

    func scan(settings: LocalMusicSettings) -> LocalMusicScanResult {
        let collected = collectAudioURLs(settings: settings)
        let tracks = collected.urls.map { url in
            metadata(for: url, rootPath: rootPath(for: url, settings: settings), extractsAlbumArt: settings.extractsAlbumArt)
        }
        let tracksByPath = Dictionary(uniqueKeysWithValues: tracks.map { ($0.path, $0) })
        let playlists = settings.importsM3UPlaylists
            ? collectPlaylists(settings: settings, tracksByPath: tracksByPath)
            : []

        return LocalMusicScanResult(
            tracks: tracks.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            playlists: playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            skippedMissingFiles: collected.skippedMissingFiles
        )
    }

    func saveSessionPlaylist(name: String, tracks: [LocalMusicTrack]) throws -> LocalMusicPlaylist {
        try fileManager.createDirectory(at: playlistDirectoryURL, withIntermediateDirectories: true)

        let fileStem = Self.sanitizedFileStem(name)
        let playlistURL = uniquePlaylistURL(fileStem: fileStem)
        try writePlaylist(
            to: playlistURL,
            trackPaths: tracks.map(\.path),
            tracksByPath: tracksByPath(for: tracks)
        )

        return LocalMusicPlaylist(
            name: playlistURL.deletingPathExtension().lastPathComponent,
            path: playlistURL.path,
            trackPaths: tracks.map(\.path)
        )
    }

    func createPlaylist(name: String, tracks: [LocalMusicTrack]) throws -> LocalMusicPlaylist {
        try saveSessionPlaylist(name: name, tracks: tracks)
    }

    func appendTrack(
        _ track: LocalMusicTrack,
        to playlist: LocalMusicPlaylist,
        knownTracks: [LocalMusicTrack]
    ) throws -> LocalMusicPlaylist {
        guard isEditablePlaylist(playlist) else {
            throw LocalMusicPlaylistMutationError.readOnly
        }
        guard !playlist.trackPaths.contains(track.path) else {
            throw LocalMusicPlaylistMutationError.duplicateTrack
        }

        return try updateEditablePlaylist(
            playlist,
            trackPaths: playlist.trackPaths + [track.path],
            knownTracks: knownTracks + [track]
        )
    }

    func updateEditablePlaylist(
        _ playlist: LocalMusicPlaylist,
        trackPaths: [String],
        knownTracks: [LocalMusicTrack]
    ) throws -> LocalMusicPlaylist {
        guard isEditablePlaylist(playlist) else {
            throw LocalMusicPlaylistMutationError.readOnly
        }

        let playlistURL = URL(fileURLWithPath: playlist.path)
        try fileManager.createDirectory(at: playlistDirectoryURL, withIntermediateDirectories: true)
        try writePlaylist(
            to: playlistURL,
            trackPaths: trackPaths,
            tracksByPath: tracksByPath(for: knownTracks)
        )

        return LocalMusicPlaylist(
            name: playlistURL.deletingPathExtension().lastPathComponent,
            path: playlistURL.path,
            trackPaths: trackPaths
        )
    }

    func renameEditablePlaylist(_ playlist: LocalMusicPlaylist, to rawName: String) throws -> LocalMusicPlaylist {
        guard isEditablePlaylist(playlist) else {
            throw LocalMusicPlaylistMutationError.readOnly
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LocalMusicPlaylistMutationError.invalidName
        }

        let currentURL = URL(fileURLWithPath: playlist.path)
        let fileStem = Self.sanitizedFileStem(name)
        let targetURL = playlistDirectoryURL
            .appendingPathComponent(fileStem, isDirectory: false)
            .appendingPathExtension("m3u")

        if currentURL.standardizedFileURL.path == targetURL.standardizedFileURL.path {
            return LocalMusicPlaylist(
                name: targetURL.deletingPathExtension().lastPathComponent,
                path: currentURL.path,
                trackPaths: playlist.trackPaths
            )
        }

        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw LocalMusicPlaylistMutationError.nameConflict(targetURL.deletingPathExtension().lastPathComponent)
        }
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw LocalMusicPlaylistMutationError.playlistMissing
        }

        try fileManager.moveItem(at: currentURL, to: targetURL)
        return LocalMusicPlaylist(
            name: targetURL.deletingPathExtension().lastPathComponent,
            path: targetURL.path,
            trackPaths: playlist.trackPaths
        )
    }

    func deleteEditablePlaylist(_ playlist: LocalMusicPlaylist) throws {
        guard isEditablePlaylist(playlist) else {
            throw LocalMusicPlaylistMutationError.readOnly
        }

        let playlistURL = URL(fileURLWithPath: playlist.path)
        guard fileManager.fileExists(atPath: playlistURL.path) else {
            throw LocalMusicPlaylistMutationError.playlistMissing
        }

        do {
            try fileManager.removeItem(at: playlistURL)
        } catch {
            throw LocalMusicPlaylistMutationError.deleteFailed(playlist.name)
        }
    }

    private func collectAudioURLs(settings: LocalMusicSettings) -> LocalMusicURLCollection {
        var seenPaths = Set<String>()
        var urls: [URL] = []
        var skippedMissingFiles = 0

        for folderPath in settings.watchFolderPaths {
            let folderURL = URL(fileURLWithPath: folderPath)
            let candidates = audioURLs(in: folderURL, recursive: settings.scansSubfolders)
            for url in candidates where seenPaths.insert(url.path).inserted {
                urls.append(url)
            }
        }

        if settings.importsM3UPlaylists {
            for playlistPath in settings.m3uPlaylistPaths {
                let playlistURL = URL(fileURLWithPath: playlistPath)
                let parsed = parseM3U(at: playlistURL)
                skippedMissingFiles += parsed.skippedMissingFiles
                for url in parsed.urls where seenPaths.insert(url.path).inserted {
                    urls.append(url)
                }
            }
        }

        return LocalMusicURLCollection(urls: urls, skippedMissingFiles: skippedMissingFiles)
    }

    private func audioURLs(in folderURL: URL, recursive: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]

        if recursive,
           let enumerator = fileManager.enumerator(
               at: folderURL,
               includingPropertiesForKeys: keys,
               options: [.skipsHiddenFiles, .skipsPackageDescendants]
           ) {
            return enumerator.compactMap { item in
                guard let url = item as? URL else { return nil }
                return Self.isSupportedAudioFile(url) ? url : nil
            }
        }

        return (try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ).filter(Self.isSupportedAudioFile)) ?? []
    }

    private func collectPlaylists(settings: LocalMusicSettings, tracksByPath: [String: LocalMusicTrack]) -> [LocalMusicPlaylist] {
        var playlistURLs: [URL] = settings.m3uPlaylistPaths.map { URL(fileURLWithPath: $0) }
        var seenPlaylistPaths = Set(playlistURLs.map(\.path))

        for folderPath in settings.watchFolderPaths {
            let folderURL = URL(fileURLWithPath: folderPath)
            let candidates = m3uURLs(in: folderURL, recursive: settings.scansSubfolders)
            for url in candidates where seenPlaylistPaths.insert(url.path).inserted {
                playlistURLs.append(url)
            }
        }

        return playlistURLs.compactMap { playlistURL in
            let trackPaths = parseM3U(at: playlistURL).urls
                .map(\.path)
                .filter { tracksByPath[$0] != nil || fileManager.fileExists(atPath: $0) }
            guard !trackPaths.isEmpty || isManagedPlaylistURL(playlistURL) else { return nil }
            return LocalMusicPlaylist(
                name: playlistURL.deletingPathExtension().lastPathComponent,
                path: playlistURL.path,
                trackPaths: trackPaths
            )
        }
    }

    private func m3uURLs(in folderURL: URL, recursive: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]

        if recursive,
           let enumerator = fileManager.enumerator(
               at: folderURL,
               includingPropertiesForKeys: keys,
               options: [.skipsHiddenFiles, .skipsPackageDescendants]
           ) {
            return enumerator.compactMap { item in
                guard let url = item as? URL else { return nil }
                return Self.isM3UPlaylist(url) ? url : nil
            }
        }

        return (try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ).filter(Self.isM3UPlaylist)) ?? []
    }

    private func parseM3U(at playlistURL: URL) -> M3UParseResult {
        guard let contents = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return M3UParseResult(urls: [], skippedMissingFiles: 0)
        }

        let baseURL = playlistURL.deletingLastPathComponent()
        var skippedMissingFiles = 0
        let urls = contents
            .components(separatedBy: .newlines)
            .compactMap { line -> URL? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

                let url: URL
                if trimmed.hasPrefix("/") {
                    url = URL(fileURLWithPath: trimmed)
                } else if let parsedURL = URL(string: trimmed), parsedURL.isFileURL {
                    url = parsedURL
                } else {
                    url = baseURL.appendingPathComponent(trimmed).standardizedFileURL
                }

                guard Self.isSupportedAudioFile(url) else { return nil }
                guard fileManager.fileExists(atPath: url.path) else {
                    skippedMissingFiles += 1
                    return nil
                }
                return url
            }
        return M3UParseResult(urls: urls, skippedMissingFiles: skippedMissingFiles)
    }

    private func metadata(for url: URL, rootPath: String?, extractsAlbumArt: Bool) -> LocalMusicTrack {
        if MatroskaFLACSupport.isMatroska(url) {
            return matroskaMetadata(for: url, rootPath: rootPath, extractsAlbumArt: extractsAlbumArt)
        }

        let asset = AVURLAsset(url: url)
        let commonMetadata = asset.commonMetadata
        let title = Self.metadataString(for: .commonKeyTitle, in: commonMetadata)
        let artist = Self.metadataString(for: .commonKeyArtist, in: commonMetadata)
        let album = Self.metadataString(for: .commonKeyAlbumName, in: commonMetadata)
        let trackNumber = Self.metadataOrdinal(
            for: [.iTunesMetadataTrackNumber, .id3MetadataTrackNumber],
            in: asset.metadata
        ) ?? LocalMusicTrack.trackNumber(fromFileName: url.lastPathComponent)
        let discNumber = Self.metadataOrdinal(
            for: [.iTunesMetadataDiscNumber],
            in: asset.metadata
        ) ?? LocalMusicTrack.discNumber(
            fromFileName: url.lastPathComponent,
            parentFolderName: url.deletingLastPathComponent().lastPathComponent
        )
        let artworkPath = extractsAlbumArt ? extractArtwork(for: url, metadata: commonMetadata) : nil

        do {
            let file = try AVAudioFile(forReading: url)
            let layout = SurroundLayoutDetector.detect(for: file.processingFormat)
            let duration = file.fileFormat.sampleRate > 0 ? Double(file.length) / file.fileFormat.sampleRate : 0

            return LocalMusicTrack(
                path: url.path,
                rootPath: rootPath,
                fileName: url.lastPathComponent,
                title: title,
                artist: artist,
                album: album,
                trackNumber: trackNumber,
                discNumber: discNumber,
                channelCount: Int(file.processingFormat.channelCount),
                channelSummary: layout.channelSummary,
                layoutName: layout.name,
                sampleRate: file.fileFormat.sampleRate,
                duration: duration,
                artworkPath: artworkPath
            )
        } catch {
            AppLogger.shared.error(category: "local-music", "Metadata scan failed file=\(url.path) error=\(error.localizedDescription)")
            return LocalMusicTrack(
                path: url.path,
                rootPath: rootPath,
                fileName: url.lastPathComponent,
                title: title,
                artist: artist,
                album: album,
                trackNumber: trackNumber,
                discNumber: discNumber,
                channelCount: 0,
                channelSummary: "",
                layoutName: "-",
                sampleRate: 0,
                duration: 0,
                artworkPath: artworkPath
            )
        }
    }

    func repairingStaleMatroskaTracks(in tracks: [LocalMusicTrack], extractsAlbumArt: Bool) async -> [LocalMusicTrack] {
        tracks.map { track in
            guard MatroskaFLACSupport.isMatroska(track.url),
                  fileManager.fileExists(atPath: track.path)
            else {
                return track
            }

            let needsMetadataRepair = track.channelCount <= 0
            let needsArtworkRepair = extractsAlbumArt
                && track.artworkPath == legacyMatroskaArtworkURL(for: track.url).path
            guard needsMetadataRepair || needsArtworkRepair else {
                return track
            }

            return matroskaMetadata(
                for: track.url,
                rootPath: track.rootPath,
                extractsAlbumArt: extractsAlbumArt
            )
        }
    }

    private func repairMissingTrackIndexMetadata(in database: LocalMusicDatabase) -> LocalMusicDatabase {
        var repaired = database
        var changed = false
        repaired.tracks = database.tracks.map { track in
            let inferredTrackNumber = track.trackNumber ?? LocalMusicTrack.trackNumber(fromFileName: track.fileName)
            let inferredDiscNumber = track.discNumber ?? LocalMusicTrack.discNumber(
                fromFileName: track.fileName,
                parentFolderName: track.url.deletingLastPathComponent().lastPathComponent
            )
            guard inferredTrackNumber != track.trackNumber ||
                inferredDiscNumber != track.discNumber
            else { return track }

            changed = true
            return LocalMusicTrack(
                path: track.path,
                rootPath: track.rootPath,
                fileName: track.fileName,
                title: track.title,
                artist: track.artist,
                album: track.album,
                trackNumber: inferredTrackNumber,
                discNumber: inferredDiscNumber,
                channelCount: track.channelCount,
                channelSummary: track.channelSummary,
                layoutName: track.layoutName,
                sampleRate: track.sampleRate,
                duration: track.duration,
                artworkPath: track.artworkPath
            )
        }
        return changed ? repaired : database
    }

    private func pruneMissingFiles(in database: LocalMusicDatabase) -> LocalMusicDatabase {
        let existingTracks = database.tracks.filter { fileManager.fileExists(atPath: $0.path) }
        let existingTrackPaths = Set(existingTracks.map(\.path))

        let playlists = database.playlists.compactMap { playlist -> LocalMusicPlaylist? in
            let trackPaths = playlist.trackPaths.filter { path in
                existingTrackPaths.contains(path) || fileManager.fileExists(atPath: path)
            }
            guard !trackPaths.isEmpty || isEditablePlaylist(playlist) else { return nil }
            return LocalMusicPlaylist(name: playlist.name, path: playlist.path, trackPaths: trackPaths)
        }

        guard existingTracks.count != database.tracks.count || playlists != database.playlists else {
            return database
        }

        AppLogger.shared.notice(
            category: "local-music",
            "Pruned missing local music tracks removed=\(database.tracks.count - existingTracks.count)"
        )

        return LocalMusicDatabase(
            settings: database.settings,
            tracks: existingTracks,
            playlists: playlists,
            metadataOverlays: database.metadataOverlays.filter { existingTrackPaths.contains($0.key) }
        )
    }

    private func matroskaMetadata(for url: URL, rootPath: String?, extractsAlbumArt: Bool) -> LocalMusicTrack {
        do {
            let streamInfo = try MatroskaAudioProbe().probe(url: url)
            let layout = SurroundLayoutDetector.fallbackLayout(for: streamInfo.channelCount)
            return LocalMusicTrack(
                path: url.path,
                rootPath: rootPath,
                fileName: url.lastPathComponent,
                title: streamInfo.tags.title,
                artist: streamInfo.tags.artist,
                album: streamInfo.tags.album,
                trackNumber: LocalMusicTrack.trackNumber(fromFileName: url.lastPathComponent),
                discNumber: LocalMusicTrack.discNumber(
                    fromFileName: url.lastPathComponent,
                    parentFolderName: url.deletingLastPathComponent().lastPathComponent
                ),
                channelCount: streamInfo.channelCount,
                channelSummary: layout.channelSummary,
                layoutName: layout.name,
                sampleRate: streamInfo.sampleRate,
                duration: streamInfo.duration,
                artworkPath: extractsAlbumArt ? extractMatroskaArtwork(for: url) : nil
            )
        } catch {
            AppLogger.shared.error(category: "local-music", "Matroska metadata scan failed file=\(url.path) error=\(error.localizedDescription)")
            return LocalMusicTrack(
                path: url.path,
                rootPath: rootPath,
                fileName: url.lastPathComponent,
                title: nil,
                artist: nil,
                album: nil,
                trackNumber: LocalMusicTrack.trackNumber(fromFileName: url.lastPathComponent),
                discNumber: LocalMusicTrack.discNumber(
                    fromFileName: url.lastPathComponent,
                    parentFolderName: url.deletingLastPathComponent().lastPathComponent
                ),
                channelCount: 0,
                channelSummary: "",
                layoutName: "-",
                sampleRate: 0,
                duration: 0,
                artworkPath: extractsAlbumArt ? extractMatroskaArtwork(for: url) : nil
            )
        }
    }

    private func extractMatroskaArtwork(for url: URL) -> String? {
        guard let ffmpegURL = FFmpegToolLocator.ffmpegURL(),
              let artworkStream = matroskaArtworkStream(for: url),
              let artworkExtension = artworkStream.fileExtension
        else {
            return nil
        }

        let filename = "\(Self.stableIdentifier(for: url.path))-cover.\(artworkExtension)"
        let destinationURL = artworkDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL.path
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-y",
            "-v", "error",
            "-i", url.path,
            "-map", "0:\(artworkStream.index)",
            "-frames:v", "1",
            "-c:v", "copy",
            destinationURL.path
        ]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLogger.shared.debug(category: "local-music", "Matroska artwork extraction could not start file=\(url.path) error=\(error.localizedDescription)")
            return nil
        }

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: destinationURL.path)
        else {
            try? fileManager.removeItem(at: destinationURL)
            return nil
        }

        return destinationURL.path
    }

    private func matroskaArtworkStream(for url: URL) -> MatroskaArtworkProbeStream? {
        guard let ffprobeURL = FFmpegToolLocator.ffprobeURL() else { return nil }

        do {
            let result = try MatroskaAudioProbe.runProcess(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-print_format", "json",
                    "-show_streams",
                    url.path
                ]
            )

            guard result.terminationStatus == 0 else {
                AppLogger.shared.debug(
                    category: "local-music",
                    "Matroska artwork probe failed file=\(url.path) error=\(result.errorText)"
                )
                return nil
            }

            let output = try JSONDecoder().decode(MatroskaArtworkProbeOutput.self, from: result.outputData)
            return output.streams
                .filter(\.isArtworkCandidate)
                .sorted { lhs, rhs in
                    if lhs.preferenceScore == rhs.preferenceScore {
                        return lhs.index < rhs.index
                    }
                    return lhs.preferenceScore > rhs.preferenceScore
                }
                .first
        } catch {
            AppLogger.shared.debug(
                category: "local-music",
                "Matroska artwork probe could not inspect file=\(url.path) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func legacyMatroskaArtworkURL(for url: URL) -> URL {
        artworkDirectoryURL
            .appendingPathComponent(Self.stableIdentifier(for: url.path), isDirectory: false)
            .appendingPathExtension("jpg")
    }

    private func extractArtwork(for url: URL, metadata: [AVMetadataItem]) -> String? {
        guard let artworkData = AVMetadataItem
            .metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common)
            .first?
            .dataValue,
              !artworkData.isEmpty
        else {
            return nil
        }

        let ext = Self.artworkExtension(for: artworkData)
        let filename = "\(Self.stableIdentifier(for: url.path)).\(ext)"
        let destinationURL = artworkDirectoryURL.appendingPathComponent(filename, isDirectory: false)

        do {
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try artworkData.write(to: destinationURL, options: .atomic)
            }
            return destinationURL.path
        } catch {
            AppLogger.shared.error(category: "local-music", "Artwork extraction failed file=\(url.path) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func rootPath(for url: URL, settings: LocalMusicSettings) -> String? {
        settings.watchFolderPaths
            .sorted { $0.count > $1.count }
            .first { watchPath in
                let prefix = watchPath.hasSuffix("/") ? watchPath : "\(watchPath)/"
                return url.path == watchPath || url.path.hasPrefix(prefix)
            }
    }

    private static func metadataString(for key: AVMetadataKey, in metadata: [AVMetadataItem]) -> String? {
        AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common)
            .first?
            .stringValue?
            .trimmedNilIfBlank
    }

    private static func metadataOrdinal(for identifiers: [AVMetadataIdentifier], in metadata: [AVMetadataItem]) -> Int? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                if let number = ordinalValue(from: item) {
                    return number
                }
            }
        }
        return nil
    }

    private static func ordinalValue(from item: AVMetadataItem) -> Int? {
        if let number = item.numberValue?.intValue,
           number > 0 {
            return number
        }
        if let string = item.stringValue,
           let number = firstPositiveInteger(in: string) {
            return number
        }
        if let number = (item.value as? NSNumber)?.intValue,
           number > 0 {
            return number
        }
        if let string = item.value as? String,
           let number = firstPositiveInteger(in: string) {
            return number
        }
        if let data = item.dataValue,
           let number = ordinalValue(from: data) {
            return number
        }
        return nil
    }

    private static func firstPositiveInteger(in value: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              let swiftRange = Range(match.range, in: value)
        else { return nil }
        let number = Int(value[swiftRange]) ?? 0
        return number > 0 ? number : nil
    }

    private static func ordinalValue(from data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        if bytes.count >= 4 {
            let iTunesOrdinal = Int(bytes[2]) << 8 | Int(bytes[3])
            if iTunesOrdinal > 0 {
                return iTunesOrdinal
            }
        }
        for index in 0..<(bytes.count - 1) {
            let value = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            if value > 0 {
                return value
            }
        }
        return nil
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = [
            "wav", "wave", "flac", "aif", "aiff", "caf", "mp3", "mkv", "mka",
            "ec3", "eac3", "ac3", "ac4", "mlp", "mp4", "mov", "m4a", "m2ts", "ts"
        ]

        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isM3UPlaylist(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = ["m3u", "m3u8"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func artworkExtension(for data: Data, sourceURL: URL? = nil) -> String {
        if let sourceExtension = sourceURL?.pathExtension.lowercased(),
           ["png", "jpg", "jpeg", "webp"].contains(sourceExtension) {
            return sourceExtension == "jpeg" ? "jpg" : sourceExtension
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(data[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        return "jpg"
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func sanitizedFileStem(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let stem = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
        return stem.isEmpty ? "Session Queue" : stem
    }

    private func isManagedPlaylistURL(_ url: URL) -> Bool {
        Self.isM3UPlaylist(url) &&
            url.deletingLastPathComponent().standardizedFileURL.path == playlistDirectoryURL.standardizedFileURL.path
    }

    private func writePlaylist(
        to playlistURL: URL,
        trackPaths: [String],
        tracksByPath: [String: LocalMusicTrack]
    ) throws {
        let lines = ["#EXTM3U"] + trackPaths.flatMap { path in
            let track = tracksByPath[path]
            let duration = track.map { Int($0.duration.rounded(.down)) } ?? -1
            let title = track?.displayTitle ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return [
                "#EXTINF:\(duration),\(title)",
                path
            ]
        }
        let contents = lines.joined(separator: "\n") + "\n"
        try contents.write(to: playlistURL, atomically: true, encoding: .utf8)
    }

    private func tracksByPath(for tracks: [LocalMusicTrack]) -> [String: LocalMusicTrack] {
        tracks.reduce(into: [:]) { result, track in
            result[track.path] = track
        }
    }

    private func uniquePlaylistURL(fileStem: String) -> URL {
        var candidate = playlistDirectoryURL.appendingPathComponent(fileStem, isDirectory: false).appendingPathExtension("m3u")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = playlistDirectoryURL
                .appendingPathComponent("\(fileStem) \(suffix)", isDirectory: false)
                .appendingPathExtension("m3u")
            suffix += 1
        }
        return candidate
    }

    private static func applicationSupportURL(fileManager: FileManager) -> URL {
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Orbisonic", isDirectory: true) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let fallbackURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Orbisonic", isDirectory: true)
        try? fileManager.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
        return fallbackURL
    }
}

extension String {
    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
