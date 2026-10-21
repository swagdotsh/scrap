import Foundation

struct FriendActivity: Identifiable {
    let name: String
    var track: String?
    var artist: String?
    var avatarURL: URL? = nil
    var isNowPlaying = false
    var playedAt: Date?
    var profileURL: URL {
        URL(string: "https://www.last.fm/user/")!.appendingPathComponent(name)
    }
    var id: String { name }

    static func parse(_ row: [String: Any]) -> FriendActivity? {
        guard let name = row["name"] as? String else { return nil }
        let recent = row["recenttrack"] as? [String: Any]
        let group = row["recenttracks"] as? [String: Any]
        let track = recent ?? (group?["track"] as? [[String: Any]])?.first ?? (group?["track"] as? [String: Any])
        let images = row["image"] as? [[String: Any]] ?? []
        let avatar = images.reversed().compactMap { ($0["#text"] as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
        var friend = FriendActivity(name: name, track: nil, artist: nil, avatarURL: avatar)
        if let track { friend.apply(recentTrack: track) }
        return friend
    }

    mutating func apply(recentTrack: [String: Any]) {
        let artist = recentTrack["artist"] as? [String: Any]
        track = recentTrack["name"] as? String
        self.artist = artist?["#text"] as? String ?? artist?["name"] as? String ?? recentTrack["artist"] as? String
        isNowPlaying = (recentTrack["@attr"] as? [String: Any])?["nowplaying"] as? String == "true"
        let uts = (recentTrack["date"] as? [String: Any])?["uts"] as? String
        playedAt = uts.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
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
                let json = try await request(["method": "user.getFriends", "user": username, "limit": "50", "page": String(page)])
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
            var unique = result.filter { seen.insert($0.name).inserted }
            let recent = await recentTracks(for: unique.map(\.name))
            guard self.username == username else { return }
            for index in unique.indices {
                if let track = recent[unique[index].name] { unique[index].apply(recentTrack: track) }
            }
            friends = unique
            friendsUpdatedAt = Date()
            friendsError = nil
        } catch {
            guard self.username == username else { return }
            friendsError = "Couldn’t refresh friends. \(error.localizedDescription)"
        }
    }

    private func recentTracks(for names: [String]) async -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        await withTaskGroup(of: (String, [String: Any]?).self) { group in
            var pending = names.makeIterator()
            func addNext() {
                guard let name = pending.next() else { return }
                group.addTask {
                    let json = try? await self.request(["method": "user.getRecentTracks", "user": name, "limit": "1"])
                    let tracks = (json?["recenttracks"] as? [String: Any])?["track"]
                    return (name, (tracks as? [[String: Any]])?.first ?? tracks as? [String: Any])
                }
            }
            for _ in 0..<6 { addNext() }
            for await (name, track) in group {
                if let track { result[name] = track }
                addNext()
            }
        }
        return result
    }
}
