import Foundation
import AppKit

struct ListeningDetails {
    var coverImage: NSImage?
    var coverURL: URL?
    var artistCount: Int?
    var trackCount: Int?
    var trackTags: [MusicLink] = []
    var artist = ArtistDetails()

    func summary(for track: PlayingTrack) -> String {
        guard let artistCount, let trackCount else { return "Listening history unavailable." }
        if artistCount == 0 { return "You've never scrobbled \(track.artist) before." }
        if trackCount == 0 { return "You've scrobbled \(track.artist) \(artistCount) times, but not this track." }
        return "You've scrobbled to \(track.artist) \(artistCount) times and \(track.title) \(trackCount) times."
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
    let playCount: String
    let url: URL?
    var avatarURL: URL? = nil
}

extension LastFMClient {
    func listeningDetails(for track: PlayingTrack, onUpdate: ((ListeningDetails) -> Void)? = nil) async -> ListeningDetails {
        var details = ListeningDetails()
        guard let username, isConfigured else { return details }
        if !track.album.isEmpty, !Task.isCancelled {
            if let json = try? await request(["method": "album.getInfo", "artist": track.artist, "album": track.album]),
               let album = json["album"] as? [String: Any] { details.coverURL = Self.cover(album["image"]) }
        }
        if let url = details.coverURL, !Task.isCancelled {
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
            request.timeoutInterval = 10
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                details.coverImage = NSImage(data: data)
            }
        }
        guard !Task.isCancelled else { return details }
        onUpdate?(details)
        do {
            let json = try await request(["method": "track.getInfo", "artist": track.artist, "track": track.title, "username": username])
            if let info = json["track"] as? [String: Any] {
                details.trackCount = Self.count(info["userplaycount"])
            }
        } catch { /* Missing metadata is not evidence of zero plays. */ }
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
            details.artist.similar = MusicLink.parse(similar?["artist"])
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
                    if let json = try? await request(["method": "track.getInfo", "artist": track.artist, "track": details.artist.topTracks[index].name]),
                       let info = json["track"] as? [String: Any], let album = info["album"] as? [String: Any] {
                        details.artist.topTracks[index].imageURL = Self.cover(album["image"])
                    }
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

    func recentScrobbles() async throws -> [RecentScrobble] {
        guard let username else { return [] }
        let json = try await request(["method": "user.getRecentTracks", "user": username, "limit": "50"])
        guard let root = json["recenttracks"] as? [String: Any] else { return [] }
        let rows = root["track"] as? [[String: Any]] ?? (root["track"] as? [String: Any]).map { [$0] } ?? []
        return rows.enumerated().compactMap { index, row in
            guard let date = row["date"] as? [String: Any], let timestamp = Self.count(date["uts"]),
                  let title = row["name"] as? String else { return nil }
            let artist = row["artist"] as? [String: Any]
            return RecentScrobble(id: "\(timestamp)-\(index)", title: title, artist: artist?["#text"] as? String ?? "", date: Date(timeIntervalSince1970: Double(timestamp)), coverURL: Self.cover(row["image"]), trackURL: MusicLink.parse(row).first?.url)
        }
    }

    func profile() async throws -> ListenerProfile? {
        guard let username else { return nil }
        let json = try await request(["method": "user.getInfo", "user": username])
        guard let info = json["user"] as? [String: Any] else { return nil }
        return ListenerProfile(name: info["name"] as? String ?? username, realName: info["realname"] as? String ?? "", playCount: String(Self.count(info["playcount"]) ?? 0), url: (info["url"] as? String).flatMap(URL.init(string:)), avatarURL: Self.cover(info["image"]))
    }

    private static func count(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        return value as? Int
    }

    private static func cover(_ value: Any?) -> URL? {
        let images = value as? [[String: Any]] ?? []
        return images.reversed().compactMap { ($0["#text"] as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
    }
}
