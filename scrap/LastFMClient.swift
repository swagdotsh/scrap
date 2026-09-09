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
        if !isConfigured { return "Setup needed — Last.fm app credentials are missing." }
        if sessionKey == nil { return "Not signed in to Last.fm." }
        switch lastFMReachable {
        case true: return "Online — signed in and able to communicate with Last.fm."
        case false: return "Offline — unable to communicate with Last.fm. Check your connection or try again later."
        case nil: return "Checking the connection to Last.fm…"
        }
    }

    func checkConnection() async {
        guard isConfigured, let sessionKey else { lastFMReachable = nil; return }
        guard !checkingConnection else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        do {
            // Omitting user checks the account associated with this authenticated session.
            let result = try await request(["method": "user.getInfo", "sk": sessionKey])
            guard self.sessionKey == sessionKey else { return }
            lastFMReachable = result["user"] is [String: Any]
        } catch {
            guard self.sessionKey == sessionKey else { return }
            lastFMReachable = false
        }
    }

    @Published var scrobblingPaused = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Connect your Last.fm account to start scrobbling."
    @Published private(set) var pendingCount = 0
    @Published private(set) var isSending = false
    private let apiKey = AppConfiguration.load().apiKey
    private let sharedSecret = AppConfiguration.load().sharedSecret
    var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }
    var canScrobble: Bool { isConfigured && sessionKey != nil && username != nil }

    static func accountStatus(isConfigured: Bool, hasSession: Bool, username: String?) -> String {
        if !isConfigured {
            if hasSession, let username {
                return "Account saved as \(username). Add the original app credentials to .env and rebuild Scrap to resume scrobbling."
            }
            return "Add app credentials to .env and rebuild Scrap, then connect Last.fm."
        }
        if hasSession, let username { return "Connected as \(username)." }
        return "Connect your Last.fm account to start scrobbling."
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
            sessionKey = nil
            lastFMReachable = nil
            username = nil
            pendingToken = nil
            friends = []
            friendsOwner = nil
            friendsUpdatedAt = nil
            friendsAttemptedAt = nil
            friendsError = nil
            try KeychainHelper.delete(key: "lastfm_username")
            status = "Signed out."
        } catch { status = "Could not finish signing out: \(error.localizedDescription)" }
    }

    func beginAuth() async {
        guard isConfigured, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let json = try await request(["method": "auth.getToken"])
            guard let token = json["token"] as? String else { throw failure("Last.fm returned no authorization token.") }
            var url = URLComponents(string: "https://www.last.fm/api/auth/")!
            url.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: token)]
            guard NSWorkspace.shared.open(url.url!) else { throw failure("Could not open the authorization page.") }
            pendingToken = token
            status = "Approve Scrap in your browser, then click ‘I've approved it’."
        } catch { status = error.localizedDescription }
    }

    func completeAuth() async {
        guard let pendingToken, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let json = try await request(["method": "auth.getSession", "token": pendingToken])
            guard let session = json["session"] as? [String: Any], let key = session["key"] as? String,
                  let user = session["name"] as? String else { throw failure("Last.fm returned no session.") }
            try KeychainHelper.save(key: "lastfm_session_key", value: key)
            try KeychainHelper.save(key: "lastfm_username", value: user)
            sessionKey = key
            username = user
            self.pendingToken = nil
            status = "Connected as \(user)."
            await retryPending()
        } catch { status = error.localizedDescription }
    }

    func isLoved(_ track: PlayingTrack) async throws -> Bool {
        guard let username else { throw NSError(domain: "LastFM", code: 0) }
        let json = try await request(["method": "track.getInfo", "artist": track.artist, "track": track.title, "username": username])
        guard let info = json["track"] as? [String: Any], let value = info["userloved"] else {
            throw NSError(domain: "LastFM", code: 0)
        }
        return (value as? String) == "1" || (value as? Int) == 1
    }

    func love(_ track: PlayingTrack, loved: Bool = true) async {
        guard isConfigured, let sessionKey else { return }
        do {
            _ = try await request(["method": loved ? "track.love" : "track.unlove", "track": track.title, "artist": track.artist, "sk": sessionKey], post: true)
            status = loved ? "Loved \(track.title)." : "Unloved \(track.title)."
        } catch { status = error.localizedDescription }
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
                status = accepted ? "Scrobbled \(item.track.title)." : "Last.fm ignored \(item.track.title)."
                queue.remove(at: index)
                persistQueue()
            } catch {
                let apiError = error as NSError
                if apiError.domain == "LastFM", apiError.code != 0,
                   ![9, 11, 16, 29].contains(apiError.code) {
                    queue.remove(at: index)
                    persistQueue()
                    status = "Last.fm rejected \(item.track.title): \(error.localizedDescription)"
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
        var params = ["track": track.title, "artist": track.artist, "album": track.album]
        if let duration = track.duration { params["duration"] = String(Int(duration)) }
        return params
    }

    func request(_ input: [String: String], post: Bool = false) async throws -> [String: Any] {
        guard isConfigured else { throw failure("Scrap’s API credentials are missing. Restore them to continue.") }
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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Invalid Last.fm response.") }
        if let code = json["error"] as? Int {
            if code == 9 { sessionKey = nil }
            throw NSError(domain: "LastFM", code: code, userInfo: [NSLocalizedDescriptionKey: json["message"] as? String ?? "Last.fm error \(code)."] )
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw failure("Last.fm request failed.") }
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
