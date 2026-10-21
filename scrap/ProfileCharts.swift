import Foundation

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
    var title: String {
        switch self {
        case .artists: "Top artists"
        case .albums: "Top albums"
        case .tracks: "Top tracks"
        }
    }
}

struct ProfileChartEntry: Identifiable {
    let link: MusicLink
    let artist: String
    let count: Int
    var id: String { link.id }
}

@MainActor
enum TrackArtworkCache {
    static var urls: [String: [URL]] = [:]
}

extension LastFMClient {
    func profileChart(_ kind: ChartKind, period: ChartPeriod, limit: Int = 5) async throws -> [ProfileChartEntry] {
        guard let username else { return [] }
        let singular = String(kind.rawValue.dropLast())
        let method = "user.getTop" + kind.rawValue.capitalized
        let json = try await request(["method": method, "user": username, "period": period.rawValue, "limit": String(limit)])
        guard let root = json["top" + kind.rawValue] as? [String: Any] else { return [] }
        let rows = root[singular] as? [[String: Any]] ?? (root[singular] as? [String: Any]).map { [$0] } ?? []
        var entries: [ProfileChartEntry] = []
        for row in rows.prefix(limit) {
            guard var link = MusicLink.parse(row).first else { continue }
            let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            if kind == .tracks, link.imageURL == nil, limit <= 10, !Task.isCancelled {
                link.imageAlternatives = await trackArtwork(artist: artist, track: link.name)
                link.imageURL = link.imageAlternatives.first
            }
            let count = Self.count(row["playcount"]) ?? 0
            if !entries.contains(where: { $0.id == link.id }) { entries.append(ProfileChartEntry(link: link, artist: artist, count: count)) }
        }
        return entries
    }

    func trackArtwork(artist: String, track: String) async -> [URL] {
        let key = artist.lowercased() + "\n" + track.lowercased()
        if let cached = TrackArtworkCache.urls[key] { return cached }
        guard let json = try? await request(["method": "track.getInfo", "artist": artist, "track": track]) else { return [] }
        let album = (json["track"] as? [String: Any])?["album"] as? [String: Any]
        let urls = ArtworkCandidates.urls(album?["image"])
        TrackArtworkCache.urls[key] = urls
        return urls
    }
}
