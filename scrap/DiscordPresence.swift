import AppKit
import Combine
import CryptoKit

// MARK: - Settings

enum DiscordStatusSource: String, CaseIterable, Identifiable {
    case state, details, app
    var id: String { rawValue }
    var label: String {
        switch self {
        case .state: "Artist line"
        case .details: "Track line"
        case .app: "App name"
        }
    }
    var discordValue: Int {
        switch self {
        case .app: 0
        case .state: 1
        case .details: 2
        }
    }
}

enum DiscordButtonKind: String, CaseIterable, Identifiable {
    case none, songLink, appleMusic, spotify, lastFMTrack, lastFMArtist, lastFMAlbum
    var id: String { rawValue }
    var menuTitle: String {
        switch self {
        case .none: "None"
        case .songLink: "song.link"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .lastFMTrack: "last.fm track page"
        case .lastFMArtist: "last.fm artist page"
        case .lastFMAlbum: "last.fm album page"
        }
    }
    var defaultLabel: String {
        switch self {
        case .none: ""
        case .songLink: "Listen on song.link"
        case .appleMusic: "Play on Apple Music"
        case .spotify: "Play on Spotify"
        case .lastFMTrack: "View on last.fm"
        case .lastFMArtist: "Artist on last.fm"
        case .lastFMAlbum: "Album on last.fm"
        }
    }
}

enum DiscordCoverSource: String, CaseIterable, Identifiable {
    case lastFM, musicApp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lastFM: "last.fm"
        case .musicApp: "Music app (your artwork)"
        }
    }
}

enum DiscordPausedBehavior: String, CaseIterable, Identifiable {
    case clear, keep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clear: "Hide activity"
        case .keep: "Keep it, without the time bar"
        }
    }
}

enum DiscordKey {
    static let enabled = "discordPresenceEnabled"
    static let detailsFormat = "discordDetailsFormat"
    static let stateFormat = "discordStateFormat"
    static let albumFormat = "discordAlbumFormat"
    static let statusSource = "discordStatusSource"
    static let showCover = "discordShowCover"
    static let coverSource = "discordCoverSource"
    static let uploadedCovers = "discordUploadedCovers"
    static let showTimestamps = "discordShowTimestamps"
    static let linkNames = "discordLinkNames"
    static let useScrobbleCleanup = "discordUseScrobbleCleanup"
    static let paused = "discordPausedBehavior"
    static let button1 = "discordButton1"
    static let button1Label = "discordButton1Label"
    static let button2 = "discordButton2"
    static let button2Label = "discordButton2Label"

    static func scoped(_ key: String, _ service: PlaybackService?) -> String {
        service.map { "\(key).\($0.rawValue)" } ?? key
    }
    static func customSettings(_ service: PlaybackService) -> String { "discordCustomSettings.\(service.rawValue)" }
    static func show(_ service: PlaybackService) -> String { "discordShow.\(service.rawValue)" }
}

struct DiscordPresenceSettings: Equatable {
    static let defaultDetailsFormat = "{title}"
    static let defaultStateFormat = "{artist}"
    static let defaultAlbumFormat = "{album}"

    var detailsFormat = defaultDetailsFormat
    var stateFormat = defaultStateFormat
    var albumFormat = defaultAlbumFormat
    var statusSource = DiscordStatusSource.state
    var showCover = true
    var coverSource = DiscordCoverSource.lastFM
    var showTimestamps = true
    var linkNames = true
    var useScrobbleCleanup = true
    var paused = DiscordPausedBehavior.clear
    var button1 = DiscordButtonKind.songLink
    var button1Label = ""
    var button2 = DiscordButtonKind.lastFMTrack
    var button2Label = ""

    static func isShown(for service: PlaybackService?, _ defaults: UserDefaults = .standard) -> Bool {
        guard let service else { return true }
        return defaults.object(forKey: DiscordKey.show(service)) as? Bool ?? true
    }

    static func load(for service: PlaybackService? = nil, _ defaults: UserDefaults = .standard) -> Self {
        let scope = service.flatMap { defaults.bool(forKey: DiscordKey.customSettings($0)) ? $0 : nil }
        func string(_ key: String) -> String? {
            scope.flatMap { defaults.string(forKey: DiscordKey.scoped(key, $0)) } ?? defaults.string(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            scope.flatMap { defaults.object(forKey: DiscordKey.scoped(key, $0)) as? Bool }
                ?? defaults.object(forKey: key) as? Bool ?? fallback
        }
        var settings = Self()
        settings.detailsFormat = string(DiscordKey.detailsFormat) ?? defaultDetailsFormat
        settings.stateFormat = string(DiscordKey.stateFormat) ?? defaultStateFormat
        settings.albumFormat = string(DiscordKey.albumFormat) ?? defaultAlbumFormat
        settings.statusSource = DiscordStatusSource(rawValue: string(DiscordKey.statusSource) ?? "") ?? .state
        settings.showCover = bool(DiscordKey.showCover, true)
        settings.coverSource = DiscordCoverSource(rawValue: string(DiscordKey.coverSource) ?? "") ?? .lastFM
        settings.showTimestamps = bool(DiscordKey.showTimestamps, true)
        settings.linkNames = bool(DiscordKey.linkNames, true)
        settings.useScrobbleCleanup = bool(DiscordKey.useScrobbleCleanup, true)
        settings.paused = DiscordPausedBehavior(rawValue: string(DiscordKey.paused) ?? "") ?? .clear
        settings.button1 = DiscordButtonKind(rawValue: string(DiscordKey.button1) ?? "") ?? .songLink
        settings.button1Label = string(DiscordKey.button1Label) ?? ""
        settings.button2 = DiscordButtonKind(rawValue: string(DiscordKey.button2) ?? "") ?? .lastFMTrack
        settings.button2Label = string(DiscordKey.button2Label) ?? ""
        return settings
    }
}

// MARK: - Activity

struct DiscordTrackInfo: Equatable {
    var track: PlayingTrack
    var service: String?
    var source: PlaybackService?
    var coverURL: URL?
    var songLinkURL: URL?
    var appleMusicURL: URL?
    var spotifyURL: URL?
}

struct DiscordActivity: Equatable {
    struct Button: Equatable { let label: String; let url: URL }

    var details: String?
    var state: String?
    var albumText: String?
    var detailsURL: URL?
    var stateURL: URL?
    var albumURL: URL?
    var coverURL: URL?
    var statusSource: DiscordStatusSource
    var start: Date?
    var end: Date?
    var buttons: [Button] = []

    func statusText(appName: String) -> String {
        switch statusSource {
        case .state: state ?? appName
        case .details: details ?? appName
        case .app: appName
        }
    }

    var payload: [String: Any] {
        var activity: [String: Any] = ["type": 2, "status_display_type": statusSource.discordValue]
        if let details { activity["details"] = details }
        if let state { activity["state"] = state }
        if let detailsURL { activity["details_url"] = detailsURL.absoluteString }
        if let stateURL { activity["state_url"] = stateURL.absoluteString }
        var assets: [String: Any] = [:]
        if let coverURL { assets["large_image"] = coverURL.absoluteString }
        if let albumText { assets["large_text"] = albumText }
        if let albumURL, coverURL != nil { assets["large_url"] = albumURL.absoluteString }
        if !assets.isEmpty { activity["assets"] = assets }
        var timestamps: [String: Any] = [:]
        if let start { timestamps["start"] = Int64(start.timeIntervalSince1970 * 1000) }
        if let end { timestamps["end"] = Int64(end.timeIntervalSince1970 * 1000) }
        if !timestamps.isEmpty { activity["timestamps"] = timestamps }
        if !buttons.isEmpty { activity["buttons"] = buttons.map { ["label": $0.label, "url": $0.url.absoluteString] } }
        return activity
    }

    static func build(info: DiscordTrackInfo, settings: DiscordPresenceSettings, isPlaying: Bool, startedAt: Date?) -> DiscordActivity? {
        if !isPlaying && settings.paused == .clear { return nil }
        let track = info.track
        let details = text(format(settings.detailsFormat, info))
        let state = text(format(settings.stateFormat, info))
        let album = text(format(settings.albumFormat, info))
        var activity = DiscordActivity(details: details, state: state, albumText: album, statusSource: settings.statusSource)
        if (settings.statusSource == .state && state == nil) || (settings.statusSource == .details && details == nil) {
            activity.statusSource = state != nil ? .state : details != nil ? .details : .app
        }
        if settings.linkNames {
            if details != nil { activity.detailsURL = track.trackURL }
            if state != nil { activity.stateURL = track.artistURL }
            if !track.album.isEmpty { activity.albumURL = track.albumURL }
        }
        if settings.showCover { activity.coverURL = info.coverURL }
        if isPlaying, settings.showTimestamps, let startedAt {
            activity.start = startedAt
            if let duration = track.duration, duration > 0 { activity.end = startedAt.addingTimeInterval(duration) }
        }
        guard info.source != .untitled else { return activity }
        var used = Set<URL>()
        for (kind, label) in [(settings.button1, settings.button1Label), (settings.button2, settings.button2Label)] {
            guard let url = buttonURL(kind, info: info) ?? (kind == .songLink ? track.trackURL : nil),
                  used.insert(url).inserted else { continue }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? kind.defaultLabel : trimmed
            activity.buttons.append(Button(label: clamp(title, limit: 32), url: url))
        }
        return activity
    }

    static func buttonURL(_ kind: DiscordButtonKind, info: DiscordTrackInfo) -> URL? {
        switch kind {
        case .none: nil
        case .songLink: info.songLinkURL
        case .appleMusic: info.appleMusicURL
        case .spotify: info.spotifyURL
        case .lastFMTrack: info.track.trackURL
        case .lastFMArtist: info.track.artistURL
        case .lastFMAlbum: info.track.album.isEmpty ? nil : info.track.albumURL
        }
    }

    static func format(_ template: String, _ info: DiscordTrackInfo) -> String {
        let values = ["{title}": info.track.title, "{artist}": info.track.artist,
                      "{album}": info.track.album, "{service}": info.service ?? ""]
        var result = template
        for (token, value) in values where result.contains(token) {
            if value.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : clamp(trimmed, limit: 128)
    }

    static func clamp(_ value: String, limit: Int) -> String {
        var result = value
        if result.count > limit { result = String(result.prefix(limit - 1)) + "…" }
        while result.count < 2 { result += "\u{2800}" }
        return result
    }
}

// MARK: - Controller

@MainActor
final class DiscordPresence: ObservableObject {
    static let defaultApplicationID = AppConfiguration.load().discordApplicationID.filter(\.isNumber)
    static let serviceApplicationIDs: [PlaybackService: String] = {
        let configuration = AppConfiguration.load()
        let ids: [PlaybackService: String] = [.spotify: configuration.discordSpotifyApplicationID.filter(\.isNumber),
                                              .untitled: configuration.discordUntitledApplicationID.filter(\.isNumber)]
        return ids.filter { !$0.value.isEmpty }
    }()

    static func applicationID(for service: PlaybackService?) -> String {
        applicationID(for: service, defaultID: defaultApplicationID, serviceIDs: serviceApplicationIDs)
    }

    nonisolated static func applicationID(for service: PlaybackService?, defaultID: String,
                                          serviceIDs: [PlaybackService: String]) -> String {
        service.flatMap { serviceIDs[$0] } ?? defaultID
    }
    static let discordBundleIDs = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]

    enum Status: Equatable {
        case off, notConfigured, waitingForDiscord, connecting, connected(username: String?), error(String)
        var description: String {
            switch self {
            case .off: "Off"
            case .notConfigured: "No Discord application ID is set in this build. Add DISCORD_APPLICATION_ID to .env and rebuild."
            case .waitingForDiscord: "Waiting for Discord. Open the Discord app to show your activity."
            case .connecting: "Connecting to Discord…"
            case .connected(let name): name.map { "Connected to Discord as \($0)." } ?? "Connected to Discord."
            case .error(let message): message
            }
        }
    }

    @Published private(set) var status = Status.off
    @Published private(set) var info: DiscordTrackInfo?
    @Published private(set) var isPlaying = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var appNames: [String: String] = [:]
    @Published private(set) var activityError: String?

    private let client: LastFMClient
    private let connection = DiscordIPCConnection()
    private var settings = DiscordPresenceSettings.load()
    private var enabled = UserDefaults.standard.bool(forKey: DiscordKey.enabled)
    private var trackKey: String?
    private var currentRawTrack: PlayingTrack?
    private var currentSource: PlaybackService?
    private var connectedID: String?
    private var activeID: String { Self.applicationID(for: currentSource) }
    private var currentTrackID: String?
    private var lookupTask: Task<Void, Never>?
    private var linkCache: [String: (songLink: URL?, appleMusic: URL?)] = [:]
    private var coverCache: [String: URL] = [:]
    private var lastSent: DiscordActivity??
    private var lastSentAt = Date.distantPast
    private var pendingSend: DispatchWorkItem?
    private var lastAttempt = Date.distantPast
    private var retryDelay: TimeInterval = 5
    private var subscriptions = Set<AnyCancellable>()

    init(client: LastFMClient) {
        self.client = client
        connection.onEvent = { [weak self] in self?.handle($0) }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &subscriptions)
        refreshStatus()
    }

    func update(track: PlayingTrack?, source: PlaybackService?, isPlaying playing: Bool, position: TimeInterval, trackID: String?) {
        guard let track else {
            if info != nil { info = nil; trackKey = nil; currentRawTrack = nil; startedAt = nil; lookupTask?.cancel() }
            isPlaying = false
            tick()
            return
        }
        let key = [source?.rawValue ?? "", trackID ?? "", track.artist, track.title, track.album].joined(separator: "\u{1F}")
        if key != trackKey {
            trackKey = key
            currentRawTrack = track
            currentSource = source
            currentTrackID = trackID
            settings = DiscordPresenceSettings.load(for: source)
            startedAt = nil
            info = DiscordTrackInfo(track: displayTrack(track), service: source?.name, source: source,
                                    coverURL: coverCache[coverKey(track, key: key)],
                                    songLinkURL: linkCache[key]?.songLink, appleMusicURL: linkCache[key]?.appleMusic,
                                    spotifyURL: Self.spotifyURL(for: track, source: source, trackID: trackID))
            startLookups(for: track, source: source, trackID: trackID, key: key)
        }
        if playing {
            let candidate = Date().addingTimeInterval(-max(0, position))
            if startedAt.map({ abs($0.timeIntervalSince(candidate)) > 2 }) ?? true { startedAt = candidate }
        }
        if isPlaying != playing { isPlaying = playing }
        tick()
    }

    func appName(for service: PlaybackService?) -> String? {
        appNames[Self.applicationID(for: service)]
    }

    func fetchAppNames() async {
        let ids = Set(PlaybackService.allCases.map(Self.applicationID(for:))).filter { !$0.isEmpty && appNames[$0] == nil }
        for id in ids {
            guard let url = URL(string: "https://discord.com/api/v10/applications/\(id)/rpc"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String else { continue }
            appNames[id] = name
        }
    }

    private func displayTrack(_ track: PlayingTrack) -> PlayingTrack {
        guard settings.useScrobbleCleanup else { return track }
        let cleaned = client.metadata(track)
        return PlayingTrack(title: cleaned["track"] ?? track.title, artist: cleaned["artist"] ?? track.artist,
                            album: cleaned["album"] ?? track.album, duration: track.duration)
    }

    private func settingsChanged() {
        let previousCoverSource = settings.coverSource
        settings = DiscordPresenceSettings.load(for: currentSource)
        if settings.coverSource != previousCoverSource, let raw = currentRawTrack, let key = trackKey {
            info?.coverURL = coverCache[coverKey(raw, key: key)]
            startLookups(for: raw, source: currentSource, trackID: currentTrackID, key: key)
        }
        let newEnabled = UserDefaults.standard.bool(forKey: DiscordKey.enabled)
        if newEnabled != enabled {
            enabled = newEnabled
            if !enabled { connection.disconnect(); connectedID = nil; lastSent = nil; pendingSend?.cancel(); pendingSend = nil }
            lastAttempt = .distantPast
            retryDelay = 5
            activityError = nil
            status = .off
            refreshStatus()
        }
        if let raw = currentRawTrack, let current = info?.track {
            let display = displayTrack(raw)
            if display != current { info?.track = display }
        }
        tick()
    }

    private func tick() {
        guard enabled, !activeID.isEmpty else { return }
        if let connectedID, connectedID != activeID {
            connection.disconnect()
            self.connectedID = nil
            lastSent = nil
            pendingSend?.cancel()
            pendingSend = nil
            lastAttempt = .distantPast
            retryDelay = 5
            status = .waitingForDiscord
        }
        switch status {
        case .connected:
            scheduleSend()
        case .connecting:
            if Date().timeIntervalSince(lastAttempt) > 10 {
                connection.disconnect()
                status = .waitingForDiscord
            }
        default:
            guard Date().timeIntervalSince(lastAttempt) >= retryDelay else { return }
            guard Self.isDiscordRunning else {
                if status != .waitingForDiscord, !isErrorStatus { status = .waitingForDiscord }
                return
            }
            lastAttempt = Date()
            status = .connecting
            connectedID = activeID
            connection.connect(clientID: activeID)
        }
    }

    private var isErrorStatus: Bool { if case .error = status { true } else { false } }

    private func refreshStatus() {
        if !enabled { status = .off }
        else if activeID.isEmpty { status = .notConfigured }
        else if case .connected = status {}
        else { status = .waitingForDiscord }
    }

    private static var isDiscordRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { discordBundleIDs.contains($0.bundleIdentifier ?? "") }
    }

    private func handle(_ event: DiscordIPCConnection.Event) {
        switch event {
        case .ready(let username):
            retryDelay = 5
            lastSent = nil
            activityError = nil
            status = .connected(username: username)
            scheduleSend()
        case .closed(let reason):
            lastSent = nil
            pendingSend?.cancel()
            guard enabled else { status = .off; return }
            if let reason {
                status = .error("Discord closed the connection: \(reason)")
                retryDelay = 30
            } else {
                status = .waitingForDiscord
                retryDelay = 5
            }
        case .error(_, let message):
            activityError = "Discord: \(message)"
        }
    }

    // MARK: Sending

    private var currentActivity: DiscordActivity? {
        guard let info, DiscordPresenceSettings.isShown(for: info.source) else { return nil }
        return DiscordActivity.build(info: info, settings: settings, isPlaying: isPlaying, startedAt: startedAt)
    }

    private func scheduleSend() {
        let activity = currentActivity
        if let lastSent, lastSent == activity { pendingSend?.cancel(); pendingSend = nil; return }
        guard pendingSend == nil else { return }
        let wait = max(0, 4 - Date().timeIntervalSince(lastSentAt))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSend = nil
            guard case .connected = self.status, self.enabled else { return }
            let latest = self.currentActivity
            if let lastSent = self.lastSent, lastSent == latest { return }
            self.connection.setActivity(latest?.payload)
            self.lastSent = .some(latest)
            self.lastSentAt = Date()
        }
        pendingSend = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    // MARK: Lookups

    private static func albumKey(_ track: PlayingTrack) -> String {
        (track.artist + "\u{1F}" + track.album).lowercased()
    }

    private func startLookups(for track: PlayingTrack, source: PlaybackService?, trackID: String?, key: String) {
        lookupTask?.cancel()
        let coverKey = coverKey(track, key: key)
        let useMusicApp = settings.coverSource == .musicApp
        let needsCover = coverCache[coverKey] == nil
        let needsLinks = linkCache[key] == nil
        guard needsCover || needsLinks else { return }
        lookupTask = Task { [weak self] in
            guard let self else { return }
            if needsCover {
                var cover: URL?
                if useMusicApp { cover = await self.musicAppCoverURL(source: source, trackID: trackID) }
                if cover == nil, !Task.isCancelled { cover = await self.coverURL(for: track) }
                guard let cover, !Task.isCancelled else { return }
                self.coverCache[coverKey] = cover
                if self.trackKey == key { self.info?.coverURL = cover; self.tick() }
            }
            if needsLinks {
                let links = await Self.musicLinks(for: track, source: source, trackID: trackID)
                guard !Task.isCancelled else { return }
                self.linkCache[key] = links
                if self.trackKey == key {
                    self.info?.songLinkURL = links.songLink
                    self.info?.appleMusicURL = links.appleMusic
                    self.tick()
                }
            }
        }
    }

    private func coverKey(_ track: PlayingTrack, key: String) -> String {
        settings.coverSource == .musicApp ? "app\u{1F}" + key : Self.albumKey(track)
    }

    private func musicAppCoverURL(source: PlaybackService?, trackID: String?) async -> URL? {
        switch source {
        case .spotify:
            let result = Self.runScript("""
            tell application id "com.spotify.client" to return {id of current track, artwork url of current track}
            """)
            guard result?.atIndex(1)?.stringValue == trackID, let raw = result?.atIndex(2)?.stringValue,
                  let url = URL(string: raw), url.scheme == "https" else { return nil }
            return url
        case .appleMusic:
            guard let trackID, let raw = LocalArtwork.appleMusicData(trackID: trackID),
                  let jpeg = Self.coverJPEG(raw) else { return nil }
            return await uploadedCoverURL(jpeg)
        default:
            return nil
        }
    }

    private static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    nonisolated static func coverJPEG(_ data: Data, maxPixels: Int = 512) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private func uploadedCoverURL(_ jpeg: Data) async -> URL? {
        let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let lifetime: TimeInterval = 70 * 3600
        var saved = UserDefaults.standard.dictionary(forKey: DiscordKey.uploadedCovers) as? [String: [String: Any]] ?? [:]
        if let entry = saved[hash], let date = entry["date"] as? Date, Date().timeIntervalSince(date) < lifetime,
           let raw = entry["url"] as? String, let url = URL(string: raw) {
            return url
        }
        guard let url = await Self.uploadToLitterbox(jpeg), !Task.isCancelled else { return nil }
        saved = saved.filter { ($0.value["date"] as? Date).map { Date().timeIntervalSince($0) < lifetime } ?? false }
        saved[hash] = ["url": url.absoluteString, "date": Date()]
        UserDefaults.standard.set(saved, forKey: DiscordKey.uploadedCovers)
        return url
    }

    nonisolated static func litterboxFilename(_ jpeg: Data) -> String {
        "scrap-" + SHA256.hash(data: jpeg).prefix(8).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    nonisolated static func litterboxRequest(_ jpeg: Data, boundary: String = UUID().uuidString) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (name, value) in [("reqtype", "fileupload"), ("time", "72h")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(litterboxFilename(jpeg))\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    private static func uploadToLitterbox(_ jpeg: Data) async -> URL? {
        guard let (data, response) = try? await URLSession.shared.data(for: litterboxRequest(jpeg)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), url.scheme == "https", url.host?.hasSuffix("catbox.moe") == true else { return nil }
        return url
    }

    private func coverURL(for track: PlayingTrack) async -> URL? {
        var candidates: [URL] = []
        if !track.album.isEmpty,
           let json = try? await client.request(["method": "album.getInfo", "artist": track.artist, "album": track.album]),
           let album = json["album"] as? [String: Any] {
            candidates = ArtworkCandidates.urls(album["image"])
        }
        if candidates.isEmpty,
           let json = try? await client.request(["method": "track.getInfo", "artist": track.artist, "track": track.title]),
           let album = (json["track"] as? [String: Any])?["album"] as? [String: Any] {
            candidates = ArtworkCandidates.urls(album["image"])
        }
        var checked = Set<String>()
        var animated: URL?
        for url in candidates where checked.insert(url.lastPathComponent).inserted {
            guard checked.count <= 4, !Task.isCancelled else { break }
            guard let data = await Self.fetchImage(url), ArtworkCandidates.stillImage(data) != nil else { continue }
            if !ArtworkCandidates.isAnimated(data) { return url }
            if animated == nil { animated = url }
        }
        if let animated, let frozen = Self.frozenCoverURL(animated), !Task.isCancelled,
           let data = await Self.fetchImage(frozen), ArtworkCandidates.stillImage(data) != nil {
            return frozen
        }
        return animated ?? candidates.first
    }

    private static func fetchImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    nonisolated static func frozenCoverURL(_ url: URL) -> URL? {
        var components = URLComponents(string: "https://wsrv.nl/")!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "output", value: "jpg"),
            URLQueryItem(name: "n", value: "1"),
        ]
        return components.url
    }

    nonisolated static func spotifyURL(for track: PlayingTrack, source: PlaybackService?, trackID: String?) -> URL? {
        if source == .spotify, let id = trackID, id.hasPrefix("spotify:track:") {
            let trackPart = id.dropFirst("spotify:track:".count)
            if !trackPart.isEmpty, trackPart.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return URL(string: "https://open.spotify.com/track/\(trackPart)")
            }
        }
        let query = "\(track.artist) \(LastFMClient.removingFeaturedArtists(from: track.title))"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) else { return nil }
        return URL(string: "https://open.spotify.com/search/\(encoded)")
    }

    nonisolated static func songLinkURL(spotifyID: String?) -> URL? {
        guard let spotifyID, spotifyID.hasPrefix("spotify:track:") else { return nil }
        let id = spotifyID.dropFirst("spotify:track:".count)
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return URL(string: "https://song.link/s/\(id)")
    }

    private static func musicLinks(for track: PlayingTrack, source: PlaybackService?, trackID: String?) async -> (songLink: URL?, appleMusic: URL?) {
        let match = await iTunesMatch(for: track)
        let spotifyLink = source == .spotify ? songLinkURL(spotifyID: trackID) : nil
        let catalogLink = (match?["trackId"] as? Int).flatMap { URL(string: "https://song.link/i/\($0)") }
        return (spotifyLink ?? catalogLink, match.flatMap(appleMusicURL))
    }

    nonisolated static func appleMusicURL(_ match: [String: Any]) -> URL? {
        guard let raw = match["trackViewUrl"] as? String, var components = URLComponents(string: raw),
              components.scheme == "https", components.host?.hasSuffix("apple.com") == true else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name == "i" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    private static func iTunesMatch(for track: PlayingTrack) async -> [String: Any]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track.artist) \(LastFMClient.removingFeaturedArtists(from: track.title))"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        return bestITunesMatch(results, for: track)
    }

    nonisolated static func bestITunesMatch(_ results: [[String: Any]], for track: PlayingTrack) -> [String: Any]? {
        func normalize(_ value: String) -> String {
            LastFMClient.removingFeaturedArtists(from: value)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
        }
        let title = normalize(track.title)
        let artist = normalize(track.artist)
        let album = normalize(track.album)
        let matches = results.filter {
            let resultArtist = normalize($0["artistName"] as? String ?? "")
            return normalize($0["trackName"] as? String ?? "") == title
                && !resultArtist.isEmpty && (artist.contains(resultArtist) || resultArtist.contains(artist))
        }
        return matches.first { !album.isEmpty && normalize($0["collectionName"] as? String ?? "").hasPrefix(album) } ?? matches.first
    }
}
