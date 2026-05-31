import Foundation

struct LocalMusicMetadataOverlay: Codable, Equatable, Sendable {
    static let minimumAutomaticConfidence = 0.86

    var title: String?
    var artist: String?
    var album: String?
    var artworkPath: String?
    var trackNumber: Int?
    var discNumber: Int?
    var sourceName: String
    var sourceIdentifier: String?
    var confidence: Double
    var createdAt: Date

    init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artworkPath: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        sourceName: String,
        sourceIdentifier: String? = nil,
        confidence: Double,
        createdAt: Date = Date()
    ) {
        self.title = title?.trimmedNilIfBlank
        self.artist = artist?.trimmedNilIfBlank
        self.album = album?.trimmedNilIfBlank
        self.artworkPath = artworkPath?.trimmedNilIfBlank
        self.trackNumber = trackNumber.flatMap(Self.positiveTrackNumber)
        self.discNumber = discNumber.flatMap(Self.positiveDiscNumber)
        self.sourceName = sourceName
        self.sourceIdentifier = sourceIdentifier?.trimmedNilIfBlank
        self.confidence = confidence
        self.createdAt = createdAt
    }

    var isDisplayEligible: Bool {
        confidence >= Self.minimumAutomaticConfidence && hasDisplayValue
    }

    var hasDisplayValue: Bool {
        title?.trimmedNilIfBlank != nil ||
            artist?.trimmedNilIfBlank != nil ||
            album?.trimmedNilIfBlank != nil ||
            artworkPath?.trimmedNilIfBlank != nil ||
            trackNumber != nil ||
            discNumber != nil
    }

    private static func positiveTrackNumber(_ value: Int) -> Int? {
        (1...999).contains(value) ? value : nil
    }

    private static func positiveDiscNumber(_ value: Int) -> Int? {
        (1...99).contains(value) ? value : nil
    }
}

struct LocalMusicMetadataLookupResult: Sendable {
    var overlay: LocalMusicMetadataOverlay
    var artworkData: Data?
    var artworkSourceURL: URL?
}

protocol LocalMusicMetadataLookupClient: Sendable {
    func lookup(track: LocalMusicTrack) async throws -> LocalMusicMetadataLookupResult?
}

protocol LocalMusicMetadataEnriching: Sendable {
    func enrich(
        tracks: [LocalMusicTrack],
        existingOverlays: [String: LocalMusicMetadataOverlay],
        alreadyScannedTrackIDs: Set<String>,
        forceRescan: Bool
    ) async -> (overlays: [String: LocalMusicMetadataOverlay], scannedTrackIDs: Set<String>)
}

final class LocalMusicMetadataEnricher: LocalMusicMetadataEnriching, @unchecked Sendable {
    private let library: LocalMusicLibrary
    private let lookupClient: LocalMusicMetadataLookupClient
    private let lookupDelayNanoseconds: UInt64

    init(
        library: LocalMusicLibrary,
        lookupClient: LocalMusicMetadataLookupClient = CompositeLocalMusicMetadataLookupClient(),
        lookupDelayNanoseconds: UInt64 = 1_050_000_000
    ) {
        self.library = library
        self.lookupClient = lookupClient
        self.lookupDelayNanoseconds = lookupDelayNanoseconds
    }

    func enrich(
        tracks: [LocalMusicTrack],
        existingOverlays: [String: LocalMusicMetadataOverlay],
        alreadyScannedTrackIDs: Set<String>,
        forceRescan: Bool
    ) async -> (overlays: [String: LocalMusicMetadataOverlay], scannedTrackIDs: Set<String>) {
        var overlays = existingOverlays
        var scannedTrackIDs = alreadyScannedTrackIDs
        let localResolver = LocalMusicEditionMetadataResolver()
        let candidates = tracks.filter { track in
            track.applyingMetadataOverlay(overlays[track.id]).needsMetadataEnhancement
                && (forceRescan || !alreadyScannedTrackIDs.contains(track.id))
        }

        var onlineCandidates: [LocalMusicTrack] = []
        for track in candidates {
            guard !Task.isCancelled else { return (overlays, scannedTrackIDs) }
            if var localResult = localResolver.lookup(track: track) {
                _ = store(result: &localResult, for: track, overlays: &overlays)
            }
            scannedTrackIDs.insert(track.id)
            if track.applyingMetadataOverlay(overlays[track.id]).needsMetadataEnhancement {
                onlineCandidates.append(track)
            }
        }
        onlineCandidates.sort {
            onlineLookupPriority(for: $0, overlays: overlays) < onlineLookupPriority(for: $1, overlays: overlays)
        }

        for (index, track) in onlineCandidates.enumerated() {
            guard !Task.isCancelled else { return (overlays, scannedTrackIDs) }

            let localResult = localResolver.lookup(track: track)
            let existingOverlay = overlays[track.id]
            let preservedLocalOverlay = localResult?.overlay ?? existingOverlay
            let lookupTrack = localResolver.onlineLookupTrack(for: track, localOverlay: preservedLocalOverlay)
            let onlineResult: LocalMusicMetadataLookupResult?
            do {
                onlineResult = try await lookupClient.lookup(track: lookupTrack)
            } catch {
                AppLogger.shared.debug(
                    category: "local-music",
                    "Metadata lookup skipped track=\(track.fileName) error=\(error.localizedDescription)"
                )
                onlineResult = nil
            }

            guard var result = merge(
                local: localResult ?? existingOverlay.map {
                    LocalMusicMetadataLookupResult(overlay: $0, artworkData: nil, artworkSourceURL: nil)
                },
                online: onlineResult
            ) else { continue }
            _ = store(result: &result, for: track, overlays: &overlays)

            if lookupDelayNanoseconds > 0, index < onlineCandidates.count - 1 {
                do {
                    try await Task.sleep(nanoseconds: lookupDelayNanoseconds)
                } catch {
                    return (overlays, scannedTrackIDs)
                }
            }
        }

        return (overlays, scannedTrackIDs)
    }

    @discardableResult
    private func store(
        result: inout LocalMusicMetadataLookupResult,
        for track: LocalMusicTrack,
        overlays: inout [String: LocalMusicMetadataOverlay]
    ) -> Bool {
        guard result.overlay.confidence >= LocalMusicMetadataOverlay.minimumAutomaticConfidence else {
            return false
        }

        if let artworkData = result.artworkData,
           track.artworkPath?.trimmedNilIfBlank == nil {
            result.overlay.artworkPath = library.cacheEnrichedArtwork(
                artworkData,
                sourceURL: result.artworkSourceURL,
                trackID: track.id
            )
        }

        guard result.overlay.isDisplayEligible else { return false }
        overlays[track.id] = result.overlay
        checkpoint(overlays: overlays)
        AppLogger.shared.info(
            category: "local-music",
            "Enhanced metadata track=\(track.fileName) source=\(result.overlay.sourceName) confidence=\(String(format: "%.2f", result.overlay.confidence))"
        )
        return true
    }

    private func onlineLookupPriority(
        for track: LocalMusicTrack,
        overlays: [String: LocalMusicMetadataOverlay]
    ) -> Int {
        guard let sourceName = overlays[track.id]?.sourceName else { return 3 }
        if sourceName.contains("LocalSidecar") { return 0 }
        if sourceName.contains("LocalFolder") { return 1 }
        return 2
    }

    private func merge(
        local: LocalMusicMetadataLookupResult?,
        online: LocalMusicMetadataLookupResult?
    ) -> LocalMusicMetadataLookupResult? {
        switch (local, online) {
        case let (local?, online?):
            let overlay = LocalMusicMetadataOverlay(
                title: local.overlay.title ?? online.overlay.title,
                artist: local.overlay.artist ?? online.overlay.artist,
                album: local.overlay.album ?? online.overlay.album,
                artworkPath: local.overlay.artworkPath ?? online.overlay.artworkPath,
                trackNumber: local.overlay.trackNumber ?? online.overlay.trackNumber,
                discNumber: local.overlay.discNumber ?? online.overlay.discNumber,
                sourceName: "\(local.overlay.sourceName)+\(online.overlay.sourceName)",
                sourceIdentifier: [local.overlay.sourceIdentifier, online.overlay.sourceIdentifier]
                    .compactMap { $0?.trimmedNilIfBlank }
                    .joined(separator: "+")
                    .trimmedNilIfBlank,
                confidence: max(local.overlay.confidence, online.overlay.confidence)
            )
            return LocalMusicMetadataLookupResult(
                overlay: overlay,
                artworkData: local.artworkData ?? online.artworkData,
                artworkSourceURL: local.artworkSourceURL ?? online.artworkSourceURL
            )
        case let (local?, nil):
            return local
        case let (nil, online?):
            return online
        case (nil, nil):
            return nil
        }
    }

    private func checkpoint(overlays: [String: LocalMusicMetadataOverlay]) {
        var database = library.load()
        database.metadataOverlays.merge(overlays) { _, new in new }
        library.save(database)
    }
}

final class CompositeLocalMusicMetadataLookupClient: LocalMusicMetadataLookupClient, @unchecked Sendable {
    private let clients: [LocalMusicMetadataLookupClient]

    init(clients: [LocalMusicMetadataLookupClient] = [
        MusicBrainzLocalMusicMetadataLookupClient(),
        AppleITunesLocalMusicMetadataLookupClient()
    ]) {
        self.clients = clients
    }

    func lookup(track: LocalMusicTrack) async throws -> LocalMusicMetadataLookupResult? {
        var best: LocalMusicMetadataLookupResult?
        for client in clients {
            let result: LocalMusicMetadataLookupResult?
            do {
                result = try await client.lookup(track: track)
            } catch {
                AppLogger.shared.debug(
                    category: "local-music",
                    "Metadata provider skipped error=\(error.localizedDescription)"
                )
                continue
            }
            guard let result,
                  result.overlay.confidence >= LocalMusicMetadataOverlay.minimumAutomaticConfidence
            else { continue }

            if let current = best {
                let overlay = LocalMusicMetadataOverlay(
                    title: current.overlay.title ?? result.overlay.title,
                    artist: current.overlay.artist ?? result.overlay.artist,
                    album: current.overlay.album ?? result.overlay.album,
                    artworkPath: current.overlay.artworkPath ?? result.overlay.artworkPath,
                    trackNumber: current.overlay.trackNumber ?? result.overlay.trackNumber,
                    discNumber: current.overlay.discNumber ?? result.overlay.discNumber,
                    sourceName: "\(current.overlay.sourceName)+\(result.overlay.sourceName)",
                    sourceIdentifier: [current.overlay.sourceIdentifier, result.overlay.sourceIdentifier]
                        .compactMap { $0?.trimmedNilIfBlank }
                        .joined(separator: "+")
                        .trimmedNilIfBlank,
                    confidence: max(current.overlay.confidence, result.overlay.confidence)
                )
                best = LocalMusicMetadataLookupResult(
                    overlay: overlay,
                    artworkData: current.artworkData ?? result.artworkData,
                    artworkSourceURL: current.artworkSourceURL ?? result.artworkSourceURL
                )
            } else {
                best = result
            }

            if best?.artworkData != nil,
               best?.overlay.title != nil || track.title?.trimmedNilIfBlank != nil,
               best?.overlay.artist != nil || track.artist?.trimmedNilIfBlank != nil,
               best?.overlay.album != nil || track.album?.trimmedNilIfBlank != nil {
                break
            }
        }
        return best
    }
}

final class LocalMusicEditionMetadataResolver {
    private let fileManager: FileManager
    private var folderSidecarCache: [String: LocalMusicAlbumEditionContext] = [:]
    private var folderArtworkCache: [String: URL?] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func lookup(track: LocalMusicTrack) -> LocalMusicMetadataLookupResult? {
        let context = albumContext(for: track)
        let artworkURL = track.artworkPath?.trimmedNilIfBlank == nil ? folderArtworkURL(for: track.url.deletingLastPathComponent()) : nil
        let artworkData = artworkURL.flatMap { try? Data(contentsOf: $0) }
        let trustedLocalContext = context.hasTrustedLocalContext || artworkData != nil
        guard trustedLocalContext else { return nil }

        let title = track.title?.trimmedNilIfBlank == nil ? context.trackTitle(for: track) : nil
        let artist = track.artist?.trimmedNilIfBlank == nil ? context.artist : nil
        let album = track.album?.trimmedNilIfBlank == nil ? context.displayAlbum : nil
        let trackNumber = track.trackNumber == nil ? context.trackNumber(for: track) : nil
        let discNumber = track.discNumber == nil ? context.discNumber(for: track) : nil

        guard title != nil || artist != nil || album != nil || trackNumber != nil || discNumber != nil || artworkData != nil else { return nil }
        let overlay = LocalMusicMetadataOverlay(
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            discNumber: discNumber,
            sourceName: context.sourceName,
            sourceIdentifier: context.sourceIdentifier,
            confidence: context.confidence
        )
        return LocalMusicMetadataLookupResult(
            overlay: overlay,
            artworkData: artworkData,
            artworkSourceURL: artworkURL
        )
    }

    func onlineLookupTrack(
        for track: LocalMusicTrack,
        localOverlay: LocalMusicMetadataOverlay?
    ) -> LocalMusicTrack {
        let context = albumContext(for: track)
        let album = if context.hasTrustedLocalContext {
            track.album?.trimmedNilIfBlank ?? context.canonicalAlbum ?? localOverlay?.album?.trimmedNilIfBlank
        } else {
            track.album?.trimmedNilIfBlank ?? localOverlay?.album?.trimmedNilIfBlank ?? context.canonicalAlbum
        }
        return LocalMusicTrack(
            path: track.path,
            rootPath: track.rootPath,
            fileName: track.fileName,
            title: track.title?.trimmedNilIfBlank ?? localOverlay?.title?.trimmedNilIfBlank ?? context.trackTitle(for: track),
            artist: track.artist?.trimmedNilIfBlank ?? localOverlay?.artist?.trimmedNilIfBlank ?? context.artist,
            album: album,
            trackNumber: track.trackNumber ?? localOverlay?.trackNumber ?? context.trackNumber(for: track),
            discNumber: track.discNumber ?? localOverlay?.discNumber ?? context.discNumber(for: track),
            channelCount: track.channelCount,
            channelSummary: track.channelSummary,
            layoutName: track.layoutName,
            sampleRate: track.sampleRate,
            duration: track.duration,
            artworkPath: track.artworkPath
        )
    }

    private func albumContext(for track: LocalMusicTrack) -> LocalMusicAlbumEditionContext {
        let folderURL = track.url.deletingLastPathComponent()
        var context = folderSidecarContext(for: folderURL)
        context.channelLayout = context.channelLayout ?? channelLayout(from: track)
        context.finalize()
        return context
    }

    private func folderSidecarContext(for folderURL: URL) -> LocalMusicAlbumEditionContext {
        if let cached = folderSidecarCache[folderURL.path] {
            return cached
        }
        var context = LocalMusicAlbumEditionContext(folderName: folderURL.lastPathComponent)

        if let manifest = readManifest(at: folderURL) {
            context.artist = context.artist ?? manifest.albumArtist ?? manifest.artist
            context.canonicalAlbum = context.canonicalAlbum ?? manifest.album
            context.year = context.year ?? manifest.year
            context.trackTitlesByNumber.merge(manifest.trackTitlesByNumber) { current, _ in current }
            context.sourceNames.append("manifest")
        }

        if let cue = readCue(at: folderURL) {
            context.artist = context.artist ?? cue.artist
            context.canonicalAlbum = context.canonicalAlbum ?? cue.album
            context.year = context.year ?? cue.year
            context.trackTitlesByFilename.merge(cue.trackTitlesByFilename) { current, _ in current }
            context.trackTitlesByNumber.merge(cue.trackTitlesByNumber) { current, _ in current }
            context.trackNumbersByFilename.merge(cue.trackNumbersByFilename) { current, _ in current }
            context.sourceNames.append("cue")
        }

        if let ripReport = readRipReport(at: folderURL) {
            context.artist = context.artist ?? ripReport.artist
            context.canonicalAlbum = context.canonicalAlbum ?? ripReport.album
            context.year = context.year ?? ripReport.year
            context.trackTitlesByFilename.merge(ripReport.trackTitlesByFilename) { current, _ in current }
            context.trackTitlesByNumber.merge(ripReport.trackTitlesByNumber) { current, _ in current }
            context.trackNumbersByFilename.merge(ripReport.trackNumbersByFilename) { current, _ in current }
            context.sourceMedium = context.sourceMedium ?? ripReport.sourceMedium
            context.channelLayout = context.channelLayout ?? ripReport.channelLayout
            context.sourceNames.append("rip-report")
        }

        folderSidecarCache[folderURL.path] = context
        return context
    }

    private func folderArtworkURL(for folderURL: URL) -> URL? {
        if let cached = folderArtworkCache[folderURL.path] {
            return cached
        }
        let preferredNames = [
            "Folder", "folder", "Cover", "cover", "Front", "front", "Album", "album"
        ]
        let extensions = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff"]
        for name in preferredNames {
            for ext in extensions {
                let candidate = folderURL.appendingPathComponent(name, isDirectory: false).appendingPathExtension(ext)
                if fileManager.fileExists(atPath: candidate.path) {
                    folderArtworkCache[folderURL.path] = candidate
                    return candidate
                }
            }
        }
        folderArtworkCache.updateValue(nil, forKey: folderURL.path)
        return nil
    }

    private func readManifest(at folderURL: URL) -> ManifestSidecar? {
        let url = folderURL.appendingPathComponent("manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ManifestSidecar.self, from: data)
    }

    private func readRipReport(at folderURL: URL) -> RipReportSidecar? {
        let url = folderURL.appendingPathComponent("rip-report.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RipReportSidecar.self, from: data)
    }

    private func readCue(at folderURL: URL) -> CueSidecar? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        guard let url = urls.first(where: { $0.pathExtension.localizedCaseInsensitiveCompare("cue") == .orderedSame }),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CueSidecar(text: text)
    }

    private func channelLayout(from track: LocalMusicTrack) -> String? {
        let candidates = [track.layoutName, track.channelSummary, track.channelText]
        for candidate in candidates {
            if let match = Self.firstMatch(in: candidate, pattern: #"\b(?:Atmos|Auro|Quad|[0-9]+(?:\.[0-9]+){1,2})\b"#) {
                return normalizedEditionToken(match)
            }
        }
        return nil
    }

    private func normalizedEditionToken(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.localizedCaseInsensitiveCompare("blu ray") == .orderedSame ||
            normalized.localizedCaseInsensitiveCompare("bluray") == .orderedSame {
            return "Blu-Ray"
        }
        if normalized.localizedCaseInsensitiveCompare("dvd audio") == .orderedSame ||
            normalized.localizedCaseInsensitiveCompare("dvda") == .orderedSame {
            return "DVD-Audio"
        }
        return normalized
    }

    private static func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              let swiftRange = Range(match.range, in: value)
        else { return nil }
        return String(value[swiftRange]).trimmedNilIfBlank
    }
}

struct LocalMusicAlbumEditionContext: Sendable {
    var artist: String?
    var canonicalAlbum: String?
    var editionTokens: [String] = []
    var sourceMedium: String?
    var channelLayout: String?
    var year: String?
    var sourceNames: [String] = []
    var trackTitlesByFilename: [String: String] = [:]
    var trackTitlesByNumber: [Int: String] = [:]
    var trackNumbersByFilename: [String: Int] = [:]

    init(folderName: String) {
        parseFolderName(folderName)
    }

    var sourceName: String {
        sourceNames.isEmpty ? "LocalFolder" : "LocalSidecar+\(sourceNames.joined(separator: "+"))"
    }

    var sourceIdentifier: String? {
        [canonicalAlbum, sourceMedium, channelLayout]
            .compactMap { $0?.trimmedNilIfBlank }
            .joined(separator: "|")
            .trimmedNilIfBlank
    }

    var confidence: Double {
        sourceNames.isEmpty ? 0.90 : 0.98
    }

    var hasTrustedLocalContext: Bool {
        !sourceNames.isEmpty || !displayEditionSuffix.isEmpty
    }

    var displayAlbum: String? {
        guard let canonicalAlbum else { return nil }
        let suffix = displayEditionSuffix
        guard !suffix.isEmpty else { return canonicalAlbum }
        return "\(canonicalAlbum) - \(suffix)"
    }

    var displayEditionSuffix: String {
        var parts: [String] = []
        let tokenText = editionTokens.joined(separator: " ")
        if let sourceMedium,
           tokenText.range(of: sourceMedium, options: [.caseInsensitive]) == nil {
            parts.append(sourceMedium)
        }
        parts.append(contentsOf: editionTokens)
        if let channelLayout,
           !parts.contains(where: { $0.range(of: channelLayout, options: [.caseInsensitive]) != nil }) {
            parts.append(channelLayout)
        }
        return Self.unique(parts).joined(separator: " ")
    }

    func trackTitle(for track: LocalMusicTrack) -> String? {
        let filename = track.fileName
        if let byFilename = trackTitlesByFilename[filename]?.trimmedNilIfBlank {
            return byFilename
        }
        if let number = trackNumber(for: track),
           let byNumber = trackTitlesByNumber[number]?.trimmedNilIfBlank {
            return byNumber
        }
        return Self.cleanTrackTitle(from: filename)
    }

    func trackNumber(for track: LocalMusicTrack) -> Int? {
        let filename = track.fileName
        if let byFilename = trackNumbersByFilename[filename] {
            return byFilename
        }
        if let byFileNamePrefix = LocalMusicTrack.trackNumber(fromFileName: filename) {
            return byFileNamePrefix
        }
        if trackTitlesByNumber.count == 1 {
            return trackTitlesByNumber.keys.first
        }
        return nil
    }

    func discNumber(for track: LocalMusicTrack) -> Int? {
        LocalMusicTrack.discNumber(
            fromFileName: track.fileName,
            parentFolderName: track.url.deletingLastPathComponent().lastPathComponent
        )
    }

    mutating func finalize() {
        artist = artist?.trimmedNilIfBlank
        canonicalAlbum = canonicalAlbum?.trimmedNilIfBlank
        sourceMedium = sourceMedium?.trimmedNilIfBlank
        channelLayout = channelLayout?.trimmedNilIfBlank
        editionTokens = Self.unique(editionTokens.compactMap { Self.cleanEditionToken($0) })
        if let sourceMedium {
            editionTokens.removeAll { $0.caseInsensitiveCompare(sourceMedium) == .orderedSame }
        }
    }

    private mutating func parseFolderName(_ folderName: String) {
        let components = folderName
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if components.count >= 2 {
            artist = components[0]
            parseAlbumAndEdition(components.dropFirst().joined(separator: " - "))
        } else {
            parseAlbumAndEdition(folderName)
        }
    }

    private mutating func parseAlbumAndEdition(_ rawValue: String) {
        var working = rawValue
        let bracketMatches = Self.matches(in: rawValue, pattern: #"\(([^\)]*)\)|\[([^\]]*)\]|\{([^\}]*)\}"#)
        for match in bracketMatches {
            let value = match.trimmedNilIfBlank ?? ""
            let unwrapped = value
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let yearMatch = Self.firstMatch(in: unwrapped, pattern: #"^(19|20)\d{2}$"#) {
                year = year ?? yearMatch
            } else if unwrapped.localizedCaseInsensitiveCompare("SPECIAL") != .orderedSame {
                editionTokens.append(contentsOf: Self.editionTokens(from: unwrapped))
            }
            working = working.replacingOccurrences(of: value, with: "")
        }

        let hyphenParts = working
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = hyphenParts.first {
            canonicalAlbum = Self.cleanAlbumTitle(first)
        }
        if hyphenParts.count > 1 {
            editionTokens.append(contentsOf: hyphenParts.dropFirst().flatMap { Self.editionTokens(from: $0) })
        }
        inferSourceAndChannel()
    }

    private mutating func inferSourceAndChannel() {
        let allTokens = editionTokens.joined(separator: " ")
        if allTokens.range(of: #"DVD[\s-]?Audio|DVDA"#, options: [.regularExpression, .caseInsensitive]) != nil {
            sourceMedium = "DVD-Audio"
        }
        if allTokens.range(of: #"Blu[\s-]?Ray|Bluray"#, options: [.regularExpression, .caseInsensitive]) != nil {
            sourceMedium = "Blu-Ray"
        }
        if let match = Self.firstMatch(in: allTokens, pattern: #"\b(?:Atmos|Auro|Quad|[0-9]+(?:\.[0-9]+){1,2})\b"#) {
            channelLayout = match
        }
    }

    private static func cleanAlbumTitle(_ value: String) -> String? {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmedNilIfBlank
    }

    private static func cleanTrackTitle(from filename: String) -> String? {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: #"^\s*\d{1,3}\s*[-._ ]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmedNilIfBlank
    }

    static func firstYear(in value: String) -> String? {
        firstMatch(in: value, pattern: #"\b((?:19|20)\d{2})\b"#)
    }

    private static func editionTokens(from value: String) -> [String] {
        let cleaned = value
            .replacingOccurrences(of: #"\b(?:FLAC|ALAC|WAV|MKA|MKV|SPECIAL|16\.44|24\.96|24bit|bit)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return [cleaned]
    }

    private static func cleanEditionToken(_ value: String) -> String? {
        let cleaned = value
            .replacingOccurrences(of: #"(?i)\bblu[\s-]?ray\b"#, with: "Blu-Ray", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bdvd[\s-]?audio\b|\bdvda\b"#, with: "DVD-Audio", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.trimmedNilIfBlank
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private static func matches(in value: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange])
        }
    }

    private static func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else { return nil }
        let selectedRange = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
            ? match.range(at: 1)
            : match.range
        guard let swiftRange = Range(selectedRange, in: value) else { return nil }
        return String(value[swiftRange]).trimmedNilIfBlank
    }
}

private struct ManifestSidecar: Decodable {
    let album: String?
    let artist: String?
    let albumArtist: String?
    let date: String?
    let tracks: [TrackEntry]

    enum CodingKeys: String, CodingKey {
        case album
        case artist
        case albumArtist = "album_artist"
        case date
        case tracks
    }

    var year: String? {
        date.flatMap { LocalMusicAlbumEditionContext.firstYear(in: $0) }
    }

    var trackTitlesByNumber: [Int: String] {
        Dictionary(uniqueKeysWithValues: tracks.compactMap { entry in
            guard let title = entry.title?.trimmedNilIfBlank else { return nil }
            return (entry.track, title)
        })
    }

    struct TrackEntry: Decodable {
        let track: Int
        let title: String?
    }
}

private struct RipReportSidecar: Decodable {
    let app: String?
    let metadata: Metadata?
    let tracks: [TrackEntry]

    var album: String? { metadata?.album }
    var artist: String? { metadata?.albumArtist ?? metadata?.artist }
    var year: String? { metadata?.date.flatMap { LocalMusicAlbumEditionContext.firstYear(in: $0) } }

    var sourceMedium: String? {
        if app?.range(of: "dvda", options: .caseInsensitive) != nil {
            return "DVD-Audio"
        }
        return nil
    }

    var channelLayout: String? {
        tracks
            .lazy
            .compactMap { $0.ffprobe?.streams.first?.channelLayout?.trimmedNilIfBlank }
            .first
    }

    var trackTitlesByFilename: [String: String] {
        Dictionary(uniqueKeysWithValues: tracks.compactMap { entry in
            guard let output = entry.output?.trimmedNilIfBlank,
                  let title = entry.title?.trimmedNilIfBlank
            else { return nil }
            return (output, title)
        })
    }

    var trackNumbersByFilename: [String: Int] {
        Dictionary(uniqueKeysWithValues: tracks.compactMap { entry in
            guard let output = entry.output?.trimmedNilIfBlank else { return nil }
            return (output, entry.track)
        })
    }

    var trackTitlesByNumber: [Int: String] {
        Dictionary(uniqueKeysWithValues: tracks.compactMap { entry in
            guard let title = entry.title?.trimmedNilIfBlank else { return nil }
            return (entry.track, title)
        })
    }

    struct Metadata: Decodable {
        let album: String?
        let artist: String?
        let albumArtist: String?
        let date: String?

        enum CodingKeys: String, CodingKey {
            case album
            case artist
            case albumArtist = "album_artist"
            case date
        }
    }

    struct TrackEntry: Decodable {
        let track: Int
        let title: String?
        let output: String?
        let ffprobe: FFProbe?
    }

    struct FFProbe: Decodable {
        let streams: [Stream]
    }

    struct Stream: Decodable {
        let channelLayout: String?

        enum CodingKeys: String, CodingKey {
            case channelLayout = "channel_layout"
        }
    }
}

private struct CueSidecar: Sendable {
    let artist: String?
    let album: String?
    let year: String?
    let trackTitlesByFilename: [String: String]
    let trackTitlesByNumber: [Int: String]
    let trackNumbersByFilename: [String: Int]

    init(text: String) {
        var albumArtist: String?
        var albumTitle: String?
        var date: String?
        var currentFile: String?
        var currentTrack: Int?
        var titlesByFilename: [String: String] = [:]
        var titlesByNumber: [Int: String] = [:]
        var numbersByFilename: [String: Int] = [:]
        var insideTrack = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("REM DATE ") {
                date = Self.quotedValue(in: trimmed) ?? trimmed.replacingOccurrences(of: "REM DATE ", with: "")
            } else if trimmed.hasPrefix("FILE ") {
                currentFile = Self.quotedValue(in: trimmed)
                insideTrack = false
                currentTrack = nil
            } else if trimmed.hasPrefix("TRACK ") {
                insideTrack = true
                currentTrack = Int(trimmed.components(separatedBy: .whitespaces).dropFirst().first ?? "")
            } else if trimmed.hasPrefix("PERFORMER ") {
                let value = Self.quotedValue(in: trimmed)
                if !insideTrack {
                    albumArtist = value
                }
            } else if trimmed.hasPrefix("TITLE ") {
                let value = Self.quotedValue(in: trimmed)
                if insideTrack {
                    if let currentFile, let value {
                        titlesByFilename[currentFile] = value
                    }
                    if let currentTrack, let value {
                        titlesByNumber[currentTrack] = value
                    }
                    if let currentFile, let currentTrack {
                        numbersByFilename[currentFile] = currentTrack
                    }
                } else {
                    albumTitle = value
                }
            }
        }

        artist = albumArtist
        album = albumTitle
        year = date.flatMap { LocalMusicAlbumEditionContext.firstYear(in: $0) }
        trackTitlesByFilename = titlesByFilename
        trackTitlesByNumber = titlesByNumber
        trackNumbersByFilename = numbersByFilename
    }

    private static func quotedValue(in line: String) -> String? {
        guard let firstQuote = line.firstIndex(of: "\""),
              let lastQuote = line.lastIndex(of: "\""),
              firstQuote != lastQuote
        else { return nil }
        return String(line[line.index(after: firstQuote)..<lastQuote]).trimmedNilIfBlank
    }
}

final class MusicBrainzLocalMusicMetadataLookupClient: LocalMusicMetadataLookupClient, @unchecked Sendable {
    private let session: URLSession
    private let userAgent: String

    init(
        session: URLSession = .shared,
        userAgent: String = "Orbisonic/1.1 (local macOS app)"
    ) {
        self.session = session
        self.userAgent = userAgent
    }

    func lookup(track: LocalMusicTrack) async throws -> LocalMusicMetadataLookupResult? {
        guard let query = musicBrainzQuery(for: track) else { return nil }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "inc", value: "artist-credits+releases")
        ]
        guard let url = components?.url else { return nil }

        let response: MusicBrainzRecordingSearchResponse = try await decodedJSON(from: url)
        guard let match = bestMatch(in: response.recordings, for: track) else { return nil }
        let release = preferredRelease(in: match.releases)
        let artist = match.artistCredit?
            .compactMap { $0.name?.trimmedNilIfBlank }
            .joined(separator: ", ")
            .trimmedNilIfBlank
        let album = release?.title?.trimmedNilIfBlank
        let confidence = confidence(for: match, track: track, hasRelease: release != nil)

        var artworkData: Data?
        var artworkURL: URL?
        if track.artworkPath?.trimmedNilIfBlank == nil,
           let releaseID = release?.id?.trimmedNilIfBlank,
           let cover = try? await coverArtURL(releaseID: releaseID) {
            artworkURL = cover
            artworkData = try? await data(from: cover, accept: nil)
        }

        let overlay = LocalMusicMetadataOverlay(
            title: track.title?.trimmedNilIfBlank == nil ? match.title?.trimmedNilIfBlank : nil,
            artist: track.artist?.trimmedNilIfBlank == nil ? artist : nil,
            album: track.album?.trimmedNilIfBlank == nil ? album : nil,
            artworkPath: nil,
            sourceName: "MusicBrainz",
            sourceIdentifier: match.id,
            confidence: confidence
        )

        guard overlay.hasDisplayValue || artworkData != nil else { return nil }
        return LocalMusicMetadataLookupResult(
            overlay: overlay,
            artworkData: artworkData,
            artworkSourceURL: artworkURL
        )
    }

    private func musicBrainzQuery(for track: LocalMusicTrack) -> String? {
        let title = track.title?.trimmedNilIfBlank ?? track.fallbackTitle.trimmedNilIfBlank
        guard let title, title.count >= 3 else { return nil }

        var terms = ["recording:\"\(luceneEscaped(title))\""]
        if let artist = track.artist?.trimmedNilIfBlank {
            terms.append("artist:\"\(luceneEscaped(artist))\"")
        }
        if let album = track.album?.trimmedNilIfBlank {
            terms.append("release:\"\(luceneEscaped(album))\"")
        }
        return terms.joined(separator: " AND ")
    }

    private func bestMatch(
        in recordings: [MusicBrainzRecording],
        for track: LocalMusicTrack
    ) -> MusicBrainzRecording? {
        recordings
            .filter { confidence(for: $0, track: track, hasRelease: preferredRelease(in: $0.releases) != nil) >= LocalMusicMetadataOverlay.minimumAutomaticConfidence }
            .sorted { lhs, rhs in
                confidence(for: lhs, track: track, hasRelease: preferredRelease(in: lhs.releases) != nil) >
                    confidence(for: rhs, track: track, hasRelease: preferredRelease(in: rhs.releases) != nil)
            }
            .first
    }

    private func preferredRelease(in releases: [MusicBrainzRelease]?) -> MusicBrainzRelease? {
        releases?.sorted { lhs, rhs in
            let lhsFront = lhs.coverArtArchive?.front == true
            let rhsFront = rhs.coverArtArchive?.front == true
            if lhsFront != rhsFront { return lhsFront }
            return (lhs.title ?? "").localizedStandardCompare(rhs.title ?? "") == .orderedAscending
        }.first
    }

    private func confidence(for recording: MusicBrainzRecording, track: LocalMusicTrack, hasRelease: Bool) -> Double {
        var score = Double(recording.score ?? 0) / 100.0
        let hasEmbeddedArtist = track.artist?.trimmedNilIfBlank != nil
        let hasEmbeddedAlbum = track.album?.trimmedNilIfBlank != nil
        let usingFallbackTitle = track.title?.trimmedNilIfBlank == nil

        if usingFallbackTitle && !hasEmbeddedArtist && !hasEmbeddedAlbum {
            score -= 0.12
        }
        if !hasRelease {
            score -= 0.04
        }
        if let length = recording.length, track.duration > 0 {
            let recordingSeconds = Double(length) / 1_000
            if abs(recordingSeconds - track.duration) > 8 {
                score -= 0.08
            }
        }

        return max(0, min(1, score))
    }

    private func coverArtURL(releaseID: String) async throws -> URL? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/") else { return nil }
        let response: CoverArtArchiveResponse = try await decodedJSON(from: url)
        return response.images
            .filter { $0.front == true || $0.types.contains(where: { $0.localizedCaseInsensitiveCompare("Front") == .orderedSame }) }
            .compactMap { image in
                image.thumbnails?["500"] ?? image.thumbnails?["large"] ?? image.thumbnails?["250"] ?? image.thumbnails?["small"] ?? image.image
            }
            .compactMap(URL.init(string:))
            .first
    }

    private func decodedJSON<T: Decodable>(from url: URL) async throws -> T {
        let data = try await data(from: url, accept: "application/json")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func data(from url: URL, accept: String?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func luceneEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

final class AppleITunesLocalMusicMetadataLookupClient: LocalMusicMetadataLookupClient, @unchecked Sendable {
    private let session: URLSession
    private let country: String
    private let userAgent: String

    init(
        session: URLSession = .shared,
        country: String = "us",
        userAgent: String = "Orbisonic/1.1 (local macOS app)"
    ) {
        self.session = session
        self.country = country
        self.userAgent = userAgent
    }

    func lookup(track: LocalMusicTrack) async throws -> LocalMusicMetadataLookupResult? {
        for query in searchQueries(for: track) {
            if let result = try await lookup(track: track, query: query) {
                return result
            }
        }
        return nil
    }

    private func lookup(track: LocalMusicTrack, query: String) async throws -> LocalMusicMetadataLookupResult? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: country)
        ]
        guard let url = components?.url else { return nil }
        let response: AppleSearchResponse = try await decodedJSON(from: url)
        guard let match = bestMatch(in: response.results, for: track) else { return nil }

        var artworkURL = match.artworkURL
        if let urlString = artworkURL?.absoluteString {
            let larger = urlString
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
                .replacingOccurrences(of: "100x100-999", with: "600x600-999")
            artworkURL = URL(string: larger) ?? artworkURL
        }
        let artworkData: Data?
        if let artworkURL {
            artworkData = try? await data(from: artworkURL, accept: nil)
        } else {
            artworkData = nil
        }
        let confidence = confidence(for: match, track: track)

        let overlay = LocalMusicMetadataOverlay(
            title: nil,
            artist: track.artist?.trimmedNilIfBlank == nil ? match.artistName : nil,
            album: track.album?.trimmedNilIfBlank == nil ? match.collectionName : nil,
            sourceName: "Apple",
            sourceIdentifier: match.collectionID.map(String.init),
            confidence: confidence
        )
        guard overlay.hasDisplayValue || artworkData != nil else { return nil }
        return LocalMusicMetadataLookupResult(
            overlay: overlay,
            artworkData: artworkData,
            artworkSourceURL: artworkURL
        )
    }

    private func searchQueries(for track: LocalMusicTrack) -> [String] {
        var queries: [String] = []
        let artist = track.artist?.trimmedNilIfBlank
        let album = track.album?.trimmedNilIfBlank
        let title = track.title?.trimmedNilIfBlank ?? track.fallbackTitle.trimmedNilIfBlank

        if let artist, let album {
            queries.append("\(artist) \(album)")
        }
        if let album {
            queries.append(album)
        }
        let trackSpecific = [artist, album, title]
            .compactMap { $0?.trimmedNilIfBlank }
            .joined(separator: " ")
            .trimmedNilIfBlank
        if let trackSpecific {
            queries.append(trackSpecific)
        }

        var seen = Set<String>()
        return queries.compactMap { query in
            let normalized = normalized(query)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return query
        }
    }

    private func bestMatch(
        in results: [AppleAlbumResult],
        for track: LocalMusicTrack
    ) -> AppleAlbumResult? {
        results
            .filter { confidence(for: $0, track: track) >= LocalMusicMetadataOverlay.minimumAutomaticConfidence }
            .sorted { confidence(for: $0, track: track) > confidence(for: $1, track: track) }
            .first
    }

    private func confidence(for result: AppleAlbumResult, track: LocalMusicTrack) -> Double {
        let expectedAlbum = normalized(track.album)
        let expectedArtist = normalized(track.artist)
        let resultAlbum = normalized(result.collectionName)
        let resultArtist = normalized(result.artistName)

        var score = 0.0
        if !expectedAlbum.isEmpty, expectedAlbum == resultAlbum {
            score += 0.62
        } else if !expectedAlbum.isEmpty,
                  (expectedAlbum.contains(resultAlbum) || resultAlbum.contains(expectedAlbum)),
                  min(expectedAlbum.count, resultAlbum.count) >= 6 {
            score += 0.48
        }
        if !expectedArtist.isEmpty, expectedArtist == resultArtist {
            score += 0.34
        } else if expectedArtist.isEmpty {
            score += 0.18
        }
        if result.artworkURL != nil {
            score += 0.06
        }
        return min(score, 1.0)
    }

    private func normalized(_ value: String?) -> String {
        value?
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:the|a|an|remastered|anniversary|edition|special|deluxe|stereo|mono)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func decodedJSON<T: Decodable>(from url: URL) async throws -> T {
        let data = try await data(from: url, accept: "application/json")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func data(from url: URL, accept: String?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

private struct AppleSearchResponse: Decodable {
    let results: [AppleAlbumResult]
}

private struct AppleAlbumResult: Decodable {
    let collectionID: Int?
    let artistName: String?
    let collectionName: String?
    let artworkUrl100: String?

    var artworkURL: URL? {
        artworkUrl100.flatMap(URL.init(string:))
    }

    enum CodingKeys: String, CodingKey {
        case collectionID = "collectionId"
        case artistName
        case collectionName
        case artworkUrl100
    }
}

private struct MusicBrainzRecordingSearchResponse: Decodable {
    let recordings: [MusicBrainzRecording]
}

private struct MusicBrainzRecording: Decodable {
    let id: String?
    let title: String?
    let score: Int?
    let length: Int?
    let artistCredit: [MusicBrainzArtistCredit]?
    let releases: [MusicBrainzRelease]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case score
        case length
        case artistCredit = "artist-credit"
        case releases
    }
}

private struct MusicBrainzArtistCredit: Decodable {
    let name: String?
}

private struct MusicBrainzRelease: Decodable {
    let id: String?
    let title: String?
    let coverArtArchive: MusicBrainzCoverArtArchive?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case coverArtArchive = "cover-art-archive"
    }
}

private struct MusicBrainzCoverArtArchive: Decodable {
    let artwork: Bool?
    let front: Bool?
}

private struct CoverArtArchiveResponse: Decodable {
    let images: [CoverArtArchiveImage]
}

private struct CoverArtArchiveImage: Decodable {
    let image: String?
    let thumbnails: [String: String]?
    let types: [String]
    let front: Bool?
}
