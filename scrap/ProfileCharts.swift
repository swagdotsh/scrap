import Foundation

enum ChartPeriod: String, CaseIterable, Identifiable {
    case day = "24hour", week = "7day", month = "1month", sixMonths = "6month", thisYear, year = "12month", overall
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .sixMonths: "Last 6 months"
        case .thisYear: String(Calendar.current.component(.year, from: Date()))
        case .year: "Last 365 days"
        case .overall: "All time"
        }
    }

    var customRangeStart: Date? {
        switch self {
        case .day: Date().addingTimeInterval(-24 * 3600)
        case .thisYear: Calendar.current.dateInterval(of: .year, for: Date())?.start
        default: nil
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

@MainActor
enum AlbumArtworkCache {
    static var urls: [String: [URL]] = [:]
}

@MainActor
enum YearChartCache {
    static var entries: [String: (entries: [ProfileChartEntry], fetched: Date)] = [:]
    static let lifetime: TimeInterval = 5 * 60
}

extension LastFMClient {
    func profileChart(_ kind: ChartKind, period: ChartPeriod, limit: Int = 5) async throws -> [ProfileChartEntry] {
        guard let username else { return [] }
        let singular = String(kind.rawValue.dropLast())
        var entries: [ProfileChartEntry]
        if let start = period.customRangeStart {
            entries = Array(try await rangeChart(kind, period: period, user: username, from: start).prefix(limit))
        } else {
            let method = "user.getTop" + kind.rawValue.capitalized
            let json = try await request(["method": method, "user": username, "period": period.rawValue, "limit": String(limit)])
            guard let root = json["top" + kind.rawValue] as? [String: Any] else { return [] }
            entries = Self.chartEntries(root[singular], limit: limit)
        }
        guard kind != .artists, limit <= 10 else { return entries }
        for index in entries.indices where entries[index].link.imageURL == nil {
            guard !Task.isCancelled else { break }
            let entry = entries[index]
            let urls = kind == .tracks
                ? await trackArtwork(artist: entry.artist, track: entry.link.name)
                : await albumArtwork(artist: entry.artist, album: entry.link.name)
            var link = entry.link
            link.imageAlternatives = urls
            link.imageURL = urls.first
            entries[index] = ProfileChartEntry(link: link, artist: entry.artist, count: entry.count)
        }
        return entries
    }

    private func rangeChart(_ kind: ChartKind, period: ChartPeriod, user: String, from start: Date) async throws -> [ProfileChartEntry] {
        let singular = String(kind.rawValue.dropLast())
        let key = "\(user.lowercased())|\(kind.rawValue)|\(period.rawValue)"
        if let cached = YearChartCache.entries[key], Date().timeIntervalSince(cached.fetched) < YearChartCache.lifetime {
            return cached.entries
        }
        let json = try await request(["method": "user.getWeekly\(singular.capitalized)Chart", "user": user,
                                      "from": String(Int(start.timeIntervalSince1970)),
                                      "to": String(Int(Date().timeIntervalSince1970))])
        guard let root = json["weekly\(singular)chart"] as? [String: Any] else { return [] }
        let entries = Self.chartEntries(root[singular], limit: .max).sorted { $0.count > $1.count }
        YearChartCache.entries[key] = (entries, Date())
        return entries
    }

    static func chartEntries(_ value: Any?, limit: Int, countKey: String = "playcount") -> [ProfileChartEntry] {
        let rows = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
        var seen = Set<String>()
        var entries: [ProfileChartEntry] = []
        for row in rows {
            guard entries.count < limit else { break }
            guard let link = MusicLink.parse(row).first, seen.insert(link.id).inserted else { continue }
            let artistRow = row["artist"] as? [String: Any]
            let artist = artistRow?["name"] as? String ?? artistRow?["#text"] as? String ?? row["artist"] as? String ?? ""
            entries.append(ProfileChartEntry(link: link, artist: artist, count: Self.count(row[countKey]) ?? 0))
        }
        return entries
    }

    func libraryCount(_ kind: ChartKind) async -> Int? {
        guard let username else { return nil }
        let json = try? await request(["method": "user.getTop" + kind.rawValue.capitalized, "user": username,
                                       "period": "overall", "limit": "1"])
        let attributes = (json?["top" + kind.rawValue] as? [String: Any])?["@attr"] as? [String: Any]
        return Self.count(attributes?["total"])
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

    func albumArtwork(artist: String, album: String) async -> [URL] {
        guard !album.isEmpty else { return [] }
        let key = artist.lowercased() + "\n" + album.lowercased()
        if let cached = AlbumArtworkCache.urls[key] { return cached }
        guard let json = try? await request(["method": "album.getInfo", "artist": artist, "album": album]) else { return [] }
        let urls = ArtworkCandidates.urls((json["album"] as? [String: Any])?["image"])
        AlbumArtworkCache.urls[key] = urls
        return urls
    }
}
