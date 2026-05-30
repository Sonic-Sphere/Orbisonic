import AppKit
import Darwin
import Foundation
import Network

private enum OrbisonicWebConstants {
    static let port: UInt16 = 37_943
    static let basePath = "/Orbisonic"
}

#if DEBUG
extension OrbisonicWebServer {
    static var publicPageJSForTesting: String {
        publicPageJS
    }
}
#endif

struct OrbisonicWebURLSet: Equatable {
    let publicURL: String
    let controlURL: String
}

private enum OrbisonicWebID {
    static func stableID(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private struct OrbisonicWebRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var token: String? {
        if let headerToken = headers["x-orbisonic-token"], !headerToken.isEmpty {
            return headerToken
        }

        if let auth = headers["authorization"],
           auth.localizedCaseInsensitiveContains("bearer ") {
            return auth.split(separator: " ").last.map(String.init)
        }

        return query["token"]
    }
}

private struct OrbisonicWebCommandPayload: Decodable {
    var action: String?
    var id: String?
    var value: String?
    var query: String?
    var sort: String?
    var channels: Int?
    var index: Int?
    var seconds: Int?
    var shuffle: Bool?
}

private struct OrbisonicWebCommandResponse: Encodable {
    let ok: Bool
    let message: String
    let state: OrbisonicWebState?
}

struct OrbisonicWebState: Encodable {
    struct URLs: Encodable {
        let publicPage: String
        let controlPage: String?
    }

    struct Player: Encodable {
        let title: String
        let subtitle: String
        let artist: String
        let album: String
        let source: String
        let sourceName: String
        let status: String
        let isPlaying: Bool
        let hasMedia: Bool
        let artworkURL: String?
        let outputChannels: String
        let volume: Int
        let currentTime: String
        let duration: String
        let progress: Double
        let details: [Detail]
        let controls: [String]
        let enabledControls: [String]
    }

    struct Detail: Encodable {
        let title: String
        let value: String
    }

    struct Route: Encodable {
        let id: String
        let name: String
        let detail: String
        let isSelected: Bool
        let isSelectable: Bool
    }

    struct SourceButton: Encodable {
        let value: String
        let title: String
        let subtitle: String
        let isSelected: Bool
        let severity: String
    }

    struct SourcePanel: Encodable {
        let title: String
        let status: String
        let headline: String
        let body: String
        let rows: [Detail]
        let severity: String
        let isSwitching: Bool
    }

    struct Input: Encodable {
        let source: String
        let selectedDevice: String
        let status: String
        let monitorState: String
        let availableSources: [String]
        let availableInputs: [Route]
        let sourceButtons: [SourceButton]
        let sourcePanel: SourcePanel
    }

    struct Routing: Encodable {
        let source: String
        let incoming: String
        let monitorOutput: String
        let monitorStatus: String
        let rendererOutput: String
        let rendererStatus: String
        let rendererScene: String
        let monitorOptions: [Route]
        let rendererOptions: [Route]
    }

    struct LocalMusic: Encodable {
        let search: String
        let sort: String
        let channelFilter: Int
        let availableChannelCounts: [Int]
        let count: String
        let queue: String
        let tracks: [Track]
        let playlists: [Playlist]
        let sessionQueue: [QueueItem]
    }

    struct Track: Encodable {
        let id: String
        let title: String
        let subtitle: String
        let album: String
        let artist: String
        let channels: String
        let duration: String
        let isSelected: Bool
        let isCurrent: Bool
        let isPending: Bool
    }

    struct Playlist: Encodable {
        let id: String
        let name: String
        let fileName: String
        let trackCount: Int
        let isSelected: Bool
    }

    struct QueueItem: Encodable {
        let index: Int
        let title: String
        let subtitle: String
        let channels: String
        let isSelected: Bool
        let isCurrent: Bool
        let isPending: Bool
    }

    struct Diagnostics: Encodable {
        let active: String
        let toneStatus: String
        let monitorChannelCount: Int
        let rendererChannelCount: Int
        let isRunning: Bool
        let isTransitioning: Bool
        let selectedChannel: Int
        let availableTests: [String]
    }

    struct Build: Encodable {
        let webServer: String
        let appStatus: String
        let lastError: String?
        let appVersion: String
        let buildNumber: String
        let machineIP: String
    }

    struct Activity: Encodable {
        let phase: String
        let label: String
        let isBusy: Bool
        let isIndeterminate: Bool
        let progress: Double?
    }

    let generatedAt: String
    let controlEnabled: Bool
    let activity: Activity
    let urls: URLs
    let player: Player
    let input: Input
    let routing: Routing
    let localMusic: LocalMusic?
    let diagnostics: Diagnostics
    let build: Build
}

final class OrbisonicWebServer {
    private weak var model: OrbisonicViewModel?
    private var controlToken: String
    private let controlTokenLock = NSLock()
    private let queue = DispatchQueue(label: "orbisonic.web-server")
    private var listener: NWListener?
    private let statusHandler: @MainActor (String) -> Void

    init(
        model: OrbisonicViewModel,
        controlToken: String,
        statusHandler: @escaping @MainActor (String) -> Void
    ) {
        self.model = model
        self.controlToken = controlToken
        self.statusHandler = statusHandler
    }

    func updateControlToken(_ token: String) {
        controlTokenLock.lock()
        controlToken = token
        controlTokenLock.unlock()
    }

    static var controlPageURL: String {
        let host = preferredLANHost()
        return "http://\(host):\(OrbisonicWebConstants.port)\(OrbisonicWebConstants.basePath)/control"
    }

    static func urlSet(controlToken: String) -> OrbisonicWebURLSet {
        let host = preferredLANHost()
        let baseURL = "http://\(host):\(OrbisonicWebConstants.port)\(OrbisonicWebConstants.basePath)"
        return OrbisonicWebURLSet(
            publicURL: "\(baseURL)/",
            controlURL: "\(baseURL)/control"
        )
    }

    func start() {
        do {
            let port = NWEndpoint.Port(rawValue: OrbisonicWebConstants.port)!
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Task { @MainActor [statusHandler] in
                statusHandler("Web server unavailable on port \(OrbisonicWebConstants.port): \(error.localizedDescription)")
            }
            AppLogger.shared.error(category: "web", "Web server failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleListenerState(_ state: NWListener.State) {
        let message: String
        switch state {
        case .ready:
            message = "Web pages listening on port \(OrbisonicWebConstants.port)."
            AppLogger.shared.notice(category: "web", message)
        case .failed(let error):
            message = "Web server failed: \(error.localizedDescription)"
            AppLogger.shared.error(category: "web", message)
        case .cancelled:
            message = "Web server stopped."
        case .waiting(let error):
            message = "Web server waiting: \(error.localizedDescription)"
        default:
            message = "Web server starting."
        }

        Task { @MainActor [statusHandler] in
            statusHandler(message)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let error {
                AppLogger.shared.warning(category: "web", "HTTP receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let request = Self.parseRequest(nextBuffer) {
                self.respond(to: request, on: connection)
                return
            }

            if isComplete {
                self.send(status: 400, contentType: "text/plain; charset=utf-8", body: "Bad request", on: connection)
            } else {
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func respond(to request: OrbisonicWebRequest, on connection: NWConnection) {
        if request.method == "OPTIONS" {
            send(status: 204, contentType: "text/plain; charset=utf-8", body: "", on: connection)
            return
        }

        if request.method == "GET", isPublicPagePath(request.path) {
            send(status: 200, contentType: "text/html; charset=utf-8", body: Self.publicPageHTML, on: connection)
            return
        }

        if request.method == "GET",
           request.path == "\(OrbisonicWebConstants.basePath)/control"
            || request.path == "\(OrbisonicWebConstants.basePath)/control/" {
            controlTokenLock.lock()
            let token = controlToken
            controlTokenLock.unlock()
            send(status: 200, contentType: "text/html; charset=utf-8", body: Self.controlPageHTML(token: token), on: connection)
            return
        }

        if request.method == "GET", request.path == "\(OrbisonicWebConstants.basePath)/api/public-state" {
            Task { @MainActor [weak self] in
                guard let self, let model else { return }
                let state = model.makeWebState(controlEnabled: false)
                self.sendJSON(state, on: connection)
            }
            return
        }

        if request.method == "GET", request.path == "\(OrbisonicWebConstants.basePath)/api/artwork/current" {
            Task { @MainActor [weak self] in
                guard let self, let artworkURL = model?.webCurrentArtworkURL else {
                    self?.send(status: 404, contentType: "text/plain; charset=utf-8", body: "Artwork unavailable", on: connection)
                    return
                }

                Task.detached { [weak self] in
                    guard let self else { return }
                    do {
                        let data = try Data(contentsOf: artworkURL)
                        let contentType = Self.artworkContentType(for: artworkURL, data: data)
                        self.send(status: 200, contentType: contentType, bodyData: data, on: connection)
                    } catch {
                        self.send(status: 404, contentType: "text/plain; charset=utf-8", body: "Artwork unavailable", on: connection)
                    }
                }
            }
            return
        }

        guard request.path.hasPrefix("\(OrbisonicWebConstants.basePath)/api/") else {
            sendJSON(OrbisonicWebCommandResponse(ok: false, message: "Not found.", state: nil), status: 404, on: connection)
            return
        }

        guard isValidControlToken(request.token) else {
            sendJSON(OrbisonicWebCommandResponse(ok: false, message: "Control token required.", state: nil), status: 401, on: connection)
            return
        }

        if request.method == "GET", request.path == "\(OrbisonicWebConstants.basePath)/api/state" {
            Task { @MainActor [weak self] in
                guard let self, let model else { return }
                self.sendJSON(model.makeWebState(controlEnabled: true), on: connection)
            }
            return
        }

        if request.method == "POST" {
            let payload = (try? JSONDecoder().decode(OrbisonicWebCommandPayload.self, from: request.body)) ?? OrbisonicWebCommandPayload()
            Task { @MainActor [weak self] in
                guard let self, let model else { return }
                do {
                    let state = try model.performWebCommand(path: request.path, payload: payload)
                    self.sendJSON(OrbisonicWebCommandResponse(ok: true, message: model.statusMessage, state: state), on: connection)
                } catch {
                    self.sendJSON(
                        OrbisonicWebCommandResponse(ok: false, message: error.localizedDescription, state: model.makeWebState(controlEnabled: true)),
                        status: 400,
                        on: connection
                    )
                }
            }
            return
        }

        sendJSON(OrbisonicWebCommandResponse(ok: false, message: "Unsupported method.", state: nil), status: 405, on: connection)
    }

    private func isPublicPagePath(_ path: String) -> Bool {
        path == "/" ||
            path == OrbisonicWebConstants.basePath ||
            path == "\(OrbisonicWebConstants.basePath)/" ||
            path == "\(OrbisonicWebConstants.basePath)/public" ||
            path == "\(OrbisonicWebConstants.basePath)/public/"
    }

    private func isValidControlToken(_ token: String?) -> Bool {
        controlTokenLock.lock()
        let expectedToken = controlToken
        controlTokenLock.unlock()

        return token == expectedToken
    }

    private func sendJSON<T: Encodable>(_ value: T, status: Int = 200, on connection: NWConnection) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            send(status: status, contentType: "application/json; charset=utf-8", bodyData: data, on: connection)
        } catch {
            send(status: 500, contentType: "text/plain; charset=utf-8", body: "JSON encode failed", on: connection)
        }
    }

    private func send(status: Int, contentType: String, body: String, on connection: NWConnection) {
        let data = Data(body.utf8)
        send(status: status, contentType: contentType, bodyData: data, on: connection)
    }

    private func send(status: Int, contentType: String, bodyData: Data, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: status)
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type, X-Orbisonic-Token, Authorization",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var responseData = Data(headers.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(_ data: Data) -> OrbisonicWebRequest? {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerEndRange.lowerBound], encoding: .utf8)
        else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEndRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let target = parts[1]
        let splitTarget = target.split(separator: "?", maxSplits: 1).map(String.init)
        let rawPath = splitTarget.first ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath
        let query = splitTarget.count > 1 ? parseQuery(splitTarget[1]) : [:]
        let body = data[bodyStart..<(bodyStart + contentLength)]

        return OrbisonicWebRequest(
            method: parts[0].uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: Data(body)
        )
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding, !key.isEmpty else { continue }
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
            result[key] = value
        }
        return result
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Server Error"
        }
    }

    private static func artworkContentType(for url: URL, data: Data) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "png" || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        return "image/jpeg"
    }

    private static func preferredLANHost() -> String {
        preferredIPv4Address() ?? "127.0.0.1"
    }

    private static func preferredIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0
            else { continue }

            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let result = inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            guard result != nil else { continue }
            let ip = String(cString: buffer)
            guard !ip.hasPrefix("169.254.") else { continue }

            let name = current.pointee.ifa_name.map { String(cString: $0) } ?? ""
            if name == "en0" || name == "en1" {
                return ip
            }
            fallback = fallback ?? ip
        }

        return fallback
    }
}

@MainActor
extension OrbisonicViewModel {
    fileprivate func makeWebState(controlEnabled: Bool) -> OrbisonicWebState {
        OrbisonicWebState(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            controlEnabled: controlEnabled,
            activity: OrbisonicWebState.Activity(
                phase: activity.phase.rawValue,
                label: activity.label,
                isBusy: activity.isBusy,
                isIndeterminate: activity.isIndeterminate,
                progress: activity.clampedProgress
            ),
            urls: OrbisonicWebState.URLs(
                publicPage: self.webPublicPageURL,
                controlPage: controlEnabled ? OrbisonicWebServer.controlPageURL : nil
            ),
            player: makeWebPlayerState(controlEnabled: controlEnabled),
            input: controlEnabled ? makeWebInputState() : makeWebPublicInputState(),
            routing: controlEnabled ? makeWebRoutingState() : makeWebPublicRoutingState(),
            localMusic: controlEnabled ? makeWebLocalMusicState() : nil,
            diagnostics: controlEnabled ? makeWebDiagnosticsState() : makeWebPublicDiagnosticsState(),
            build: controlEnabled ? makeWebBuildState() : makeWebPublicBuildState()
        )
    }

    func webStateForTesting(controlEnabled: Bool) -> OrbisonicWebState {
        makeWebState(controlEnabled: controlEnabled)
    }

    fileprivate func performWebCommand(path: String, payload: OrbisonicWebCommandPayload) throws -> OrbisonicWebState {
        switch path {
        case "\(OrbisonicWebConstants.basePath)/api/player/control":
            try performWebPlayerCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/player/volume":
            try performWebVolumeCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/input/source":
            try performWebSourceCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/input/route":
            try performWebInputRouteCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/input/monitor":
            try performWebMonitorCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/routing/monitor-output":
            try performWebMonitorOutputCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/routing/renderer-output":
            try performWebRendererOutputCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/local-music/search":
            localMusicSearchText = payload.query ?? ""
            if let sort = payload.sort, let mode = PlaylistSortMode(rawValue: sort) {
                localMusicSortMode = mode
            }
            if let channels = payload.channels {
                localMusicChannelFilter = max(0, channels)
            }
        case "\(OrbisonicWebConstants.basePath)/api/local-music/track":
            try performWebTrackCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/local-music/playlist":
            try performWebPlaylistCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/local-music/queue":
            try performWebQueueCommand(payload)
        case "\(OrbisonicWebConstants.basePath)/api/local-music/rescan":
            rescanLocalMusicLibrary()
        case "\(OrbisonicWebConstants.basePath)/api/diagnostics":
            try performWebDiagnosticsCommand(payload)
        default:
            throw OrbisonicWebCommandError.unsupportedCommand
        }

        return makeWebState(controlEnabled: true)
    }

    private func makeWebPlayerState(controlEnabled: Bool) -> OrbisonicWebState.Player {
        OrbisonicWebState.Player(
            title: webNowPlayingTitle,
            subtitle: webNowPlayingSubtitle,
            artist: webNowPlayingArtist,
            album: webNowPlayingAlbum,
            source: sourceMode.rawValue,
            sourceName: webPublicSourceName,
            status: webPlayerStatus,
            isPlaying: webPlayerIsPlaying,
            hasMedia: webPlayerHasMedia,
            artworkURL: webArtworkPath,
            outputChannels: webSphereOutputChannelText,
            volume: sphereOutputVolumeValue,
            currentTime: webPlayerCurrentTime,
            duration: webPlayerDuration,
            progress: webPlayerProgress,
            details: webPlayerDetails,
            controls: webPlayerControls,
            enabledControls: webEnabledPlayerControls
        )
    }

    private var webPlayerIsPlaying: Bool {
        switch sourceMode {
        case .spotify:
            return liveAudioSignalState.isRecentlyReceiving ||
                liveMonitorState == .monitoring ||
                spotifyNowPlayingForActiveStatus?.isPlaying == true
        case .roon:
            return liveAudioSignalState.isRecentlyReceiving ||
                liveMonitorState == .monitoring
        case .aux:
            return liveAudioSignalState.isRecentlyReceiving || liveMonitorState == .monitoring
        case .atmosDRP:
            return dolbyReferencePlayerSnapshot.state == .playing ||
                liveAudioSignalState.isRecentlyReceiving ||
                liveMonitorState == .monitoring
        case .filePlayback:
            return isPlaying
        case .testTone:
            return isTestTonePlaying
        case .off:
            return false
        }
    }

    private var webPlayerHasMedia: Bool {
        switch sourceMode {
        case .off:
            return false
        case .roon:
            return roonBridgeSnapshot.selectedZone?.nowPlaying != nil || roonNowPlaying != nil
        case .spotify:
            return spotifyNowPlayingForActiveStatus != nil
        case .aux:
            return webPlayerIsPlaying
        case .atmosDRP:
            return currentAtmosDRPTrack != nil || dolbyReferencePlayerSnapshot.session != nil
        case .filePlayback:
            return visibleLocalPlaybackTrack != nil || visibleLocalSourceMetadata != nil
        case .testTone:
            return isTestTonePlaying
        }
    }

    private var webPublicSourceName: String {
        switch sourceMode {
        case .aux:
            return "Aux"
        case .atmosDRP:
            return "Atmos"
        case .filePlayback:
            return "Local Music"
        case .off:
            return "Sonic Sphere"
        case .roon:
            return "Roon"
        case .spotify:
            return "Spotify"
        case .testTone:
            return "Diagnostics"
        }
    }

    private func webPublicMetadataText(_ value: String?) -> String {
        guard let value = value?.trimmedNilIfBlank, value != "-" else { return "" }
        return value
    }

    private var webSphereOutputChannelText: String {
        let topology = rendererPreset.outputTopology
        if topology.fullRangeCount > 0, topology.lfeCount > 0 {
            return "\(topology.fullRangeCount).\(topology.lfeCount) channels"
        }
        let count = max(rendererScene.outputSpeakers.count, topology.outputCount)
        return count == 1 ? "1 channel" : "\(count) channels"
    }

    fileprivate var webCurrentArtworkURL: URL? {
        switch sourceMode {
        case .off:
            nil
        case .roon:
            roonArtworkURL
        case .spotify:
            spotifyArtworkURL
        case .filePlayback:
            currentLocalArtworkURL
        case .atmosDRP:
            currentLocalArtworkURL
        case .aux, .testTone:
            nil
        }
    }

    private var webArtworkPath: String? {
        guard let artworkURL = webCurrentArtworkURL else { return nil }
        let cacheKey = OrbisonicWebID.stableID(for: artworkURL.absoluteString)
        return "\(OrbisonicWebConstants.basePath)/api/artwork/current?v=\(cacheKey)"
    }

    private func makeWebInputState() -> OrbisonicWebState.Input {
        OrbisonicWebState.Input(
            source: sourceMode.rawValue,
            selectedDevice: inputRoute.displayName,
            status: selectedSourceDeviceStatusText,
            monitorState: webSelectedSourceStatusText,
            availableSources: SourceMode.musicInputs.map(\.rawValue),
            availableInputs: [],
            sourceButtons: webSourceButtons,
            sourcePanel: webSourcePanel
        )
    }

    private func makeWebPublicInputState() -> OrbisonicWebState.Input {
        OrbisonicWebState.Input(
            source: sourceMode.rawValue,
            selectedDevice: "",
            status: webPublicSignalText,
            monitorState: webPlayerStatus,
            availableSources: [],
            availableInputs: [],
            sourceButtons: [],
            sourcePanel: OrbisonicWebState.SourcePanel(
                title: (sourceSwitchTargetMode ?? sourceMode).displayName,
                status: webSelectedSourceStatusText,
                headline: webSelectedSourceHeadline,
                body: webSelectedSourceBody,
                rows: [],
                severity: webSourceSeverity,
                isSwitching: isLiveMonitorTransitioning
            )
        )
    }

    private var webSourceButtons: [OrbisonicWebState.SourceButton] {
        SourceMode.musicInputs.map { mode in
            OrbisonicWebState.SourceButton(
                value: mode.rawValue,
                title: mode.displayName,
                subtitle: "",
                isSelected: sourceSwitchTargetMode == mode || sourceMode == mode,
                severity: webSourceButtonSeverity(for: mode)
            )
        }
    }

    private var webSourcePanel: OrbisonicWebState.SourcePanel {
        OrbisonicWebState.SourcePanel(
            title: (sourceSwitchTargetMode ?? sourceMode).displayName,
            status: webSelectedSourceStatusText,
            headline: webSelectedSourceHeadline,
            body: webSelectedSourceBody,
            rows: webSelectedSourceRows,
            severity: webSourceSeverity,
            isSwitching: isLiveMonitorTransitioning
        )
    }

    private var webSelectedSourceStatusText: String {
        inputSourceStatusPanel.status
    }

    private var webSelectedSourceHeadline: String {
        inputSourceStatusPanel.headline
    }

    private var webSelectedSourceBody: String {
        inputSourceStatusPanel.body
    }

    private var webSelectedSourceRows: [OrbisonicWebState.Detail] {
        inputSourceStatusPanel.rows.map { row in
            OrbisonicWebState.Detail(title: row.title, value: row.value)
        }
    }

    private func webLiveInputReadyValue(expected: OrbisonicLoopbackDevice) -> String {
        inputRoute.uid == expected.deviceUID ? "Ready" : "Missing"
    }

    private var webSelectedLiveSourceUnavailable: Bool {
        guard sourceMode.isLiveInput else { return false }
        switch liveMonitorState {
        case .unavailable, .error:
            return true
        case .stopped, .monitoring, .muted, .silent:
            return false
        }
    }

    private var webSpotifyReceiverUnavailable: Bool {
        switch spotifyReceiverStatus.state {
        case .notStarted, .failed, .embeddedModuleUnavailable:
            return true
        case .waitingForConnection, .running, .restarting:
            return false
        }
    }

    private var webLiveSignalValue: String {
        switch liveMonitorState {
        case .monitoring:
            return "Present"
        case .silent, .stopped, .muted:
            return "No audio yet"
        case .unavailable, .error:
            return "No audio"
        }
    }

    private func webSourceButtonSeverity(for mode: SourceMode) -> String {
        guard sourceSwitchTargetMode == mode || sourceMode == mode else {
            return "ready"
        }
        return webSourceSeverity
    }

    private var webSourceSeverity: String {
        if isLiveMonitorTransitioning {
            return "waiting"
        }
        if sourceMode == .off {
            return "idle"
        }
        if sourceMode.isLiveInput {
            if webSelectedLiveSourceUnavailable ||
                (sourceMode == .roon && webLiveInputReadyValue(expected: .roonInput) == "Missing") ||
                (sourceMode == .spotify && (
                    webSpotifyReceiverUnavailable ||
                    webLiveInputReadyValue(expected: .spotifyInput) == "Missing"
                )) ||
                (sourceMode == .aux && webLiveInputReadyValue(expected: .auxCable) == "Missing") ||
                (sourceMode == .atmosDRP && (
                    dolbyReferencePlayerSnapshot.state == .failed ||
                    webLiveInputReadyValue(expected: AtmosDRPRoutingPolicy.captureLoopback) == "Missing"
                )) {
                return "failed"
            }
            switch liveMonitorState {
            case .monitoring:
                return "active"
            case .silent, .muted:
                return "waiting"
            case .stopped:
                return "ready"
            case .unavailable, .error:
                return "failed"
            }
        }
        return isPlaying || isTestTonePlaying ? "active" : "ready"
    }

    private func makeWebRoutingState() -> OrbisonicWebState.Routing {
        OrbisonicWebState.Routing(
            source: sourceFlowTitle,
            incoming: inputNowText,
            monitorOutput: monitorOutputSelectionText,
            monitorStatus: monitorOutputStatusText,
            rendererOutput: rendererOutputSelectionText,
            rendererStatus: rendererOutputStatusText,
            rendererScene: rendererSceneOutputText,
            monitorOptions: webMonitorOutputOptions(),
            rendererOptions: webRendererOutputOptions()
        )
    }

    private func makeWebPublicRoutingState() -> OrbisonicWebState.Routing {
        OrbisonicWebState.Routing(
            source: sourceMode.displayName,
            incoming: webPublicSignalText,
            monitorOutput: "",
            monitorStatus: "",
            rendererOutput: "",
            rendererStatus: "",
            rendererScene: rendererSceneOutputText,
            monitorOptions: webMonitorOutputOptions(),
            rendererOptions: webRendererOutputOptions()
        )
    }

    private func makeWebLocalMusicState() -> OrbisonicWebState.LocalMusic {
        OrbisonicWebState.LocalMusic(
            search: localMusicSearchText,
            sort: localMusicSortMode.rawValue,
            channelFilter: localMusicChannelFilter,
            availableChannelCounts: availableLocalMusicChannelCounts,
            count: localMusicCountText,
            queue: "",
            tracks: visibleLocalMusicTracks.prefix(80).map(webTrackState),
            playlists: localMusicPlaylists.prefix(80).map(webPlaylistState),
            sessionQueue: []
        )
    }

    private func makeWebDiagnosticsState() -> OrbisonicWebState.Diagnostics {
        OrbisonicWebState.Diagnostics(
            active: activeDiagnosticText,
            toneStatus: testToneStatus,
            monitorChannelCount: monitorChannelWalkCount,
            rendererChannelCount: rendererOutputChannelWalkCount,
            isRunning: isDiagnosticSequencePlaying,
            isTransitioning: isDiagnosticTransitioning,
            selectedChannel: selectedDiagnosticSpeakerChannel,
            availableTests: ["monitorWalk", "rendererWalk", "testTone"]
        )
    }

    private func makeWebPublicDiagnosticsState() -> OrbisonicWebState.Diagnostics {
        OrbisonicWebState.Diagnostics(
            active: "",
            toneStatus: "",
            monitorChannelCount: 0,
            rendererChannelCount: 0,
            isRunning: false,
            isTransitioning: false,
            selectedChannel: 0,
            availableTests: []
        )
    }

    private func makeWebBuildState() -> OrbisonicWebState.Build {
        OrbisonicWebState.Build(
            webServer: self.webServerStatus,
            appStatus: self.statusMessage,
            lastError: self.controlLastError,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev",
            machineIP: URLComponents(string: webPublicPageURL).flatMap(\.host) ?? "unknown"
        )
    }

    private func makeWebPublicBuildState() -> OrbisonicWebState.Build {
        OrbisonicWebState.Build(
            webServer: self.webServerStatus,
            appStatus: "",
            lastError: nil,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev",
            machineIP: URLComponents(string: webPublicPageURL).flatMap(\.host) ?? "unknown"
        )
    }

    private var webNowPlayingTitle: String {
        switch sourceMode {
        case .off:
            return "Nothing playing right now"
        case .roon:
            if let title = roonTransportTitleText, !title.isEmpty {
                return title
            }
            if let nowPlaying = roonNowPlaying {
                return nowPlaying.title
            }
            return "Roon"
        case .testTone:
            return selectedTestTonePoint.rawValue
        case .aux:
            return "Aux Cable"
        case .atmosDRP:
            return currentAtmosDRPTrack?.displayTitle ?? visibleLocalPlaybackTrack?.displayTitle ?? "Atmos"
        case .spotify:
            return spotifyNowPlayingForActiveStatus?.displayTitle ?? "Spotify"
        case .filePlayback:
            if let track = visibleLocalPlaybackTrack {
                return track.displayTitle
            }
            if let metadata = visibleLocalSourceMetadata {
                return metadata.title?.trimmedNilIfBlank ?? metadata.fileName
            }
            return "Nothing playing right now"
        }
    }

    private var webNowPlayingSubtitle: String {
        switch sourceMode {
        case .off:
            return "Choose a source to start playback."
        case .roon:
            if let subtitle = roonTransportSubtitleText, !subtitle.isEmpty {
                return subtitle
            }
            if let nowPlaying = roonNowPlaying {
                return nowPlaying.artist.isEmpty ? "Roon" : nowPlaying.artist
            }
            return "Controlled from Roon."
        case .testTone:
            return testToneStatus
        case .aux:
            return "Controlled in the source app."
        case .atmosDRP:
            if let track = currentAtmosDRPTrack ?? visibleLocalPlaybackTrack {
                return track.displaySubtitle
            }
            return "Dolby Reference Player through \(AtmosDRPRoutingPolicy.captureLoopback.displayName)."
        case .spotify:
            return spotifyNowPlayingForActiveStatus?.artistText ?? "Controlled from Spotify Connect."
        case .filePlayback:
            if let track = visibleLocalPlaybackTrack {
                return track.displaySubtitle
            }
            if let metadata = visibleLocalSourceMetadata {
                let albumArtist = [metadata.album?.trimmedNilIfBlank, metadata.artist?.trimmedNilIfBlank].compactMap { $0 }.joined(separator: " - ")
                return albumArtist.isEmpty ? "\(metadata.layoutName) • \(metadata.channelCount) ch • \(metadata.sampleRateText)" : albumArtist
            }
            return "Choose Roon, Spotify, Atmos, Aux, or Local Music."
        }
    }

    private var webNowPlayingArtist: String {
        switch sourceMode {
        case .off, .aux, .atmosDRP, .testTone:
            if sourceMode == .atmosDRP,
               let track = currentAtmosDRPTrack ?? visibleLocalPlaybackTrack {
                return webPublicMetadataText(track.displayArtist)
            }
            return ""
        case .roon:
            if let artist = roonBridgeSnapshot.selectedZone?.nowPlaying?.threeLine?.line2?.trimmedNilIfBlank {
                return artist
            }
            if let subtitle = roonBridgeSnapshot.selectedZone?.nowPlaying?.subtitleText?.trimmedNilIfBlank {
                return subtitle
            }
            return roonNowPlaying?.artist.trimmedNilIfBlank ?? ""
        case .spotify:
            return webPublicMetadataText(spotifyNowPlayingForActiveStatus?.artistText)
        case .filePlayback:
            if let track = visibleLocalPlaybackTrack {
                return webPublicMetadataText(track.displayArtist)
            }
            return visibleLocalSourceMetadata?.artist?.trimmedNilIfBlank ?? ""
        }
    }

    private var webNowPlayingAlbum: String {
        switch sourceMode {
        case .off, .roon, .aux, .atmosDRP, .testTone:
            if sourceMode == .atmosDRP,
               let track = currentAtmosDRPTrack ?? visibleLocalPlaybackTrack {
                return webPublicMetadataText(track.displayAlbum)
            }
            if sourceMode == .roon,
               let album = roonBridgeSnapshot.selectedZone?.nowPlaying?.threeLine?.line3?.trimmedNilIfBlank {
                return album
            }
            return ""
        case .spotify:
            return webPublicMetadataText(spotifyNowPlayingForActiveStatus?.albumText)
        case .filePlayback:
            if let track = visibleLocalPlaybackTrack {
                return webPublicMetadataText(track.displayAlbum)
            }
            return visibleLocalSourceMetadata?.album?.trimmedNilIfBlank ?? ""
        }
    }

    private var webPlayerStatus: String {
        if isLiveMonitorTransitioning {
            return sourceSwitchStatusText ?? "Stopping audio..."
        }

        switch sourceMode {
        case .off:
            return "Orbisonic is idle"
        case .roon:
            return webRoonPlaybackStatus
        case .spotify:
            return webSpotifyPlaybackStatus
        case .aux:
            return "Aux has no transport"
        case .atmosDRP:
            return webAtmosDRPPlaybackStatus
        case .testTone:
            return isTestTonePlaying ? "Test tone playing" : "Test tone ready"
        case .filePlayback:
            return webLocalPlaybackStatus
        }
    }

    private var webLocalPlaybackStatus: String {
        if isLocalFileLoading {
            return webCondensedLocalLoadingStatus(statusMessage)
        }
        if isPlaying {
            return "Local playing"
        }
        if statusMessage.localizedCaseInsensitiveContains("paused") {
            return "Local paused"
        }
        return "Local ready"
    }

    private func webCondensedLocalLoadingStatus(_ status: String) -> String {
        if status.hasPrefix("Starting playback") {
            return "Loading"
        }
        if status.hasPrefix("Loading") {
            return "Loading"
        }
        if status.hasPrefix("Still loading") {
            return "Still loading."
        }
        return "Loading"
    }

    private var webRoonPlaybackStatus: String {
        guard let state = roonBridgeSnapshot.selectedZone?.state.lowercased() else {
            return liveAudioSignalState.isRecentlyReceiving || liveMonitorState == .monitoring
                ? "Roon playing"
                : webRoonWaitingStatus
        }
        switch state {
        case "playing", "loading":
            if liveAudioSignalState.isRecentlyReceiving || liveMonitorState == .monitoring {
                return "Roon playing"
            }
            if liveAudioSignalState == .noSignal || liveMonitorState == .silent {
                return "No Roon audio"
            }
            return "Waiting for Roon audio"
        case "paused":
            return "Roon paused"
        default:
            return webRoonWaitingStatus
        }
    }

    private var webRoonWaitingStatus: String {
        if liveAudioSignalState == .noSignal || liveMonitorState == .silent {
            return "No Roon audio"
        }
        return "Waiting for Roon"
    }

    private var webSpotifyPlaybackStatus: String {
        guard spotifyReceiverStatus.isRunning else {
            switch spotifyReceiverStatus.state {
            case .failed, .embeddedModuleUnavailable, .notStarted:
                return "Spotify unavailable"
            case .restarting:
                return "Waiting for Spotify"
            case .waitingForConnection, .running:
                break
            }
            return "Waiting for Spotify"
        }
        if liveAudioSignalState.isRecentlyReceiving ||
            liveMonitorState == .monitoring ||
            spotifyNowPlayingForActiveStatus?.isPlaying == true {
            return "Spotify playing"
        }
        return spotifyNowPlayingForActiveStatus == nil ? "No Spotify track" : "Spotify paused"
    }

    private var webAtmosDRPPlaybackStatus: String {
        switch dolbyReferencePlayerSnapshot.state {
        case .starting:
            return "Atmos starting"
        case .playing:
            return "Atmos playing"
        case .paused:
            return "Atmos paused"
        case .stopping:
            return "Atmos stopping"
        case .failed:
            return "Atmos failed"
        case .idle, .stopped:
            return "Atmos ready"
        }
    }

    private var webPlayerCurrentTime: String {
        switch sourceMode {
        case .roon:
            return webTimeText(seconds: roonBridgeSnapshot.selectedZone?.nowPlaying?.seekPosition)
        case .spotify:
            return spotifyNowPlayingForActiveStatus?.positionText ?? "0:00"
        case .filePlayback:
            return visibleLocalSourceMetadata == nil ? "0:00" : formattedCurrentTime()
        case .atmosDRP:
            return currentAtmosDRPTrack == nil ? "0:00" : formattedCurrentTime()
        case .off, .aux, .testTone:
            return "0:00"
        }
    }

    private var webPlayerDuration: String {
        switch sourceMode {
        case .roon:
            return webTimeText(seconds: roonBridgeSnapshot.selectedZone?.nowPlaying?.length)
        case .spotify:
            return spotifyNowPlayingForActiveStatus?.durationText ?? "0:00"
        case .filePlayback:
            return visibleLocalSourceMetadata == nil ? "0:00" : formattedDuration()
        case .atmosDRP:
            return currentAtmosDRPTrack == nil ? "0:00" : formattedDuration()
        case .off, .aux, .testTone:
            return "0:00"
        }
    }

    private var webPlayerProgress: Double {
        switch sourceMode {
        case .roon:
            guard let nowPlaying = roonBridgeSnapshot.selectedZone?.nowPlaying,
                  let position = nowPlaying.seekPosition,
                  let length = nowPlaying.length,
                  length > 0
            else { return 0 }
            return min(max(position / length, 0), 1)
        case .spotify:
            guard let position = spotifyNowPlayingForActiveStatus?.positionMs,
                  let duration = spotifyNowPlayingForActiveStatus?.durationMs,
                  duration > 0
            else { return 0 }
            return min(max(Double(position) / Double(duration), 0), 1)
        case .filePlayback:
            return min(max(scrubProgress, 0), 1)
        case .atmosDRP:
            return min(max(scrubProgress, 0), 1)
        case .off, .aux, .testTone:
            return 0
        }
    }

    private func webTimeText(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return "0:00"
        }

        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func webFormatSampleRate(_ sampleRate: Double) -> String {
        guard sampleRate > 0 else {
            return "unknown rate"
        }

        let kilohertz = sampleRate / 1_000
        if abs(kilohertz.rounded() - kilohertz) < 0.01 {
            return "\(Int(kilohertz.rounded())) kHz"
        }

        return String(format: "%.1f kHz", kilohertz)
    }

    private var webPublicSignalText: String {
        switch sourceMode {
        case .off:
            return "Orbisonic is idle."
        case .roon:
            if let signalPath = roonSignalPath {
                return signalPath.sourceChannelText == "-" ? signalPath.statusText : signalPath.sourceChannelText
            }
            return roonNowPlayingStatus.trimmedNilIfBlank ?? liveSignalStatus
        case .spotify:
            return spotifyNowPlayingForActiveStatus == nil ? "Spotify Connect" : "Spotify Connect • stereo"
        case .aux:
            return liveMonitorState.isCapturing ? "Aux live input active" : "Aux live input idle"
        case .atmosDRP:
            if let summary = dolbyReferencePlayerSnapshot.bitstreamInfo?.formatSummary.trimmedNilIfBlank {
                return summary
            }
            return liveMonitorState.isCapturing ? "Atmos DRP live input active" : "Atmos DRP ready"
        case .testTone:
            return testToneStatus
        case .filePlayback:
            guard let metadata = visibleLocalSourceMetadata else { return "No local file loaded." }
            return "\(webFormatText(for: metadata)) • \(metadata.channelCount) ch • \(metadata.sampleRateText)"
        }
    }

    private var webPlayerDetails: [OrbisonicWebState.Detail] {
        let baseRows: [OrbisonicWebState.Detail] = [
            OrbisonicWebState.Detail(title: "Source", value: webPublicSourceName),
            OrbisonicWebState.Detail(title: "Playback", value: webTechnicalPlaybackText),
            OrbisonicWebState.Detail(title: "Input", value: webTechnicalInputText),
            OrbisonicWebState.Detail(title: "Sphere output", value: webSphereOutputChannelText),
            OrbisonicWebState.Detail(title: "Format", value: webPlayerFormatText),
            OrbisonicWebState.Detail(title: "Renderer", value: webTechnicalRendererText),
            OrbisonicWebState.Detail(title: "Routing", value: webTechnicalRoutingText),
            OrbisonicWebState.Detail(title: "Endpoint", value: webTechnicalEndpointText),
            OrbisonicWebState.Detail(title: "Signal quality", value: webTechnicalSignalQualityText),
            OrbisonicWebState.Detail(title: "System state", value: webTechnicalSystemStateText)
        ]
        return (baseRows + webAtmosDRPDetails).filter { !$0.value.isEmpty }
    }

    private var webAtmosDRPDetails: [OrbisonicWebState.Detail] {
        guard sourceMode == .atmosDRP else { return [] }
        guard let bitstream = dolbyReferencePlayerSnapshot.bitstreamInfo else {
            return [.init(title: "DRP route", value: "\(AtmosDRPRoutingPolicy.captureLoopback.displayName) loopback")]
        }

        var rows: [OrbisonicWebState.Detail] = []
        if let value = bitstream.codec {
            rows.append(.init(title: "DRP codec", value: value))
        }
        if let value = bitstream.hasAtmos {
            rows.append(.init(title: "Dolby Atmos", value: value ? "Yes" : "No"))
        }
        if let value = bitstream.bitRateKbps {
            rows.append(.init(title: "Data rate", value: "\(value) kbps"))
        }
        if let value = bitstream.codedChannels {
            rows.append(.init(title: "Coded channels", value: value))
        }
        if let value = bitstream.sampleRateHz {
            rows.append(.init(title: "Sample rate", value: webFormatSampleRate(Double(value))))
        }
        if let value = bitstream.dynamicObjectCount {
            rows.append(.init(title: "Dynamic objects", value: "\(value)"))
        }
        if let value = bitstream.complexityIndex {
            rows.append(.init(title: "Complexity index", value: "\(value)"))
        }
        return rows
    }

    private var webPlayerControls: [String] {
        ["previous", "play", "pause", "next"]
    }

    private var webEnabledPlayerControls: [String] {
        webPlayerControls.filter { webPlayerControlIsEnabled($0) }
    }

    private func webPlayerControlIsEnabled(_ control: String) -> Bool {
        switch sourceMode {
        case .off, .aux:
            return false
        case .atmosDRP:
            let hasPlayableAtmosSource = currentAtmosDRPTrack != nil ||
                localMusicTracks.contains { DolbyReferencePlayerController.supportsFile($0.url) }
            switch control {
            case "previous", "next":
                return hasPlayableAtmosSource
            case "play":
                return hasPlayableAtmosSource && ![.starting, .playing, .stopping].contains(dolbyReferencePlayerSnapshot.state)
            case "pause":
                return dolbyReferencePlayerSnapshot.state == .playing
            default:
                return false
            }
        case .roon:
            switch control {
            case "previous": return canSendRoonTransport(.previous)
            case "play": return canSendRoonTransport(.play)
            case "pause": return canSendRoonTransport(.pause)
            case "next": return canSendRoonTransport(.next)
            default: return false
            }
        case .spotify:
            return false
        case .filePlayback:
            let hasPlayableLocalSource = visibleLocalSourceMetadata != nil || !localMusicTracks.isEmpty
            switch control {
            case "previous", "next":
                return !sessionQueue.isEmpty || !localMusicTracks.isEmpty
            case "play":
                return hasPlayableLocalSource && !isPlaying && !isLocalFileLoading
            case "pause":
                return isPlaying || isLocalFileLoading
            default:
                return false
            }
        case .testTone:
            switch control {
            case "play": return !isTestTonePlaying
            default: return false
            }
        }
    }

    private var webTechnicalPlaybackText: String {
        if isLiveMonitorTransitioning {
            return "Switching sources"
        }
        if webPlayerIsPlaying {
            return "Playing"
        }
        if webPlayerStatus.localizedCaseInsensitiveContains("paused") {
            return "Paused"
        }
        if webPlayerStatus.localizedCaseInsensitiveContains("loading") ||
            webPlayerStatus.localizedCaseInsensitiveContains("starting") {
            return "Loading"
        }
        return sourceMode == .off ? "Idle" : "Ready"
    }

    private var webTechnicalInputText: String {
        guard let count = webCurrentInputChannelCount else {
            return sourceMode == .off ? "No active input" : "Waiting for input"
        }
        return count == 1 ? "1 channel" : "\(count) channels"
    }

    private var webCurrentInputChannelCount: Int? {
        switch sourceMode {
        case .off:
            return nil
        case .roon:
            if let count = roonSignalPath?.sourceChannelCount {
                return count
            }
            return inputRoute.isAvailable && inputRoute.inputChannelCount > 0 ? inputRoute.inputChannelCount : nil
        case .spotify:
            return 2
        case .aux:
            return inputRoute.isAvailable && inputRoute.inputChannelCount > 0 ? inputRoute.inputChannelCount : nil
        case .atmosDRP:
            return inputRoute.uid == AtmosDRPRoutingPolicy.captureLoopback.deviceUID && inputRoute.inputChannelCount > 0
                ? inputRoute.inputChannelCount
                : nil
        case .filePlayback:
            if let metadata = visibleLocalSourceMetadata, metadata.channelCount > 0 {
                return metadata.channelCount
            }
            if let track = visibleLocalPlaybackTrack, track.channelCount > 0 {
                return track.channelCount
            }
            return nil
        case .testTone:
            return isTestTonePlaying ? 1 : nil
        }
    }

    private var webTechnicalRendererText: String {
        "\(rendererTargetText) \(rendererPreset.outputTopology.fullRangeCount).\(rendererPreset.outputTopology.lfeCount)"
    }

    private var webTechnicalRoutingText: String {
        if rendererScene.isBypass {
            return "Source channels play directly through the sphere"
        }
        if rendererScene.matrix.inputCount > 0 {
            let inputText = rendererScene.matrix.inputCount == 1
                ? "1-channel source"
                : "\(rendererScene.matrix.inputCount)-channel source"
            let outputText = webSphereOutputChannelText.replacingOccurrences(of: " channels", with: "")
            return "\(inputText) expanded to \(outputText) sphere playback"
        }
        if sourceMode == .off {
            return "Ready for a source"
        }
        return "Ready for sphere playback"
    }

    private var webTechnicalEndpointText: String {
        switch sourceMode {
        case .off:
            return ""
        case .roon:
            let value = inputSourceDiagnosticsValue(title: "Roon endpoint raw state") ?? roonBridgeSnapshot.compactStatusText
            return "Orbisonic Roon endpoint \(value.lowercased())"
        case .spotify:
            if spotifyReceiverStatus.isRunning {
                return "Spotify Connect receiver running"
            }
            return spotifyReceiverStatus.message.trimmedNilIfBlank ?? "Spotify Connect receiver waiting"
        case .aux:
            let ready = webLiveInputReadyValue(expected: .auxCable) == "Ready"
            return ready ? "Aux input ready" : "Aux input not connected"
        case .atmosDRP:
            let ready = webLiveInputReadyValue(expected: AtmosDRPRoutingPolicy.captureLoopback) == "Ready"
            let routeText = ready ? "input ready" : "input not connected"
            return "Dolby Reference Player \(routeText)"
        case .filePlayback:
            return "Local Music player"
        case .testTone:
            return "Diagnostics tone generator"
        }
    }

    private var webTechnicalSignalQualityText: String {
        switch sourceMode {
        case .off:
            return ""
        case .roon:
            if let nowPlaying = roonNowPlaying {
                return nowPlaying.tidyFormatText
            }
            if let sourceFormat = roonSignalPath?.sourceFormat.trimmedNilIfBlank {
                return sourceFormat
            }
            return liveSignalStatus
        case .spotify:
            return "Spotify Connect stream"
        case .aux:
            return inputRoute.isAvailable ? "\(webFormatSampleRate(inputRoute.nominalSampleRate)) input" : liveSignalStatus
        case .atmosDRP:
            if let summary = dolbyReferencePlayerSnapshot.bitstreamInfo?.formatSummary.trimmedNilIfBlank {
                return summary
            }
            return inputRoute.isAvailable ? "\(webFormatSampleRate(inputRoute.nominalSampleRate)) input" : liveSignalStatus
        case .filePlayback:
            if let metadata = visibleLocalSourceMetadata {
                var parts = [webFormatText(for: metadata), metadata.sampleRateText]
                if metadata.bitDepth > 0 {
                    parts.append("\(metadata.bitDepth)-bit")
                }
                return parts.filter { !$0.isEmpty && $0 != "-" }.joined(separator: " / ")
            }
            if let track = visibleLocalPlaybackTrack {
                return "\(track.url.pathExtension.uppercased().trimmedNilIfBlank ?? "Local music") / \(track.sampleRateText)"
            }
            return "Waiting for Local Music"
        case .testTone:
            return activeDiagnosticText.trimmedNilIfBlank ?? testToneStatus
        }
    }

    private var webTechnicalSystemStateText: String {
        switch webSourceSeverity {
        case "failed":
            return "Needs attention"
        case "waiting":
            return "Waiting"
        case "active", "ready":
            return "Ready"
        default:
            return sourceMode == .off ? "Idle" : "Ready"
        }
    }

    private func inputSourceDiagnosticsValue(title: String) -> String? {
        inputSourceDiagnosticsRows.first { $0.title == title }?.value
    }

    private var webPlayerFormatText: String {
        switch sourceMode {
        case .roon:
            return webRoonFormatText
        case .filePlayback:
            if let metadata = visibleLocalSourceMetadata {
                return webFormatText(for: metadata)
            }
            if let track = visibleLocalPlaybackTrack {
                return webFormatText(forFileExtension: track.url.pathExtension)
            }
            return ""
        case .atmosDRP:
            if let summary = dolbyReferencePlayerSnapshot.bitstreamInfo?.formatSummary.trimmedNilIfBlank {
                return summary
            }
            if let track = currentAtmosDRPTrack ?? visibleLocalPlaybackTrack {
                return webFormatText(forFileExtension: track.url.pathExtension)
            }
            return ""
        case .off, .spotify, .aux, .testTone:
            return ""
        }
    }

    private var webRoonFormatText: String {
        if let format = roonNowPlaying.flatMap({ webFormatText(in: $0.qualityFormat) }) {
            return format
        }
        if let sourceFormat = roonSignalPath?.sourceFormat,
           let format = webFormatText(in: sourceFormat) {
            return format
        }
        return ""
    }

    private func webFormatText(in text: String) -> String? {
        let uppercased = text.uppercased()
        let candidates: [(matches: [String], label: String)] = [
            (["APPLE LOSSLESS", "ALAC"], "Apple Lossless"),
            (["FLAC"], "FLAC"),
            (["MPEG LAYER 3", "MPEGLAYER3", "MP3"], "MP3"),
            (["MPEG-4 AAC", "MPEG4AAC", "AAC"], "AAC"),
            (["ENHANCED AC-3", "E-AC-3", "EAC3"], "E-AC-3"),
            (["AC-3", "AC3"], "AC-3"),
            (["DSD"], "DSD"),
            (["DXD"], "DXD"),
            (["PCM", "WAV", "AIFF", "AIF"], "PCM")
        ]

        return candidates.first { candidate in
            candidate.matches.contains { uppercased.contains($0) }
        }?.label
    }

    private func webFormatText(for metadata: AudioSourceMetadata) -> String {
        if metadata.containerName.localizedCaseInsensitiveContains("Matroska"),
           !metadata.codecName.isEmpty {
            return metadata.codecName.localizedCaseInsensitiveContains("Matroska")
                ? metadata.codecName
                : "Matroska \(metadata.codecName)"
        }
        return metadata.codecName.isEmpty ? metadata.containerName : metadata.codecName
    }

    private func webFormatText(forFileExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "flac":
            return "FLAC"
        case "m4a":
            return "M4A"
        case "mp3":
            return "MP3"
        case "wav", "wave":
            return "WAV"
        case "aif", "aiff":
            return "AIFF"
        case "mka", "mkv":
            return "Matroska"
        default:
            return fileExtension.uppercased().trimmedNilIfBlank ?? ""
        }
    }

    private func webMonitorOutputOptions() -> [OrbisonicWebState.Route] {
        [
            OrbisonicWebState.Route(id: "none", name: "not set", detail: "Output 1 Monitor disabled", isSelected: monitorOutputSelectionText == "not set", isSelectable: true),
            OrbisonicWebState.Route(id: "system", name: "System Default", detail: systemOutputNowText, isSelected: monitorOutputSelectionText.hasPrefix("System Default"), isSelectable: systemOutputRoute.isSelectableOutputTarget)
        ] + availableOutputRoutes.map { route in
            OrbisonicWebState.Route(
                id: route.uid,
                name: route.deviceName,
                detail: route.routeDetail,
                isSelected: route.uid == monitorOutputRoute.uid,
                isSelectable: route.isSelectableOutputTarget
            )
        }
    }

    private func webRendererOutputOptions() -> [OrbisonicWebState.Route] {
        [
            OrbisonicWebState.Route(id: "none", name: "not set", detail: "Output 2 Renderer not selected", isSelected: rendererOutputSelectionText == "not set", isSelectable: true)
        ] + availableOutputRoutes.map { route in
            OrbisonicWebState.Route(
                id: route.uid,
                name: route.deviceName,
                detail: route.routeDetail,
                isSelected: route.uid == rendererOutputRoute.uid,
                isSelectable: route.isSelectableOutputTarget
            )
        }
    }

    private func webTrackState(_ track: LocalMusicTrack) -> OrbisonicWebState.Track {
        OrbisonicWebState.Track(
            id: OrbisonicWebID.stableID(for: track.id),
            title: track.displayTitle,
            subtitle: track.displaySubtitle,
            album: track.displayAlbum,
            artist: track.displayArtist,
            channels: track.channelText,
            duration: track.durationText,
            isSelected: selectedLibraryTrackID == track.id,
            isCurrent: currentFileURL?.path == track.id,
            isPending: pendingSessionQueueIndex.flatMap { index in
                sessionQueue.indices.contains(index) ? sessionQueue[index].id : nil
            } == track.id
        )
    }

    private func webPlaylistState(_ playlist: LocalMusicPlaylist) -> OrbisonicWebState.Playlist {
        OrbisonicWebState.Playlist(
            id: OrbisonicWebID.stableID(for: playlist.id),
            name: playlist.name,
            fileName: playlist.fileName,
            trackCount: tracks(for: playlist).count,
            isSelected: selectedLocalMusicPlaylistID == playlist.id
        )
    }

    private func performWebPlayerCommand(_ payload: OrbisonicWebCommandPayload) throws {
        let stateBefore = debugPlaybackStateSnapshot()
        let sourceBefore = sourceMode
        let action = payload.action ?? ""
        var allowed = webPlayerControlIsEnabled(action)
        var commandError: String?
        defer {
            logTransportDebug(
                source: sourceBefore,
                command: action,
                allowed: allowed,
                handler: "performWebPlayerCommand",
                stateBefore: stateBefore,
                stateAfter: debugPlaybackStateSnapshot(),
                error: commandError
            )
        }

        do {
            switch action {
            case "play":
                switch sourceMode {
                case .roon:
                    playRoonTransport()
                case .atmosDRP:
                    playAtmosDRPTransport()
                case .filePlayback:
                    playLocalTransport()
                case .testTone:
                    playSelectedTestTone()
                case .off, .spotify, .aux:
                    allowed = false
                    throw OrbisonicWebCommandError.unsupportedCommand
                }
            case "pause":
                switch sourceMode {
                case .roon:
                    pauseRoonTransport()
                case .atmosDRP:
                    pauseAtmosDRPTransport()
                case .filePlayback:
                    pauseLocalTransport()
                case .off, .spotify, .aux, .testTone:
                    allowed = false
                    throw OrbisonicWebCommandError.unsupportedCommand
                }
            case "stop":
                switch sourceMode {
                case .roon:
                    stopRoonTransport()
                case .atmosDRP:
                    stopAtmosDRPTransport()
                case .filePlayback:
                    stopLocalTransport()
                case .testTone:
                    stop()
                case .off, .spotify, .aux:
                    allowed = false
                    throw OrbisonicWebCommandError.unsupportedCommand
                }
            case "previous":
                switch sourceMode {
                case .roon:
                    playPreviousRoonTrack()
                case .atmosDRP:
                    skipAtmosDRPTransport(offset: -1)
                case .filePlayback:
                    skipLocalTransport(offset: -1)
                case .off, .spotify, .aux, .testTone:
                    allowed = false
                    throw OrbisonicWebCommandError.unsupportedCommand
                }
            case "next":
                switch sourceMode {
                case .roon:
                    playNextRoonTrack()
                case .atmosDRP:
                    skipAtmosDRPTransport(offset: 1)
                case .filePlayback:
                    skipLocalTransport(offset: 1)
                case .off, .spotify, .aux, .testTone:
                    allowed = false
                    throw OrbisonicWebCommandError.unsupportedCommand
                }
            default:
                allowed = false
                throw OrbisonicWebCommandError.unsupportedCommand
            }
        } catch {
            commandError = error.localizedDescription
            throw error
        }
    }

    private func performWebVolumeCommand(_ payload: OrbisonicWebCommandPayload) throws {
        let rawValue = payload.value ?? payload.query ?? payload.id ?? ""
        guard let volume = Double(rawValue) else {
            throw OrbisonicWebCommandError.invalidPayload
        }

        setSphereOutputVolume(volume)
    }

    private func performWebSourceCommand(_ payload: OrbisonicWebCommandPayload) throws {
        guard let value = payload.value,
              let mode = SourceMode(rawValue: value),
              SourceMode.musicInputs.contains(mode)
        else { throw OrbisonicWebCommandError.invalidPayload }
        selectSourceMode(mode, reason: "web source selected", requestedBy: "web")
    }

    private func performWebInputRouteCommand(_ payload: OrbisonicWebCommandPayload) throws {
        guard let id = payload.id ?? payload.value,
              let route = availableInputRoutes.first(where: { $0.uid == id })
        else { throw OrbisonicWebCommandError.invalidPayload }
        selectInputRoute(route)
    }

    private func performWebMonitorCommand(_ payload: OrbisonicWebCommandPayload) throws {
        switch payload.action {
        case "start":
            startSelectedLiveMonitor()
        case "mute":
            muteLiveMonitor()
        case "resume":
            resumeLiveMonitor()
        case "stop":
            stopSelectedLiveMonitor()
        default:
            throw OrbisonicWebCommandError.unsupportedCommand
        }
    }

    private func performWebMonitorOutputCommand(_ payload: OrbisonicWebCommandPayload) throws {
        let value = payload.value ?? payload.id ?? ""
        if value == "none" {
            selectNoMonitorOutput()
            return
        }
        if value == "system" {
            selectSystemMonitorOutput()
            return
        }
        guard let route = availableOutputRoutes.first(where: { $0.uid == value }) else {
            throw OrbisonicWebCommandError.invalidPayload
        }
        selectMonitorOutputRoute(route)
    }

    private func performWebRendererOutputCommand(_ payload: OrbisonicWebCommandPayload) throws {
        let value = payload.value ?? payload.id ?? ""
        if value == "none" {
            selectNoRendererOutput()
            return
        }
        guard let route = availableOutputRoutes.first(where: { $0.uid == value }) else {
            throw OrbisonicWebCommandError.invalidPayload
        }
        selectRendererOutputRoute(route)
    }

    private func performWebTrackCommand(_ payload: OrbisonicWebCommandPayload) throws {
        guard let id = payload.id,
              let track = localMusicTracks.first(where: { OrbisonicWebID.stableID(for: $0.id) == id })
        else { throw OrbisonicWebCommandError.invalidPayload }

        switch payload.action {
        case "select":
            selectLocalMusicTrack(track)
        case "play":
            playLocalMusicTrackNow(track)
        case "add":
            addLocalMusicTrackToQueue(track)
        default:
            throw OrbisonicWebCommandError.unsupportedCommand
        }
    }

    private func performWebPlaylistCommand(_ payload: OrbisonicWebCommandPayload) throws {
        guard let id = payload.id,
              let playlist = localMusicPlaylists.first(where: { OrbisonicWebID.stableID(for: $0.id) == id })
        else { throw OrbisonicWebCommandError.invalidPayload }

        switch payload.action {
        case "select":
            selectedLocalMusicPlaylistID = playlist.id
        case "play":
            playLocalMusicPlaylist(playlist, shuffle: payload.shuffle ?? false)
        case "add":
            addLocalMusicPlaylistToQueue(playlist, shuffle: payload.shuffle ?? false)
        default:
            throw OrbisonicWebCommandError.unsupportedCommand
        }
    }

    private func performWebQueueCommand(_ payload: OrbisonicWebCommandPayload) throws {
        switch payload.action {
        case "play":
            guard let index = payload.index else { throw OrbisonicWebCommandError.invalidPayload }
            playSessionQueueIndex(index)
        case "select":
            guard let index = payload.index else { throw OrbisonicWebCommandError.invalidPayload }
            selectSessionQueueIndex(index)
        case "up":
            guard let index = payload.index else { throw OrbisonicWebCommandError.invalidPayload }
            moveSessionQueueItemUp(index)
        case "down":
            guard let index = payload.index else { throw OrbisonicWebCommandError.invalidPayload }
            moveSessionQueueItemDown(index)
        case "remove":
            guard let index = payload.index else { throw OrbisonicWebCommandError.invalidPayload }
            removeSessionQueueItem(index)
        case "clear":
            clearSessionQueue()
        default:
            throw OrbisonicWebCommandError.unsupportedCommand
        }
    }

    private func performWebDiagnosticsCommand(_ payload: OrbisonicWebCommandPayload) throws {
        switch payload.action {
        case "monitorWalk":
            startMonitorChannelWalk()
        case "rendererWalk":
            startRendererOutputChannelWalk()
        case "testTone":
            if let index = payload.index {
                selectDiagnosticSpeakerChannel(index)
            }
            playSelectedDiagnosticSpeakerTone()
        case "stop":
            if isTestTonePlaying {
                stopTestTone()
            } else {
                stopDiagnosticsAndReturnToMusic()
            }
        default:
            throw OrbisonicWebCommandError.unsupportedCommand
        }
    }
}

private enum OrbisonicWebCommandError: LocalizedError {
    case invalidPayload
    case unsupportedCommand
    case webControlReadOnly

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "The web command payload was invalid."
        case .unsupportedCommand:
            "That web command is not supported for the current source."
        case .webControlReadOnly:
            "That control is desktop-only. The web page is read-only for this panel."
        }
    }
}

private extension OrbisonicWebServer {
    static var publicPageHTML: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Sonic Sphere Now Playing</title>
          <style>\(baseCSS)</style>
        </head>
        <body>
          <main class="shell public-shell">
            <section class="hero">
              <p>Sonic Sphere</p>
              <h1>Now Playing</h1>
            </section>
            <section class="now-card">
              <div class="art-frame">
                <img id="artworkImage" class="artwork public-artwork" alt="Album art" hidden>
                <div id="artFallback" class="art-fallback" aria-hidden="true">
                  <div class="sphere-mark">
                    <span></span><span></span><span></span>
                  </div>
                </div>
              </div>
              <div class="track-copy">
                <h2 id="titleText">Nothing playing right now</h2>
                <p id="artistText" class="artist-line" hidden></p>
                <p id="albumText" class="album-line" hidden></p>
              <p id="sourceLine" class="source-line">Roon · Spotify · Atmos · Aux · Local Music</p>
                <p id="idleHint" class="idle-hint">Choose a source to start playback.</p>
              </div>
              <details class="nerd-panel" id="nerdPanel">
                <summary>Stuff for nerds</summary>
                <div id="nerdDetails" class="nerd-details"></div>
              </details>
            </section>
            <p id="connectionNote" class="connection-note" hidden></p>
          </main>
          <script>\(publicPageJS)</script>
        </body>
        </html>
        """
    }

    static let baseCSS = """
    :root{color-scheme:dark;--bg:#061013;--panel:#0b171bcc;--line:#d7fbff22;--text:#f2fdff;--muted:#a9b9bc;--soft:#ffffff0e;--cyan:#6ee7dc;--blue:#93c5fd}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;background:linear-gradient(135deg,#061013 0%,#0b171b 48%,#04090b 100%);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Display","Segoe UI",sans-serif}
    [hidden]{display:none!important}.shell{width:min(780px,calc(100vw - 28px));margin:0 auto;padding:34px 0 38px}.hero{text-align:center;margin-bottom:18px}.hero p{margin:0 0 4px;color:var(--cyan);font-size:13px;font-weight:850;letter-spacing:.08em;text-transform:uppercase}.hero h1{margin:0;font-size:30px;line-height:1.05;font-weight:850}
    .now-card{border:1px solid var(--line);border-radius:8px;background:var(--panel);box-shadow:0 22px 52px #00000070;padding:24px}.art-frame{position:relative;width:min(100%,430px);aspect-ratio:1;margin:0 auto 22px;border:1px solid var(--line);border-radius:8px;overflow:hidden;background:#0e1b20}
    .artwork,.art-fallback{position:absolute;inset:0;width:100%;height:100%}.artwork{object-fit:cover}.art-fallback{display:grid;place-items:center;background:linear-gradient(145deg,#102126,#071013)}.sphere-mark{position:relative;width:46%;aspect-ratio:1;border:1px solid #6ee7dc70;border-radius:50%;box-shadow:0 0 48px #6ee7dc24,inset 0 0 32px #93c5fd16}.sphere-mark span{position:absolute;inset:16%;border:1px solid #ffffff34;border-radius:50%}.sphere-mark span:nth-child(1){transform:rotateX(68deg)}.sphere-mark span:nth-child(2){transform:rotateY(68deg)}.sphere-mark span:nth-child(3){inset:36%;background:#6ee7dc}
    .track-copy{text-align:center;display:grid;gap:8px}.track-copy h2{margin:0;font-size:34px;line-height:1.08;font-weight:850;overflow-wrap:anywhere}.artist-line,.album-line,.source-line,.idle-hint,.connection-note{margin:0}.artist-line{font-size:18px;font-weight:750;color:#dff7f8;overflow-wrap:anywhere}.album-line{font-size:16px;font-weight:650;color:var(--muted);overflow-wrap:anywhere}.source-line{margin-top:3px;color:var(--cyan);font-size:13px;font-weight:850;letter-spacing:.02em}.idle-hint,.connection-note{color:var(--muted);font-weight:650}.idle-hint{margin-top:2px}.connection-note{text-align:center;margin-top:12px}
    .nerd-panel{margin-top:22px;border-top:1px solid var(--line);padding-top:12px;color:var(--muted)}.nerd-panel summary{cursor:pointer;list-style:none;font-size:12px;font-weight:850;letter-spacing:.06em;text-transform:uppercase}.nerd-panel summary::-webkit-details-marker{display:none}.nerd-panel summary::after{content:"+";float:right;color:var(--cyan)}.nerd-panel[open] summary::after{content:"-"}.nerd-details{display:grid;gap:8px;margin-top:12px}.row{display:grid;grid-template-columns:130px minmax(0,1fr);gap:14px;align-items:start;padding:8px 0;border-top:1px solid #ffffff0b}.row:first-child{border-top:0}.row b{color:#7f969a;text-transform:uppercase;font-size:11px;font-weight:850}.row span{color:#d8e9eb;font-weight:700;overflow-wrap:anywhere}
    @media(max-width:620px){.shell{width:min(100vw - 20px,780px);padding-top:20px}.now-card{padding:16px}.art-frame{margin-bottom:18px}.hero h1{font-size:26px}.track-copy h2{font-size:28px}.artist-line{font-size:16px}.row{grid-template-columns:1fr;gap:2px}}
    """

    static let publicPageJS = """
    const $=id=>document.getElementById(id);
    function esc(v){return String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
    function clean(v){const text=String(v??'').trim();return text==='-'?'':text}
    function sourceName(player){return clean(player.sourceName)||({'Aux Cable':'Aux','Local Files':'Local Music','Roon':'Roon','Spotify':'Spotify'}[player.source]||clean(player.source)||'Sonic Sphere')}
    function hasMedia(player){return Boolean(player.hasMedia)}
    function setText(id,value){$(id).textContent=value}
    function setOptionalText(id,value){const el=$(id),text=clean(value);el.textContent=text;el.hidden=!text}
    function setArtwork(url){
      const art=$('artworkImage'),fallback=$('artFallback');
      if(url){
        if(art.getAttribute('src')!==url)art.src=url;
        art.hidden=false;fallback.hidden=true;
      }else{
        art.removeAttribute('src');art.hidden=true;fallback.hidden=false;
      }
      art.onerror=()=>{art.hidden=true;fallback.hidden=false};
    }
    const hiddenNerdRows=new Set(['Renderer','Routing','Endpoint','System state']);
    function renderNerdRows(rows){
      $('nerdDetails').innerHTML=(rows||[]).filter(r=>!hiddenNerdRows.has(clean(r.title))).map(r=>`<div class="row"><b>${esc(r.title)}</b><span>${esc(r.value)}</span></div>`).join('');
    }
    async function load(){
      try{
        const res=await fetch('/Orbisonic/api/public-state',{cache:'no-store'});
        const s=await res.json();
        const media=hasMedia(s.player),source=sourceName(s.player);
        setArtwork(s.player.artworkURL);
        setText('titleText',media?clean(s.player.title)||'Untitled':'Nothing playing right now');
        setOptionalText('artistText',media?s.player.artist:'');
        setOptionalText('albumText',media?s.player.album:'');
        setText('sourceLine',media?source:'Roon · Spotify · Atmos · Aux · Local Music');
        $('idleHint').hidden=media;
        renderNerdRows(s.player.details);
        $('connectionNote').hidden=true;
      }catch(e){
        setArtwork(null);
        setText('titleText','Nothing playing right now');
        setOptionalText('artistText','');
        setOptionalText('albumText','');
        setText('sourceLine','Roon · Spotify · Atmos · Aux · Local Music');
        $('idleHint').hidden=false;
        $('connectionNote').textContent='Waiting for Orbisonic.';
        $('connectionNote').hidden=false;
      }
    }
    load();setInterval(load,1500);
    """

}
