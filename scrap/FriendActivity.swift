import Foundation

struct FriendActivity: Identifiable {
    let name: String
    let track: String?
    let artist: String?
    var avatarURL: URL? = nil
    var profileURL: URL {
        URL(string: "https://www.last.fm/user/")!.appendingPathComponent(name)
    }
    var id: String { name }

    static func parse(_ row: [String: Any]) -> FriendActivity? {
        guard let name = row["name"] as? String else { return nil }
        let recent = row["recenttrack"] as? [String: Any]
        let group = row["recenttracks"] as? [String: Any]
        let track = recent ?? (group?["track"] as? [[String: Any]])?.first ?? (group?["track"] as? [String: Any])
        let artist = track?["artist"] as? [String: Any]
        let images = row["image"] as? [[String: Any]] ?? []
        let avatar = images.reversed().compactMap { ($0["#text"] as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
        return FriendActivity(name: name, track: track?["name"] as? String,
                              artist: artist?["#text"] as? String ?? artist?["name"] as? String ?? track?["artist"] as? String, avatarURL: avatar)
    }
}

extension LastFMClient {
    func refreshFriends(force: Bool = false) async {
        guard isConfigured, let username, !friendsLoading else { return }
        if friendsOwner != username {
            friends = []; friendsUpdatedAt = nil; friendsAttemptedAt = nil; friendsOwner = username
        }
        if !force, let last = friendsAttemptedAt, Date().timeIntervalSince(last) < 3600 { return }
        friendsAttemptedAt = Date()
        friendsLoading = true
        defer { friendsLoading = false }
        do {
            var result: [FriendActivity] = []
            var page = 1
            var totalPages = 1
            repeat {
                let json = try await request(["method": "user.getFriends", "user": username, "recenttracks": "1", "limit": "50", "page": String(page)])
                guard let root = json["friends"] as? [String: Any] else {
                    throw NSError(domain: "Friends", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unexpected friends response."])
                }
                let rows = root["user"] as? [[String: Any]] ?? (root["user"] as? [String: Any]).map { [$0] } ?? []
                result += rows.compactMap(FriendActivity.parse)
                let attributes = root["@attr"] as? [String: Any]
                totalPages = Int(attributes?["totalPages"] as? String ?? "1") ?? 1
                page += 1
                try Task.checkCancellation()
            } while page <= totalPages
            guard self.username == username else { return }
            var seen = Set<String>()
            friends = result.filter { seen.insert($0.name).inserted }
            friendsUpdatedAt = Date()
            friendsError = nil
        } catch {
            guard self.username == username else { return }
            friendsError = "Couldn’t refresh friends. \(error.localizedDescription)"
        }
    }
}
