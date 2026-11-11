import Foundation

// MARK: - Periods

nonisolated enum ReportKind: String, CaseIterable, Identifiable, Codable {
    case week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }
    var noun: String { rawValue }
    fileprivate var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

/// A report's time span, in the user's time zone. Weeks run Saturday to Friday.
nonisolated struct ReportPeriod: Hashable, Codable {
    let kind: ReportKind
    let interval: DateInterval

    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 7
        return calendar
    }

    static func containing(_ date: Date, kind: ReportKind) -> ReportPeriod {
        ReportPeriod(kind: kind, interval: calendar.dateInterval(of: kind.component, for: date)!)
    }

    /// The newest period whose report is out.
    static func latest(_ kind: ReportKind, now: Date = .now) -> ReportPeriod {
        var period = containing(now, kind: kind)
        while period.releaseDate > now { period = period.previous }
        return period
    }

    /// Weekly reports come out on the week's Friday. Monthly and yearly reports come out on the first
    /// Friday after the period ends, at the same time as the report notifications.
    var releaseDate: Date {
        switch kind {
        case .week:
            Self.calendar.date(byAdding: .day, value: 6, to: interval.start)!
        case .month, .year:
            Notifier.upcomingReportDates(count: 1, after: interval.end.addingTimeInterval(-1)).first ?? interval.end
        }
    }

    func isReleased(now: Date = .now) -> Bool { releaseDate <= now }
    var previous: ReportPeriod { Self.containing(interval.start.addingTimeInterval(-1), kind: kind) }
    var next: ReportPeriod { Self.containing(interval.end.addingTimeInterval(1), kind: kind) }
    var lastDay: Date { Self.calendar.date(byAdding: .day, value: -1, to: interval.end)! }

    var title: String {
        switch kind {
        case .week:
            let sameYear = Self.calendar.isDate(interval.start, equalTo: .now, toGranularity: .year)
                && Self.calendar.isDate(lastDay, equalTo: .now, toGranularity: .year)
            let range = "\(interval.start.formatted(.dateTime.month().day())) – \(lastDay.formatted(.dateTime.month().day()))"
            return sameYear ? range : "\(range), \(lastDay.formatted(.dateTime.year()))"
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        }
    }
}

// MARK: - Report

nonisolated struct ListeningReport: Codable {
    struct Item: Identifiable, Codable {
        let name: String
        var artist = ""
        let count: Int
        var imageURL: URL? = nil
        let url: URL
        var id: String { url.absoluteString }
    }

    struct Tag: Identifiable, Codable {
        let name: String
        /// Relative to the top tag, which is 1.
        let weight: Double
        let url: URL
        var id: String { name }
    }

    /// The busiest day or month in a period, with what was played most then.
    struct Highlight: Codable {
        let interval: DateInterval
        let scrobbles: Int
        var topArtist: Item?
        var topAlbum: Item?
        var topTrack: Item?
    }

    let period: ReportPeriod
    let scrobbles: Int
    let previousScrobbles: Int
    var topArtist: Item?
    var topAlbum: Item?
    var topTrack: Item?
    var newArtists: [Item] = []
    var newAlbums: [Item] = []
    var newTracks: [Item] = []
    var topTags: [Tag] = []
    /// Scrobbles per hour of the day (0–23) in the user's time zone.
    var hourly: [Int] = []
    var busiestDay: Highlight?
    /// Scrobbles per month (January first), for yearly reports.
    var monthly: [Int] = []
    var busiestMonth: Highlight?
    var builtAt = Date()

    static let discoveryCheckLimit = 25

    /// Built after the period ended, so it won't change.
    var isFinal: Bool { builtAt >= period.interval.end }

    var peakHour: Int? {
        guard let peak = hourly.max(), peak > 0 else { return nil }
        return hourly.firstIndex(of: peak)
    }

    static func latestWeek(now: Date = .now) -> DateInterval { ReportPeriod.latest(.week, now: now).interval }
}

nonisolated struct ScrobbledPlay {
    let title: String
    let artist: String
    let album: String
    let date: Date
    let imageURL: URL?
}

// MARK: - Tallies

nonisolated extension ListeningReport {
    typealias Ranked = (key: String, count: Int, play: ScrobbledPlay)

    static func artistKey(_ artist: String) -> String { artist.lowercased() }
    static func albumKey(artist: String, album: String) -> String { artist.lowercased() + "\n" + album.lowercased() }
    static func trackKey(artist: String, title: String) -> String { artist.lowercased() + "\n" + title.lowercased() }

    static func ranked(_ plays: [ScrobbledPlay], key: (ScrobbledPlay) -> String) -> [Ranked] {
        var counts: [String: (count: Int, play: ScrobbledPlay, order: Int)] = [:]
        for (index, play) in plays.enumerated() {
            let k = key(play)
            counts[k] = ((counts[k]?.count ?? 0) + 1, counts[k]?.play ?? play, counts[k]?.order ?? index)
        }
        return counts.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.order < $1.value.order }
            .map { ($0.key, $0.value.count, $0.value.play) }
    }

    static func rankings(_ plays: [ScrobbledPlay]) -> (artists: [Ranked], albums: [Ranked], tracks: [Ranked]) {
        (ranked(plays) { artistKey($0.artist) },
         ranked(plays.filter { !$0.album.isEmpty }) { albumKey(artist: $0.artist, album: $0.album) },
         ranked(plays) { trackKey(artist: $0.artist, title: $0.title) })
    }

    static func artistItem(_ entry: Ranked) -> Item {
        Item(name: entry.play.artist, count: entry.count,
             url: PlayingTrack(title: "", artist: entry.play.artist, album: "", duration: nil).artistURL)
    }

    static func albumItem(_ entry: Ranked) -> Item {
        let play = entry.play
        return Item(name: play.album, artist: play.artist, count: entry.count, imageURL: play.imageURL,
                    url: PlayingTrack(title: "", artist: play.artist, album: play.album, duration: nil).albumURL)
    }

    static func trackItem(_ entry: Ranked) -> Item {
        let play = entry.play
        return Item(name: play.title, artist: play.artist, count: entry.count, imageURL: play.imageURL,
                    url: PlayingTrack(title: play.title, artist: play.artist, album: play.album, duration: nil).trackURL)
    }

    static func hourly(_ plays: [ScrobbledPlay], calendar: Calendar = ReportPeriod.calendar) -> [Int] {
        var hours = Array(repeating: 0, count: 24)
        for play in plays { hours[calendar.component(.hour, from: play.date)] += 1 }
        return hours
    }

    static func monthly(_ plays: [ScrobbledPlay], calendar: Calendar = ReportPeriod.calendar) -> [Int] {
        var months = Array(repeating: 0, count: 12)
        for play in plays { months[calendar.component(.month, from: play.date) - 1] += 1 }
        return months
    }

    /// The day or month with the most scrobbles (the earliest one on a tie) and its top artist, album and track.
    static func busiest(_ plays: [ScrobbledPlay], by component: Calendar.Component,
                        calendar: Calendar = ReportPeriod.calendar) -> Highlight? {
        var groups: [Date: [ScrobbledPlay]] = [:]
        for play in plays {
            guard let start = calendar.dateInterval(of: component, for: play.date)?.start else { continue }
            groups[start, default: []].append(play)
        }
        guard let best = groups.max(by: { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }),
              let interval = calendar.dateInterval(of: component, for: best.key) else { return nil }
        let top = rankings(best.value)
        return Highlight(interval: interval, scrobbles: best.value.count,
                         topArtist: top.artists.first.map(artistItem), topAlbum: top.albums.first.map(albumItem),
                         topTrack: top.tracks.first.map(trackItem))
    }

    /// Combines the top artists' last.fm tags, weighted by how much each artist was played.
    static func combineTags(_ artistTags: [(plays: Int, artist: String, tags: [(name: String, count: Int)])], limit: Int = 5) -> [Tag] {
        let ignored: Set<String> = ["seen live", "favorites", "favourites", "favorite", "favourite", "albums i own",
                                    "under 2000 listeners", "spotify", "my top artists", "all"]
        let artistNames = Set(artistTags.map { $0.artist.lowercased() })
        var weights: [String: (name: String, weight: Double)] = [:]
        for entry in artistTags {
            for tag in entry.tags.prefix(10) where tag.count > 0 {
                let key = tag.name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !ignored.contains(key), !artistNames.contains(key) else { continue }
                weights[key] = (weights[key]?.name ?? tag.name.lowercased(),
                                (weights[key]?.weight ?? 0) + Double(entry.plays) * Double(tag.count) / 100)
            }
        }
        let top = weights.values.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.name < $1.name }.prefix(limit)
        guard let maxWeight = top.first?.weight, maxWeight > 0 else { return [] }
        return top.compactMap { tag in
            let path = tag.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#+&"))) ?? tag.name
            guard let url = URL(string: "https://www.last.fm/tag/\(path)") else { return nil }
            return Tag(name: tag.name, weight: tag.weight / maxWeight, url: url)
        }
    }
}

// MARK: - Building

extension LastFMClient {
    func listeningReport(for period: ReportPeriod, progress: ((Int, Int) -> Void)? = nil) async throws -> ListeningReport {
        let builtAt = Date()
        let start = period.interval.start
        let previousScrobbles = try await scrobbleCount(in: period.previous.interval)
        let plays = try await scrobbledPlays(from: start, to: min(period.interval.end, builtAt), progress: progress)
            .filter { $0.date >= start && $0.date < period.interval.end }
        let (artists, albums, tracks) = ListeningReport.rankings(plays)

        var report = ListeningReport(period: period, scrobbles: plays.count, previousScrobbles: previousScrobbles,
                                     topArtist: artists.first.map(ListeningReport.artistItem),
                                     topAlbum: albums.first.map(ListeningReport.albumItem),
                                     topTrack: tracks.first.map(ListeningReport.trackItem), builtAt: builtAt)
        report.hourly = ListeningReport.hourly(plays)
        if period.kind != .week { report.busiestDay = ListeningReport.busiest(plays, by: .day) }
        if period.kind == .year {
            report.monthly = ListeningReport.monthly(plays)
            report.busiestMonth = ListeningReport.busiest(plays, by: .month)
        }
        guard !plays.isEmpty else { return report }
        report.topTags = await topTags(for: Array(artists.prefix(10)))

        // An item is new if all of the user's plays of it happened since the period started.
        let limit = ListeningReport.discoveryCheckLimit
        let since = await chartCounts(since: start)
        report.newArtists = await newEntries(artists.prefix(limit), since: since.artists) { play in
            ["method": "artist.getInfo", "artist": play.artist]
        } userCount: { ($0["artist"] as? [String: Any])?["stats"] as? [String: Any] }.map(ListeningReport.artistItem)
        report.newAlbums = await newEntries(albums.prefix(limit), since: since.albums) { play in
            ["method": "album.getInfo", "artist": play.artist, "album": play.album]
        } userCount: { $0["album"] as? [String: Any] }.map(ListeningReport.albumItem)
        report.newTracks = await newEntries(tracks.prefix(limit), since: since.tracks) { play in
            ["method": "track.getInfo", "artist": play.artist, "track": play.title]
        } userCount: { $0["track"] as? [String: Any] }.map(ListeningReport.trackItem)
        return report
    }

    private func topTags(for artists: [ListeningReport.Ranked]) async -> [ListeningReport.Tag] {
        var results: [(plays: Int, artist: String, tags: [(name: String, count: Int)])] = []
        await withTaskGroup(of: (Int, String, [(name: String, count: Int)]).self) { group in
            for entry in artists {
                let artist = entry.play.artist
                group.addTask {
                    guard let json = try? await self.request(["method": "artist.getTopTags", "artist": artist]),
                          let root = json["toptags"] as? [String: Any] else { return (entry.count, artist, []) }
                    let rows = root["tag"] as? [[String: Any]] ?? (root["tag"] as? [String: Any]).map { [$0] } ?? []
                    let tags = rows.compactMap { row -> (name: String, count: Int)? in
                        guard let name = row["name"] as? String else { return nil }
                        return (name, Self.count(row["count"]) ?? 0)
                    }
                    return (entry.count, artist, tags)
                }
            }
            for await result in group { results.append((result.0, result.1, result.2)) }
        }
        return ListeningReport.combineTags(results.sorted { $0.plays > $1.plays })
    }

    /// Play counts from `start` until now, from last.fm's charts (each capped at 1,000 entries).
    private func chartCounts(since start: Date) async -> (artists: [String: Int], albums: [String: Int], tracks: [String: Int]) {
        guard let username else { return ([:], [:], [:]) }
        let range = ["user": username, "from": String(Int(start.timeIntervalSince1970)), "to": String(Int(Date().timeIntervalSince1970))]
        func rows(_ method: String, root: String, row: String) async -> [[String: Any]] {
            guard let json = try? await request(range.merging(["method": method]) { $1 }),
                  let container = json[root] as? [String: Any] else { return [] }
            return container[row] as? [[String: Any]] ?? (container[row] as? [String: Any]).map { [$0] } ?? []
        }
        func counts(_ rows: [[String: Any]], key: ([String: Any], String) -> String) -> [String: Int] {
            var counts: [String: Int] = [:]
            for item in rows {
                guard let name = item["name"] as? String, let plays = Self.count(item["playcount"]) else { continue }
                counts[key(item, name), default: 0] += plays
            }
            return counts
        }
        func artistName(_ item: [String: Any]) -> String { (item["artist"] as? [String: Any])?["#text"] as? String ?? "" }
        let artists = counts(await rows("user.getWeeklyArtistChart", root: "weeklyartistchart", row: "artist")) { ListeningReport.artistKey($1) }
        let albums = counts(await rows("user.getWeeklyAlbumChart", root: "weeklyalbumchart", row: "album")) {
            ListeningReport.albumKey(artist: artistName($0), album: $1)
        }
        let tracks = counts(await rows("user.getWeeklyTrackChart", root: "weeklytrackchart", row: "track")) {
            ListeningReport.trackKey(artist: artistName($0), title: $1)
        }
        return (artists, albums, tracks)
    }

    private func newEntries(_ candidates: ArraySlice<ListeningReport.Ranked>,
                            since: [String: Int],
                            params: (ScrobbledPlay) -> [String: String],
                            userCount: @escaping ([String: Any]) -> [String: Any]?) async -> [ListeningReport.Ranked] {
        guard let username else { return [] }
        var result: [ListeningReport.Ranked] = []
        for batch in stride(from: candidates.startIndex, to: candidates.endIndex, by: 5).map({ candidates[$0..<min($0 + 5, candidates.endIndex)] }) {
            guard !Task.isCancelled else { break }
            await withTaskGroup(of: (Int, Bool).self) { group in
                for (offset, candidate) in batch.enumerated() {
                    var input = params(candidate.play)
                    input["username"] = username
                    let sinceCount = max(since[candidate.key] ?? 0, candidate.count)
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

    /// Every scrobble between two dates. Pages are fetched a few at a time so long periods stay quick.
    func scrobbledPlays(from start: Date, to end: Date, progress: ((Int, Int) -> Void)? = nil) async throws -> [ScrobbledPlay] {
        let first = try await recentTracksPage(1, from: start, to: end)
        let total = first.totalPages
        progress?(1, total)
        var pages: [Int: [ScrobbledPlay]] = [1: first.plays]
        if total > 1 {
            try await withThrowingTaskGroup(of: (Int, [ScrobbledPlay]).self) { group in
                var next = 2
                while next <= min(total, 4) {
                    let number = next
                    group.addTask { (number, try await self.recentTracksPage(number, from: start, to: end).plays) }
                    next += 1
                }
                while let (number, plays) = try await group.next() {
                    pages[number] = plays
                    progress?(pages.count, total)
                    if next <= total {
                        let number = next
                        group.addTask { (number, try await self.recentTracksPage(number, from: start, to: end).plays) }
                        next += 1
                    }
                }
            }
        }
        // New scrobbles can shift pages while they load, so drop any repeats.
        var seen = Set<String>()
        return pages.keys.sorted().flatMap { pages[$0] ?? [] }.filter {
            seen.insert("\(Int($0.date.timeIntervalSince1970))\n\($0.artist)\n\($0.title)").inserted
        }
    }

    private func recentTracksPage(_ number: Int, from start: Date, to end: Date) async throws -> (plays: [ScrobbledPlay], totalPages: Int) {
        guard let username else { return ([], 0) }
        let input = ["method": "user.getRecentTracks", "user": username, "limit": "200", "page": String(number),
                     "from": String(Int(start.timeIntervalSince1970)), "to": String(Int(end.timeIntervalSince1970))]
        var attempt = 0
        while true {
            do {
                let json = try await request(input)
                let root = json["recenttracks"] as? [String: Any]
                let rows = root?["track"] as? [[String: Any]] ?? (root?["track"] as? [String: Any]).map { [$0] } ?? []
                let totalPages = Self.count((root?["@attr"] as? [String: Any])?["totalPages"]) ?? 1
                let plays = rows.compactMap { row -> ScrobbledPlay? in
                    guard let title = row["name"] as? String,
                          let uts = Self.count((row["date"] as? [String: Any])?["uts"]) else { return nil }
                    return ScrobbledPlay(title: title, artist: (row["artist"] as? [String: Any])?["#text"] as? String ?? "",
                                         album: (row["album"] as? [String: Any])?["#text"] as? String ?? "",
                                         date: Date(timeIntervalSince1970: TimeInterval(uts)),
                                         imageURL: ArtworkCandidates.urls(row["image"]).first)
                }
                return (plays, totalPages)
            } catch {
                // Retry rate limits and temporary failures a couple of times before giving up.
                let code = (error as NSError).domain == "LastFM" ? (error as NSError).code : 0
                attempt += 1
                guard attempt < 3, [0, 8, 11, 16, 29].contains(code) else { throw error }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    private func scrobbleCount(in interval: DateInterval) async throws -> Int {
        guard let username else { return 0 }
        let json = try await request(["method": "user.getRecentTracks", "user": username, "limit": "1",
                                      "from": String(Int(interval.start.timeIntervalSince1970)),
                                      "to": String(Int(interval.end.timeIntervalSince1970) - 1)])
        let attributes = (json["recenttracks"] as? [String: Any])?["@attr"] as? [String: Any]
        return Self.count(attributes?["total"]) ?? 0
    }
}

// MARK: - Storage

/// Keeps the four most recent weekly reports on disk, per last.fm account.
enum ReportStore {
    static let keptWeeks = 4

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Reports", isDirectory: true)
    }

    private static func prefix(_ username: String) -> String {
        username.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } + "-week-"
    }

    private static func fileURL(_ username: String, _ period: ReportPeriod) -> URL? {
        directory?.appendingPathComponent(prefix(username) + "\(Int(period.interval.start.timeIntervalSince1970)).json")
    }

    static func isStored(_ period: ReportPeriod, now: Date = .now) -> Bool {
        guard period.kind == .week else { return false }
        let oldest = ReportPeriod.calendar.date(byAdding: .weekOfYear, value: -(keptWeeks - 1),
                                                to: ReportPeriod.latest(.week, now: now).interval.start)!
        return period.interval.start >= oldest
    }

    static func load(_ period: ReportPeriod, username: String) -> ListeningReport? {
        guard isStored(period), let url = fileURL(username, period), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ListeningReport.self, from: data)
    }

    static func save(_ report: ListeningReport, username: String, now: Date = .now) {
        guard isStored(report.period, now: now), let directory, let url = fileURL(username, report.period),
              let data = try? JSONEncoder().encode(report) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        prune(username: username, now: now)
    }

    static func prune(username: String, now: Date = .now) {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = prefix(username)
        let oldest = ReportPeriod.calendar.date(byAdding: .weekOfYear, value: -(keptWeeks - 1),
                                                to: ReportPeriod.latest(.week, now: now).interval.start)!
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".json") {
            let stamp = file.dropFirst(prefix.count).dropLast(5)
            guard let seconds = TimeInterval(stamp), Date(timeIntervalSince1970: seconds) < oldest else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
