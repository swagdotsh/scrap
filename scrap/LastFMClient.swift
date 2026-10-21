import Foundation
import CryptoKit
import AppKit
import Combine

@MainActor
final class LastFMClient: ObservableObject {
    @Published private(set) var sessionKey = KeychainHelper.load(key: "lastfm_session_key")
    @Published private(set) var username = KeychainHelper.load(key: "lastfm_username")
    @Published private(set) var pendingToken: String?
    @Published private(set) var lastFMReachable: Bool?
    private var checkingConnection = false
    var connectionHelp: String {
        if !isConfigured { return "Setup needed: last.fm app credentials are missing." }
        if sessionKey == nil { return "Not signed in to last.fm." }
        switch lastFMReachable {
        case true: return "Online (Signed in and able to communicate with last.fm)"
        case false: return "Offline (Unable to communicate with last.fm. Check your connection or try again later)"
        case nil: return "Checking the connection to last.fm…"
        }
    }

    func checkConnection() async {
        guard isConfigured, let sessionKey else { lastFMReachable = nil; return }
        guard !checkingConnection else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        do {
            let result = try await request(["method": "user.getInfo", "sk": sessionKey], post: true)
            guard self.sessionKey == sessionKey else { return }
            lastFMReachable = result["user"] is [String: Any]
        } catch {
            guard self.sessionKey == sessionKey else { return }
            lastFMReachable = false
        }
    }

    @Published var scrobblingPaused = false
    var onScrobbled: ((PlayingTrack) -> Void)?
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Connect your last.fm account to start scrobbling."
    @Published private(set) var pendingCount = 0
    @Published private(set) var isSending = false
    private let apiKey = AppConfiguration.load().apiKey
    private let sharedSecret = AppConfiguration.load().sharedSecret
    var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }
    var canScrobble: Bool { isConfigured && sessionKey != nil && username != nil }

    static func accountStatus(isConfigured: Bool, hasSession: Bool, username: String?) -> String {
        if !isConfigured {
            if hasSession, let username {
                return "Account saved as \(username). Add the original app credentials to .env and rebuild scrap to resume scrobbling."
            }
            return "Add app credentials to .env and rebuild scrap, then connect last.fm."
        }
        if hasSession, let username { return "Connected as \(username)." }
        return "Connect your last.fm account to start scrobbling."
    }

    @Published var friends: [FriendActivity] = []
    @Published var friendsLoading = false
    @Published var friendsUpdatedAt: Date?
    @Published var friendsError: String?
    var friendsAttemptedAt: Date?
    var friendsOwner: String?

    private struct Submission: Codable {
        let track: PlayingTrack
        let startedAt: Date
        let username: String
    }
    private var queue: [Submission] = []
    private let defaults: UserDefaults

    private enum DefaultsKey {
        static let removeAlbumTypeSuffix = "removeAlbumTypeSuffix"
        static let usePrimaryArtist = "usePrimaryArtist"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "pendingScrobbles"),
           let saved = try? JSONDecoder().decode([Submission].self, from: data) { queue = saved }
        pendingCount = queue.count
        status = Self.accountStatus(isConfigured: isConfigured, hasSession: sessionKey != nil, username: username)
    }

    func signOut() {
        guard !isBusy, !isSending else { return }
        do {
            try KeychainHelper.delete(key: "lastfm_session_key")
            try KeychainHelper.delete(key: "lastfm_username")
            sessionKey = nil
            lovedTracks = [:]
            lastFMReachable = nil
            username = nil
            pendingToken = nil
            friends = []
            friendsOwner = nil
            friendsUpdatedAt = nil
            friendsAttemptedAt = nil
            friendsError = nil
            status = "Signed out. last.fm data removed from Keychain."
        } catch {
            sessionKey = KeychainHelper.load(key: "lastfm_session_key")
            username = KeychainHelper.load(key: "lastfm_username")
            status = "Could not finish signing out: \(error.localizedDescription)"
        }
    }

    func beginAuth() async {
        guard isConfigured, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let json = try await request(["method": "auth.getToken"])
            guard let token = json["token"] as? String else { throw failure("last.fm returned no authorization token.") }
            var url = URLComponents(string: "https://www.last.fm/api/auth/")!
            url.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: token)]
            guard NSWorkspace.shared.open(url.url!) else { throw failure("Could not open the authorization page.") }
            pendingToken = token
            status = "Approve scrap in your browser, then click ‘I've approved it’."
        } catch { status = error.localizedDescription }
    }

    func completeAuth() async {
        guard let pendingToken, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let json = try await request(["method": "auth.getSession", "token": pendingToken])
            guard let session = json["session"] as? [String: Any], let key = session["key"] as? String,
                  let user = session["name"] as? String else { throw failure("last.fm returned no session.") }
            try KeychainHelper.save(key: "lastfm_session_key", value: key)
            try KeychainHelper.save(key: "lastfm_username", value: user)
            lovedTracks = [:]
            sessionKey = key
            username = user
            self.pendingToken = nil
            status = "Connected as \(user)."
            await retryPending()
        } catch { status = error.localizedDescription }
    }

    private var loveRevision = 0
    @Published private(set) var lovedTracks: [[String]: Bool] = [:]
    @Published private(set) var loveRequests = Set<[String]>()

    func lovedState(for track: PlayingTrack) -> Bool? {
        lovedTracks[[track.artist, track.title]]
    }

    func refreshLovedState(for track: PlayingTrack) async {
        guard canScrobble else { return }
        do { _ = try await isLoved(track) }
        catch { status = "Could not load loved status: \(error.localizedDescription)" }
    }

    func isLoved(_ track: PlayingTrack) async throws -> Bool {
        guard let username else { throw NSError(domain: "LastFM", code: 0) }
        let revision = loveRevision
        let json = try await request(["method": "track.getInfo", "artist": track.artist, "track": track.title, "username": username])
        guard let info = json["track"] as? [String: Any], let value = info["userloved"] else {
            throw NSError(domain: "LastFM", code: 0)
        }
        let loved = (value as? String) == "1" || (value as? Int) == 1
        guard self.username == username else { throw NSError(domain: "LastFM", code: 0) }
        if revision == loveRevision, !loveRequests.contains([track.artist, track.title]) {
            lovedTracks[[track.artist, track.title]] = loved
        }
        return loved
    }

    private var automaticLoves = Set<[String]>()
    private var automaticLoveAttempts: [[String]: Date] = [:]

    func loveAppleMusicFavorite(_ track: PlayingTrack) {
        guard defaults.bool(forKey: "loveAppleMusicFavorites"), canScrobble,
              let sessionKey else { return }
        let key = [sessionKey, track.artist, track.title]
        guard !automaticLoves.contains(key),
              automaticLoveAttempts[key].map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        automaticLoveAttempts[key] = Date()
        automaticLoves.insert(key)
        Task {
            let succeeded = await love(track)
            if !succeeded { automaticLoves.remove(key) }
        }
    }

    @discardableResult
    func love(_ track: PlayingTrack, loved: Bool = true) async -> Bool {
        guard isConfigured, let sessionKey else { return false }
        let trackKey = [track.artist, track.title]
        guard !loveRequests.contains(trackKey) else { return false }
        loveRevision += 1
        loveRequests.insert(trackKey)
        defer { loveRequests.remove(trackKey) }
        do {
            _ = try await request(["method": loved ? "track.love" : "track.unlove", "track": track.title, "artist": track.artist, "sk": sessionKey], post: true)
            guard self.sessionKey == sessionKey else { return false }
            lovedTracks[trackKey] = loved
            status = loved ? "Loved \(track.title)." : "Unloved \(track.title)."
            return true
        } catch { status = error.localizedDescription; return false }
    }

    func updateNowPlaying(_ track: PlayingTrack) {
        guard !scrobblingPaused, isConfigured, let sessionKey else { return }
        Task {
            do {
                guard !scrobblingPaused else { return }
                var params = metadata(track)
                params["method"] = "track.updateNowPlaying"
                params["sk"] = sessionKey
                _ = try await request(params, post: true)
            } catch { status = error.localizedDescription }
        }
    }

    func scrobble(_ track: PlayingTrack, startedAt: Date) {
        guard !scrobblingPaused, canScrobble, let username else { return }
        queue.append(Submission(track: track, startedAt: startedAt, username: username))
        persistQueue()
        Task { await retryPending() }
    }

    func retryPending() async {
        guard !scrobblingPaused, isConfigured, !isSending, let sessionKey, let username else { return }
        isSending = true
        defer { isSending = false }
        while !scrobblingPaused, let index = queue.firstIndex(where: { $0.username == username }) {
            let item = queue[index]
            do {
                var params = metadata(item.track)
                params["method"] = "track.scrobble"
                params["sk"] = sessionKey
                params["timestamp"] = String(Int(item.startedAt.timeIntervalSince1970))
                let json = try await request(params, post: true)
                guard let result = json["scrobbles"] as? [String: Any],
                      let attributes = result["@attr"] as? [String: Any] else {
                    throw failure("Unexpected response. Scrobble kept for retry.")
                }
                let accepted = String(describing: attributes["accepted"] ?? "0") == "1"
                status = accepted ? "Scrobbled \(item.track.title)." : "last.fm ignored \(item.track.title)."
                if accepted { onScrobbled?(item.track) }
                queue.remove(at: index)
                persistQueue()
            } catch {
                let apiError = error as NSError
                if apiError.domain == "LastFM", apiError.code != 0,
                   ![9, 11, 16, 29].contains(apiError.code) {
                    queue.remove(at: index)
                    persistQueue()
                    status = "last.fm rejected \(item.track.title): \(error.localizedDescription)"
                    continue
                }
                status = "\(error.localizedDescription) Scrobble saved; reconnect or use Retry pending."
                return
            }
        }
    }

    private func persistQueue() {
        defaults.set(try? JSONEncoder().encode(queue), forKey: "pendingScrobbles")
        pendingCount = queue.count
    }

    private func metadata(_ track: PlayingTrack) -> [String: String] {
        Self.metadata(
            for: track,
            removeAlbumTypeSuffix: defaults.bool(forKey: DefaultsKey.removeAlbumTypeSuffix),
            removeAppleMusicEdition: defaults.bool(forKey: "removeAppleMusicEdition"),
            usePrimaryArtist: defaults.bool(forKey: DefaultsKey.usePrimaryArtist),
            preservedArtistNames: defaults.string(forKey: "preservedArtistNames") ?? Self.defaultPreservedArtistNames,
            removeFeaturedArtists: defaults.bool(forKey: "removeFeaturedArtists")
        )
    }

    nonisolated static let defaultPreservedArtistNames = "Earth, Wind & Fire"

    static func removingFeaturedArtists(from title: String) -> String {
        let pattern = #"\s*[(\[](?:feat\.?|ft\.?|featuring|with)\s[^)\]]*[)\]]"#
        let cleaned = title.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    static func metadata(
        for track: PlayingTrack,
        removeAlbumTypeSuffix: Bool,
        removeAppleMusicEdition: Bool = false,
        usePrimaryArtist: Bool,
        preservedArtistNames: String = defaultPreservedArtistNames,
        removeFeaturedArtists: Bool = false
    ) -> [String: String] {
        var album = track.album
        if removeAlbumTypeSuffix {
            let editionSuffix = " (Apple Music Edition)"
            if removeAppleMusicEdition, album.hasSuffix(editionSuffix) {
                album.removeLast(editionSuffix.count)
            }
            for suffix in [" - Single", " - EP"] where album.hasSuffix(suffix) {
                album.removeLast(suffix.count)
                break
            }
        }

        var artist = track.artist
        if usePrimaryArtist {
            let protectedNames = preservedArtistNames.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }
            let protectedRange = protectedNames.compactMap { name -> Range<String.Index>? in
                guard let range = artist.range(of: name, options: [.anchored, .caseInsensitive]) else { return nil }
                let remainder = artist[range.upperBound...]
                guard remainder.isEmpty || remainder.hasPrefix(" & ") || remainder.hasPrefix(", ") else { return nil }
                return range
            }.first
            if let protectedRange {
                artist = String(artist[protectedRange])
            } else {
                let separators = [artist.range(of: ", "), artist.range(of: " & ")].compactMap { $0 }
                if let separator = separators.min(by: { $0.lowerBound < $1.lowerBound }) {
                    artist = String(artist[..<separator.lowerBound])
                }
            }
        }

        let title = removeFeaturedArtists ? Self.removingFeaturedArtists(from: track.title) : track.title
        var params = ["track": title, "artist": artist, "album": album]
        if let duration = track.duration { params["duration"] = String(Int(duration)) }
        return params
    }

    func request(_ input: [String: String], post: Bool = false) async throws -> [String: Any] {
        guard isConfigured else { throw failure("scrap’s API credentials are missing. Restore them to continue.") }
        var params = input
        params["api_key"] = apiKey
        let base = params.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + sharedSecret
        params["api_sig"] = Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02hhx", $0) }.joined()
        params["format"] = "json"
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        var request: URLRequest
        if post {
            request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formBody(params).utf8)
        } else {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            request = URLRequest(url: components.url!)
        }
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Invalid last.fm response.") }
        if let code = json["error"] as? Int {
            if code == 9 { sessionKey = nil }
            throw NSError(domain: "LastFM", code: code, userInfo: [NSLocalizedDescriptionKey: json["message"] as? String ?? "last.fm error \(code)."] )
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw failure("last.fm request failed.") }
        return json
    }

    static func formBody(_ params: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return params.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
