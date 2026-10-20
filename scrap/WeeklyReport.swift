import Foundation

struct WeeklyReport {
    struct Item: Identifiable {
        let name: String
        var artist = ""
        let count: Int
        var imageURL: URL? = nil
        let url: URL
        var id: String { url.absoluteString }
    }

    let week: DateInterval
    let scrobbles: Int
    let previousScrobbles: Int
    var topArtist: Item?
    var topAlbum: Item?
    var topTrack: Item?
    var newArtists: [Item] = []
    var newAlbums: [Item] = []
    var newTracks: [Item] = []

    static let discoveryCheckLimit = 25

    static func latestWeek(now: Date = .now) -> DateInterval {
        var calendar = Calendar.current
        calendar.firstWeekday = 7
        let current = calendar.dateInterval(of: .weekOfYear, for: now)!
        let friday = calendar.date(byAdding: .day, value: 6, to: current.start)!
        if now >= friday { return current }
        let start = calendar.date(byAdding: .day, value: -7, to: current.start)!
        return DateInterval(start: start, end: current.start)
    }

    static func nextReportDate(after week: DateInterval) -> Date {
        Calendar.current.date(byAdding: .day, value: 6, to: week.end)!
    }
}

private struct Play {
    let title: String
    let artist: String
    let album: String
    let date: Date
    let imageURL: URL?
}

extension LastFMClient {
    func weeklyReport(for week: DateInterval) async throws -> WeeklyReport {
        let previous = DateInterval(start: Calendar.current.date(byAdding: .day, value: -7, to: week.start)!, end: week.start)
        let plays = try await plays(from: week.start, to: .now)
        let previousScrobbles = try await scrobbleCount(in: previous)
        let inWeek = plays.filter { week.contains($0.date) && $0.date < week.end }

        func tally(_ plays: [Play], key: (Play) -> String) -> [String: (count: Int, play: Play)] {
            var result: [String: (count: Int, play: Play)] = [:]
            for play in plays {
                let k = key(play)
                result[k] = ((result[k]?.count ?? 0) + 1, result[k]?.play ?? play)
            }
            return result
        }
        let artistKey: (Play) -> String = { $0.artist.lowercased() }
        let albumKey: (Play) -> String = { $0.artist.lowercased() + "\n" + $0.album.lowercased() }
        let trackKey: (Play) -> String = { $0.artist.lowercased() + "\n" + $0.title.lowercased() }

        let weekArtists = tally(inWeek, key: artistKey)
        let weekAlbums = tally(inWeek.filter { !$0.album.isEmpty }, key: albumKey)
        let weekTracks = tally(inWeek, key: trackKey)
        let sinceArtists = tally(plays, key: artistKey)
        let sinceAlbums = tally(plays.filter { !$0.album.isEmpty }, key: albumKey)
        let sinceTracks = tally(plays, key: trackKey)

        func ranked(_ tally: [String: (count: Int, play: Play)]) -> [(key: String, count: Int, play: Play)] {
            tally.map { ($0.key, $0.value.count, $0.value.play) }.sorted { $0.count > $1.count }
        }
        func artistItem(_ entry: (key: String, count: Int, play: Play)) -> WeeklyReport.Item {
            .init(name: entry.play.artist, count: entry.count, url: PlayingTrack(title: "", artist: entry.play.artist, album: "", duration: nil).artistURL)
        }
        func albumItem(_ entry: (key: String, count: Int, play: Play)) -> WeeklyReport.Item {
            let play = entry.play
            return .init(name: play.album, artist: play.artist, count: entry.count, imageURL: play.imageURL,
                         url: PlayingTrack(title: "", artist: play.artist, album: play.album, duration: nil).albumURL)
        }
        func trackItem(_ entry: (key: String, count: Int, play: Play)) -> WeeklyReport.Item {
            let play = entry.play
            return .init(name: play.title, artist: play.artist, count: entry.count, imageURL: play.imageURL,
                         url: PlayingTrack(title: play.title, artist: play.artist, album: play.album, duration: nil).trackURL)
        }

        let artists = ranked(weekArtists), albums = ranked(weekAlbums), tracks = ranked(weekTracks)
        var report = WeeklyReport(week: week, scrobbles: inWeek.count, previousScrobbles: previousScrobbles,
                                  topArtist: artists.first.map(artistItem), topAlbum: albums.first.map(albumItem),
                                  topTrack: tracks.first.map(trackItem))

        let limit = WeeklyReport.discoveryCheckLimit
        report.newArtists = await newEntries(artists.prefix(limit), since: sinceArtists) { play in
            ["method": "artist.getInfo", "artist": play.artist]
        } userCount: { ($0["artist"] as? [String: Any])?["stats"] as? [String: Any] }.map(artistItem)
        report.newAlbums = await newEntries(albums.prefix(limit), since: sinceAlbums) { play in
            ["method": "album.getInfo", "artist": play.artist, "album": play.album]
        } userCount: { $0["album"] as? [String: Any] }.map(albumItem)
        report.newTracks = await newEntries(tracks.prefix(limit), since: sinceTracks) { play in
            ["method": "track.getInfo", "artist": play.artist, "track": play.title]
        } userCount: { $0["track"] as? [String: Any] }.map(trackItem)
        return report
    }

    private func newEntries(_ candidates: ArraySlice<(key: String, count: Int, play: Play)>,
                            since: [String: (count: Int, play: Play)],
                            params: (Play) -> [String: String],
                            userCount: @escaping ([String: Any]) -> [String: Any]?) async -> [(key: String, count: Int, play: Play)] {
        guard let username else { return [] }
        var result: [(key: String, count: Int, play: Play)] = []
        for batch in stride(from: candidates.startIndex, to: candidates.endIndex, by: 5).map({ candidates[$0..<min($0 + 5, candidates.endIndex)] }) {
            guard !Task.isCancelled else { break }
            await withTaskGroup(of: (Int, Bool).self) { group in
                for (offset, candidate) in batch.enumerated() {
                    var input = params(candidate.play)
                    input["username"] = username
                    let sinceCount = since[candidate.key]?.count ?? candidate.count
                    group.addTask {
                        guard let json = try? await self.request(input),
                              let total = Self.count(userCount(json)?["userplaycount"]) else { return (offset, false) }
                        return (offset, total <= sinceCount)
                    }
                }
                var isNew = Array(repeating: false, count: batch.count)
                for await (offset, value) in group { isNew[offset] = value }
                result += zip(batch, isNew).filter(\.1).map(\.0)
            }
        }
        return result
    }

    private func plays(from start: Date, to end: Date) async throws -> [Play] {
        func page(_ number: Int) async throws -> (plays: [Play], totalPages: Int) {
            guard let username else { return ([], 0) }
            let json = try await request(["method": "user.getRecentTracks", "user": username, "limit": "200", "page": String(number),
                                          "from": String(Int(start.timeIntervalSince1970)), "to": String(Int(end.timeIntervalSince1970))])
            let root = json["recenttracks"] as? [String: Any]
            let rows = root?["track"] as? [[String: Any]] ?? (root?["track"] as? [String: Any]).map { [$0] } ?? []
            let totalPages = Self.count((root?["@attr"] as? [String: Any])?["totalPages"]) ?? 1
            let plays = rows.compactMap { row -> Play? in
                guard let title = row["name"] as? String,
                      let uts = Self.count((row["date"] as? [String: Any])?["uts"]) else { return nil }
                return Play(title: title, artist: (row["artist"] as? [String: Any])?["#text"] as? String ?? "",
                            album: (row["album"] as? [String: Any])?["#text"] as? String ?? "",
                            date: Date(timeIntervalSince1970: TimeInterval(uts)),
                            imageURL: ArtworkCandidates.urls(row["image"]).first)
            }
            return (plays, totalPages)
        }
        let first = try await page(1)
        var plays = first.plays
        for number in stride(from: 2, through: first.totalPages, by: 1) {
            try Task.checkCancellation()
            plays += try await page(number).plays
        }
        return plays
    }

    private func scrobbleCount(in interval: DateInterval) async throws -> Int {
        guard let username else { return 0 }
        let json = try await request(["method": "user.getRecentTracks", "user": username, "limit": "1",
                                      "from": String(Int(interval.start.timeIntervalSince1970)),
                                      "to": String(Int(interval.end.timeIntervalSince1970))])
        let attributes = (json["recenttracks"] as? [String: Any])?["@attr"] as? [String: Any]
        return Self.count(attributes?["total"]) ?? 0
    }
}
