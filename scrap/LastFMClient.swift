import Foundation
import CryptoKit
import AppKit

@MainActor
final class LastFMClient: ObservableObject {
    private let apiKey = "YOUR_API_KEY"
    private let sharedSecret = "YOUR_SHARED_SECRET"
    private let baseURL = "https://ws.audioscrobbler.com/2.0/"

    @Published private(set) var sessionKey: String?
    @Published private(set) var username: String?

    init() {
        sessionKey = KeychainHelper.load(key: "lastfm_session_key")
        username = KeychainHelper.load(key: "lastfm_username")
    }

    // MARK: - Signing

    private func sign(_ params: [String: String]) -> String {
        let sorted = params.sorted { $0.key < $1.key }
        let base = sorted.map { $0.key + $0.value }.joined() + sharedSecret
        let digest = Insecure.MD5.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    // MARK: - Auth flow

    func beginAuth() async {
        do {
            let token = try await getToken()
            let authURL = URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)")!
            NSWorkspace.shared.open(authURL)

            // give the user time to approve in the browser before we try getSession
            // simplest approach: a manual "I've approved it" step, see step below
            self.pendingToken = token
        } catch {
            print("❌ getToken failed: \(error)")
        }
    }

    private var pendingToken: String?

    func completeAuth() async {
        guard let token = pendingToken else {
            print("❌ No pending token — call beginAuth() first")
            return
        }
        do {
            let (key, user) = try await getSession(token: token)
            self.sessionKey = key
            self.username = user
            KeychainHelper.save(key: "lastfm_session_key", value: key)
            KeychainHelper.save(key: "lastfm_username", value: user)
            print("✅ Authenticated as \(user)")
        } catch {
            print("❌ getSession failed: \(error)")
        }
    }

    private func getToken() async throws -> String {
        var params = ["method": "auth.getToken", "api_key": apiKey, "format": "json"]
        params["api_sig"] = sign(params.filter { $0.key != "format" })

        let (data, _) = try await URLSession.shared.data(for: makeRequest(params))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["token"] as? String else {
            throw NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: "No token in response: \(String(data: data, encoding: .utf8) ?? "")"])
        }
        return token
    }

    private func getSession(token: String) async throws -> (String, String) {
        var params = ["method": "auth.getSession", "api_key": apiKey, "token": token, "format": "json"]
        params["api_sig"] = sign(params.filter { $0.key != "format" })

        let (data, _) = try await URLSession.shared.data(for: makeRequest(params))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let session = json?["session"] as? [String: Any],
              let key = session["key"] as? String,
              let name = session["name"] as? String else {
            throw NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: "No session in response: \(String(data: data, encoding: .utf8) ?? "")"])
        }
        return (key, name)
    }

    // MARK: - Scrobbling

    func updateNowPlaying(_ track: PlayingTrack) {
        guard let sessionKey else { return }
        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "api_key": apiKey,
            "sk": sessionKey,
            "track": track.title,
            "artist": track.artist,
            "album": track.album,
            "format": "json"
        ]
        params["api_sig"] = sign(params.filter { $0.key != "format" })

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: makeRequest(params, method: "POST"))
                print("📡 updateNowPlaying response: \(String(data: data, encoding: .utf8) ?? "")")
            } catch {
                print("❌ updateNowPlaying failed: \(error)")
            }
        }
    }

    func scrobble(_ track: PlayingTrack) {
        guard let sessionKey else { return }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": apiKey,
            "sk": sessionKey,
            "track": track.title,
            "artist": track.artist,
            "album": track.album,
            "timestamp": timestamp,
            "format": "json"
        ]
        params["api_sig"] = sign(params.filter { $0.key != "format" })

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: makeRequest(params, method: "POST"))
                print("✅ scrobble response: \(String(data: data, encoding: .utf8) ?? "")")
            } catch {
                print("❌ scrobble failed: \(error)")
            }
        }
    }

    // MARK: - Request building

    private func makeRequest(_ params: [String: String], method: String = "GET") -> URLRequest {
        var components = URLComponents(string: baseURL)!
        if method == "GET" {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            return URLRequest(url: components.url!)
        } else {
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
            request.httpBody = body.data(using: .utf8)
            return request
        }
    }
}