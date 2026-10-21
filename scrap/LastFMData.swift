import Foundation

enum ArtworkCandidates {
    static func urls(_ value: Any?) -> [URL] {
        let images = value as? [[String: Any]] ?? []
        var seen = Set<URL>()
        return images.reversed().compactMap { row in
            guard let raw = row["#text"] as? String, let url = URL(string: raw),
                  url.scheme == "https", !raw.contains("2a96cbd8b46e442fc41c2b86b821562f"),
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }
}

struct MusicLink: Identifiable {
    let name: String
    let url: URL
    var imageURL: URL? = nil
    var imageAlternatives: [URL] = []
    var id: String { url.absoluteString }

    static func parse(_ value: Any?, limit: Int = 20) -> [MusicLink] {
        let rows = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
        var seen = Set<URL>()
        return Array(rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty,
                  let raw = row["url"] as? String, var url = URLComponents(string: raw),
                  ["http", "https"].contains(url.scheme ?? ""),
                  let host = url.host, host == "last.fm" || host.hasSuffix(".last.fm") else { return nil as MusicLink? }
            url.scheme = "https"
            guard let destination = url.url, seen.insert(destination).inserted else { return nil }
            let images = ArtworkCandidates.urls(row["image"])
            return MusicLink(name: name, url: destination, imageURL: images.first, imageAlternatives: images)
        }.prefix(limit))
    }
}

struct ArtistDetails {
    var url: URL?
    var biography = ""
    var totalPlays: Int?
    var tags: [MusicLink] = []
    var similar: [MusicLink] = []
    var topTracks: [MusicLink] = []
    var topAlbums: [MusicLink] = []

    static func plainBiography(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<a\\b[^>]*>.*?</a>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        var text = stripped
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ListeningDetails {
    var artistCount: Int?
    var trackCount: Int?
    var trackTags: [MusicLink] = []
    var artist = ArtistDetails()

    func summary(for track: PlayingTrack) -> String {
        guard let artistCount, let trackCount else { return "Listening history unavailable." }
        if artistCount == 0 { return "You've never scrobbled \(track.artist) before." }
        if trackCount == 0 { return "You've scrobbled \(track.artist) \(artistCount) times, but not this track." }
        return "You've scrobbled \(track.artist) \(artistCount) times and \(track.title) \(trackCount) times."
    }
}

struct RecentScrobble: Identifiable {
    let id: String
    let title: String
    let artist: String
    let date: Date
    var coverURL: URL? = nil
    var trackURL: URL? = nil

    var destination: URL {
        if let trackURL { return trackURL }
        return URL(string: "https://www.last.fm/music")!
            .appendingPathComponent(artist).appendingPathComponent("_").appendingPathComponent(title)
    }
}

struct ListenerProfile {
    let name: String
    let realName: String
    let playCount: Int
    let url: URL?
    var avatarURL: URL? = nil
}

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

enum TrackArtworkCache {
    static var urls: [String: URL?] = [:]
}

enum ChartPeriod: String, CaseIterable, Identifiable {
    case week = "7day", month = "1month", year = "12month", overall
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .year: "Last 365 days"
        case .overall: "All time"
        }
    }
}

enum ChartKind: String, CaseIterable {
    case artists, albums, tracks
    var title: String { "Top " + rawValue }
}

struct ProfileChartEntry: Identifiable {
    let link: MusicLink
    let artist: String
    let count: Int
    var id: String { link.id }
}

extension LastFMClient {
    func listeningDetails(for track: PlayingTrack) async -> ListeningDetails {
        var details = ListeningDetails()
        guard let username, isConfigured else { return details }
        do {
            let json = try await request(["method": "track.getInfo", "artist": track.artist, "track": track.title, "username": username])
            if let info = json["track"] as? [String: Any] {
                details.trackCount = Self.count(info["userplaycount"])
            }
        } catch {}
        do {
            let json = try await request(["method": "artist.getInfo", "artist": track.artist, "username": username])
            let info = json["artist"] as? [String: Any]
            let stats = info?["stats"] as? [String: Any]
            details.artistCount = Self.count(stats?["userplaycount"])
            details.artist.totalPlays = Self.count(stats?["playcount"] ?? stats?["plays"])
            details.artist.url = MusicLink.parse(info).first?.url
            let bio = info?["bio"] as? [String: Any]
            details.artist.biography = ArtistDetails.plainBiography(bio?["summary"] as? String ?? "")
            let tags = info?["tags"] as? [String: Any]
            details.artist.tags = MusicLink.parse(tags?["tag"], limit: 5)
            let similar = info?["similar"] as? [String: Any]
            details.artist.similar = MusicLink.parse(similar?["artist"], limit: 10)
        } catch { }
        if !Task.isCancelled,
           let json = try? await request(["method": "track.getTopTags", "artist": track.artist, "track": track.title]),
           let tags = json["toptags"] as? [String: Any] {
            details.trackTags = MusicLink.parse(tags["tag"], limit: 5)
        }
        if !Task.isCancelled {
            if let json = try? await request(["method": "artist.getTopTracks", "artist": track.artist, "limit": "3"]),
               let root = json["toptracks"] as? [String: Any] {
                details.artist.topTracks = MusicLink.parse(root["track"], limit: 3)
                for index in details.artist.topTracks.indices where details.artist.topTracks[index].imageURL == nil {
                    guard !Task.isCancelled else { return details }
                    details.artist.topTracks[index].imageURL = await trackArtwork(artist: track.artist, track: details.artist.topTracks[index].name)
                }
            }
            if !Task.isCancelled,
               let json = try? await request(["method": "artist.getTopAlbums", "artist": track.artist, "limit": "3"]),
               let root = json["topalbums"] as? [String: Any] {
                details.artist.topAlbums = MusicLink.parse(root["album"], limit: 3)
            }
        }
        return details
    }

    func recentScrobbles(limit: Int = 50) async throws -> [RecentScrobble] {
        guard let username else { return [] }
        let json = try await request(["method": "user.getRecentTracks", "user": username, "limit": String(limit)])
        guard let root = json["recenttracks"] as? [String: Any] else { return [] }
        let rows = root["track"] as? [[String: Any]] ?? (root["track"] as? [String: Any]).map { [$0] } ?? []
        return rows.enumerated().compactMap { index, row in
            guard let date = row["date"] as? [String: Any], let timestamp = Self.count(date["uts"]),
                  let title = row["name"] as? String else { return nil }
            let artist = row["artist"] as? [String: Any]
            return RecentScrobble(id: "\(timestamp)-\(index)", title: title, artist: artist?["#text"] as? String ?? "",
                                  date: Date(timeIntervalSince1970: Double(timestamp)),
                                  coverURL: ArtworkCandidates.urls(row["image"]).first, trackURL: MusicLink.parse(row).first?.url)
        }
    }

    func albumCoverURL(artist: String, album: String) async -> URL? {
        guard !album.isEmpty,
              let json = try? await request(["method": "album.getInfo", "artist": artist, "album": album]) else { return nil }
        return ArtworkCandidates.urls((json["album"] as? [String: Any])?["image"]).first
    }

    func profile() async throws -> ListenerProfile? {
        guard let username else { return nil }
        let json = try await request(["method": "user.getInfo", "user": username])
        guard let info = json["user"] as? [String: Any] else { return nil }
        return ListenerProfile(name: info["name"] as? String ?? username, realName: info["realname"] as? String ?? "",
                               playCount: Self.count(info["playcount"]) ?? 0,
                               url: (info["url"] as? String).flatMap(URL.init(string:)),
                               avatarURL: ArtworkCandidates.urls(info["image"]).first)
    }

    func friends() async throws -> [FriendActivity] {
        guard let username else { return [] }
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
        var seen = Set<String>()
        var friends = result.filter { seen.insert($0.name).inserted }
        let recent = await recentTracks(for: friends.map(\.name))
        for index in friends.indices {
            if let track = recent[friends[index].name] { friends[index].apply(recentTrack: track) }
        }
        return friends
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

    func profileChart(_ kind: ChartKind, period: ChartPeriod, limit: Int = 10) async throws -> [ProfileChartEntry] {
        guard let username else { return [] }
        let singular = String(kind.rawValue.dropLast())
        let method = "user.getTop" + kind.rawValue.capitalized
        let json = try await request(["method": method, "user": username, "period": period.rawValue, "limit": String(limit)])
        guard let root = json["top" + kind.rawValue] as? [String: Any] else { return [] }
        let rows = root[singular] as? [[String: Any]] ?? (root[singular] as? [String: Any]).map { [$0] } ?? []
        var entries: [ProfileChartEntry] = []
        for row in rows.prefix(limit) {
            guard let link = MusicLink.parse(row).first else { continue }
            let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            let count = Self.count(row["playcount"]) ?? 0
            if !entries.contains(where: { $0.id == link.id }) { entries.append(ProfileChartEntry(link: link, artist: artist, count: count)) }
        }
        return entries
    }

    func trackArtwork(artist: String, track: String) async -> URL? {
        let key = artist.lowercased() + "\n" + track.lowercased()
        if let cached = TrackArtworkCache.urls[key] { return cached }
        guard let json = try? await request(["method": "track.getInfo", "artist": artist, "track": track]) else { return nil }
        let album = (json["track"] as? [String: Any])?["album"] as? [String: Any]
        let url = ArtworkCandidates.urls(album?["image"]).first
        TrackArtworkCache.urls[key] = url
        return url
    }

    nonisolated static func count(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        return value as? Int
    }
}
