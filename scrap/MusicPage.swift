import SwiftUI
import UIKit
import Charts

// MARK: - Model

/// An artist, album or track page that scrap can show in-app instead of opening last.fm.
enum MusicItem: Hashable, Identifiable {
    case artist(String)
    case album(artist: String, name: String)
    case track(artist: String, name: String)

    var id: String { url.absoluteString }

    var name: String {
        switch self {
        case .artist(let name), .album(_, let name), .track(_, let name): name
        }
    }

    var artist: String {
        switch self {
        case .artist(let name), .album(let name, _), .track(let name, _): name
        }
    }

    var url: URL {
        switch self {
        case .artist(let artist): Self.lastFMURL([artist])
        case .album(let artist, let name): Self.lastFMURL([artist, name])
        case .track(let artist, let name): Self.lastFMURL([artist, "_", name])
        }
    }

    /// Reads a last.fm `/music/...` link. Other last.fm pages (tags, users) and other sites return nil.
    init?(url: URL) {
        guard let host = url.host?.lowercased(), host == "last.fm" || host.hasSuffix(".last.fm"),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        var parts = path.split(separator: "/").map(String.init)
        if parts.count > 1, parts[0].count == 2, parts[1] == "music" { parts.removeFirst() } // localized, e.g. /de/music
        guard parts.first == "music" else { return nil }
        let names = parts.dropFirst()
            .filter { !$0.hasPrefix("+") } // +noredirect, +wiki, +similar…
            .map { ($0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? $0) }
        guard let artist = names.first, !artist.isEmpty else { return nil }
        switch names.count {
        case 1: self = .artist(artist)
        case 2: self = names[1] == "_" ? .artist(artist) : .album(artist: artist, name: names[1])
        default: self = .track(artist: artist, name: names[2])
        }
    }

    private static func lastFMURL(_ components: [String]) -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~ ")
        let path = components.map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: " ", with: "+")
        }.joined(separator: "/")
        return URL(string: "https://www.last.fm/music/" + path)!
    }
}

struct AlbumTrack: Identifiable {
    let rank: Int
    let name: String
    let url: URL
    let duration: TimeInterval?
    var id: String { "\(rank)|\(url.absoluteString)" }
}

struct MusicPageInfo {
    var name: String
    var artist: String?
    var url: URL?
    var imageURL: URL?
    var listeners: Int?
    var scrobbles: Int?
    var userScrobbles: Int?
    var description = ""
    var tags: [MusicLink] = []
    var album: MusicLink?
    var tracks: [AlbumTrack] = []
}

enum LibraryChartCache {
    struct Pages {
        var entries: [ProfileChartEntry] = []
        var fetched = 0
        var total = 1
        var date = Date()
    }
    static var pages: [String: Pages] = [:]
    static let lifetime: TimeInterval = 15 * 60
    static let pageSize = 500
    static let maxPages = 6
}

// MARK: - Loading

extension LastFMClient {
    func musicPageInfo(_ item: MusicItem) async throws -> MusicPageInfo {
        var params = ["autocorrect": "1"]
        if let username { params["username"] = username }
        switch item {
        case .artist(let artist):
            params.merge(["method": "artist.getInfo", "artist": artist]) { $1 }
            let json = try await request(params)
            guard let row = json["artist"] as? [String: Any] else { throw pageFailure }
            let stats = row["stats"] as? [String: Any]
            return MusicPageInfo(
                name: row["name"] as? String ?? artist,
                url: MusicLink.parse(row).first?.url,
                listeners: Self.count(stats?["listeners"]),
                scrobbles: Self.count(stats?["playcount"]),
                userScrobbles: Self.count(stats?["userplaycount"]),
                description: Self.pageDescription(row["bio"]),
                tags: MusicLink.parse((row["tags"] as? [String: Any])?["tag"], limit: 8))
        case .album(let artist, let name):
            params.merge(["method": "album.getInfo", "artist": artist, "album": name]) { $1 }
            let json = try await request(params)
            guard let row = json["album"] as? [String: Any] else { throw pageFailure }
            let albumArtist = row["artist"] as? String ?? (row["artist"] as? [String: Any])?["name"] as? String ?? artist
            let tracksValue = (row["tracks"] as? [String: Any])?["track"]
            let trackRows = tracksValue as? [[String: Any]] ?? (tracksValue as? [String: Any]).map { [$0] } ?? []
            let tracks = trackRows.enumerated().compactMap { index, track -> AlbumTrack? in
                guard let title = track["name"] as? String, !title.isEmpty else { return nil }
                let trackArtist = (track["artist"] as? [String: Any])?["name"] as? String ?? albumArtist
                let rank = Self.count((track["@attr"] as? [String: Any])?["rank"]) ?? index + 1
                let url = MusicLink.parse(track).first?.url ?? MusicItem.track(artist: trackArtist, name: title).url
                let seconds = Self.count(track["duration"]).flatMap { $0 > 0 ? TimeInterval($0) : nil }
                return AlbumTrack(rank: rank, name: title, url: url, duration: seconds)
            }
            return MusicPageInfo(
                name: row["name"] as? String ?? name, artist: albumArtist,
                url: MusicLink.parse(row).first?.url,
                imageURL: ArtworkCandidates.urls(row["image"]).first,
                listeners: Self.count(row["listeners"]),
                scrobbles: Self.count(row["playcount"]),
                userScrobbles: Self.count(row["userplaycount"]),
                description: Self.pageDescription(row["wiki"]),
                tags: MusicLink.parse((row["tags"] as? [String: Any])?["tag"], limit: 8),
                tracks: tracks)
        case .track(let artist, let name):
            params.merge(["method": "track.getInfo", "artist": artist, "track": name]) { $1 }
            let json = try await request(params)
            guard let row = json["track"] as? [String: Any] else { throw pageFailure }
            let trackArtist = (row["artist"] as? [String: Any])?["name"] as? String ?? artist
            var album: MusicLink?
            if let albumRow = row["album"] as? [String: Any], let title = albumRow["title"] as? String, !title.isEmpty {
                let albumArtist = albumRow["artist"] as? String ?? trackArtist
                let images = ArtworkCandidates.urls(albumRow["image"])
                let url = MusicLink.parse(["name": title, "url": albumRow["url"] ?? ""]).first?.url
                    ?? MusicItem.album(artist: albumArtist, name: title).url
                album = MusicLink(name: title, url: url, imageURL: images.first, imageAlternatives: images)
            }
            return MusicPageInfo(
                name: row["name"] as? String ?? name, artist: trackArtist,
                url: MusicLink.parse(row).first?.url,
                imageURL: album?.imageURL,
                listeners: Self.count(row["listeners"]),
                scrobbles: Self.count(row["playcount"]),
                userScrobbles: Self.count(row["userplaycount"]),
                description: Self.pageDescription(row["wiki"]),
                tags: MusicLink.parse((row["toptags"] as? [String: Any])?["tag"], limit: 8),
                album: album)
        }
    }

    func artistTopTracks(_ artist: String, limit: Int) async -> [ProfileChartEntry] {
        guard let json = try? await request(["method": "artist.getTopTracks", "artist": artist, "autocorrect": "1",
                                             "limit": String(limit)]) else { return [] }
        return Self.chartEntries((json["toptracks"] as? [String: Any])?["track"], limit: limit)
    }

    func artistTopAlbums(_ artist: String, limit: Int) async -> [ProfileChartEntry] {
        guard let json = try? await request(["method": "artist.getTopAlbums", "artist": artist, "autocorrect": "1",
                                             "limit": String(limit)]) else { return [] }
        return Self.chartEntries((json["topalbums"] as? [String: Any])?["album"], limit: limit)
    }

    func similarArtists(_ artist: String, limit: Int = 20) async -> [ProfileChartEntry] {
        guard let json = try? await request(["method": "artist.getSimilar", "artist": artist, "autocorrect": "1",
                                             "limit": String(limit)]) else { return [] }
        return Self.chartEntries((json["similarartists"] as? [String: Any])?["artist"], limit: limit)
            .map { ProfileChartEntry(link: $0.link, artist: $0.link.name, count: 0) }
    }

    func similarTracks(artist: String, track: String, limit: Int = 20) async -> [ProfileChartEntry] {
        guard let json = try? await request(["method": "track.getSimilar", "artist": artist, "track": track,
                                             "autocorrect": "1", "limit": String(limit)]) else { return [] }
        return Self.chartEntries((json["similartracks"] as? [String: Any])?["track"], limit: limit)
    }

    /// The signed-in listener's most-played tracks or albums by one artist. last.fm has no direct
    /// endpoint for this, so it walks the listener's all-time chart (cached for a while) until it has enough.
    func libraryTop(_ kind: ChartKind, artist names: Set<String>, expectedPlays: Int, limit: Int) async -> [ProfileChartEntry] {
        guard let username, kind != .artists else { return [] }
        let names = Set(names.map { $0.lowercased() })
        let key = "\(username.lowercased())|\(kind.rawValue)"
        var cache = LibraryChartCache.pages[key] ?? .init()
        if Date().timeIntervalSince(cache.date) > LibraryChartCache.lifetime { cache = .init() }
        let singular = String(kind.rawValue.dropLast())
        while true {
            let found = cache.entries.filter { names.contains($0.artist.lowercased()) }
            let plays = found.reduce(0) { $0 + $1.count }
            if found.count >= limit || plays >= expectedPlays || cache.fetched >= cache.total
                || cache.fetched >= LibraryChartCache.maxPages || Task.isCancelled {
                return Array(found.prefix(limit))
            }
            let page = cache.fetched + 1
            guard let json = try? await request(["method": "user.getTop" + kind.rawValue.capitalized, "user": username,
                                                 "period": "overall", "limit": String(LibraryChartCache.pageSize),
                                                 "page": String(page)]),
                  let root = json["top" + kind.rawValue] as? [String: Any] else { return Array(found.prefix(limit)) }
            // Another page view may have filled the cache while this request was in flight.
            if let latest = LibraryChartCache.pages[key], latest.fetched >= page,
               Date().timeIntervalSince(latest.date) <= LibraryChartCache.lifetime {
                cache = latest
                continue
            }
            cache.entries += Self.chartEntries(root[singular], limit: LibraryChartCache.pageSize)
            cache.fetched = page
            cache.total = Int((root["@attr"] as? [String: Any])?["totalPages"] as? String ?? "") ?? page
            LibraryChartCache.pages[key] = cache
        }
    }

    private var pageFailure: NSError {
        NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: "last.fm doesn't have a page for this."])
    }

    private static func pageDescription(_ value: Any?) -> String {
        let wiki = value as? [String: Any]
        let html = (wiki?["content"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? wiki?["summary"] as? String ?? ""
        return ArtistDetails.plainBiography(html)
            .replacingOccurrences(of: "\\s*User-contributed text is available.*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Presentation

extension View {
    /// Opens last.fm artist, album and track links from anything inside this view as an in-app page.
    func musicPages() -> some View { modifier(MusicPageHost()) }
}

private struct MusicPageHost: ViewModifier {
    @State private var item: MusicItem?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let page = MusicItem(url: url) else { return .systemAction }
                item = page
                return .handled
            })
            .sheet(item: $item) { MusicPageSheet(root: $0) }
    }
}

private struct MusicPageSheet: View {
    let root: MusicItem
    @Environment(\.dismiss) private var dismiss
    @State private var path: [MusicItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            MusicPageView(item: root)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
                .navigationDestination(for: MusicItem.self) { MusicPageView(item: $0) }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let page = MusicItem(url: url) else { return .systemAction }
            if page != (path.last ?? root) { path.append(page) }
            return .handled
        })
    }
}

// MARK: - Page

struct MusicPageView: View {
    let item: MusicItem
    @EnvironmentObject private var lastFM: LastFMClient
    @State private var info: MusicPageInfo?
    @State private var error: String?
    @State private var showingDescription = false
    @State private var popularTracks: [ProfileChartEntry]?
    @State private var popularAlbums: [ProfileChartEntry]?
    @State private var yourTracks: [ProfileChartEntry]?
    @State private var yourAlbums: [ProfileChartEntry]?
    @State private var related: [ProfileChartEntry]?
    @State private var monthly: [MonthlyCount]?

    private var title: String { info?.name ?? item.name }
    private var artistName: String { info?.artist ?? (isArtist ? title : item.artist) }
    private var isArtist: Bool { if case .artist = item { true } else { false } }

    var body: some View {
        List {
            if let error, info == nil {
                ContentUnavailableView {
                    Label("Couldn't load \(item.name)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await loadInfo() } }
                }
                .listRowBackground(Color.clear)
            } else {
                hero
                if let info {
                    statsSection(info)
                    if !info.tags.isEmpty {
                        Section("Tags") { TagChips(tags: info.tags) }
                    }
                    aboutSection(info)
                    if lastFM.username != nil { monthlySection }
                    switch item {
                    case .artist: artistSections
                    case .album: albumSections(info)
                    case .track: trackSections(info)
                    }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
        }
        .tint(.primary)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } // the header draws the name
            ToolbarItem(placement: .topBarTrailing) {
                Button { ShareSheet.present(url: info?.url ?? item.url) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
            }
        }
        .sheet(isPresented: $showingDescription) {
            DescriptionSheet(title: title, text: info?.description ?? "")
        }
        .task { await loadInfo() }
        .task { await loadRelated() }
        .task(id: info?.userScrobbles) { await loadYours() }
        .task(id: info?.name) {
            guard let info else { return }
            monthly = await lastFM.monthlyScrobbles(for: item, canonicalName: info.name, canonicalArtist: info.artist)
        }
    }

    // MARK: Sections

    private var hero: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.largeTitle.bold()).foregroundStyle(.primary)
                    if !isArtist {
                        Text(creditLine).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 300)
                    .overlay {
                        if isArtist {
                            ArtistPortrait(name: title, size: nil)
                        } else {
                            RemoteArtwork(url: info?.imageURL, symbol: albumOrTrackSymbol, size: nil)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        }
    }

    /// "Artist" for albums, "Artist - Album" for tracks; each part opens its own page.
    private var creditLine: AttributedString {
        var line = AttributedString(artistName)
        line.link = MusicItem.artist(artistName).url
        if let album = info?.album {
            var albumPart = AttributedString(album.name)
            albumPart.link = album.url
            line += AttributedString(" - ") + albumPart
        }
        return line
    }

    private var albumOrTrackSymbol: String {
        if case .album = item { "opticaldisc" } else { "music.note" }
    }

    private func statsSection(_ info: MusicPageInfo) -> some View {
        Section {
            HStack(alignment: .top) {
                stat("Listeners", value: info.listeners)
                Divider()
                stat("Scrobbles", value: info.scrobbles)
                Divider()
                stat("Your scrobbles", value: info.userScrobbles ?? (lastFM.username == nil ? nil : 0))
            }
        }
    }

    private func stat(_ label: String, value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(value?.formatted() ?? "—").font(.title3.bold()).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func aboutSection(_ info: MusicPageInfo) -> some View {
        Section("About") {
            if info.description.isEmpty {
                Text("No description available.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.description).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(5)
                    if info.description.count > 280 {
                        Button("View more") { showingDescription = true }
                            .font(.callout.bold())
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var monthlySection: some View {
        Section("Your scrobbles") {
            if let monthly {
                MonthlyItemChart(months: monthly).padding(.vertical, 6)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 130)
            }
        }
    }

    @ViewBuilder private var artistSections: some View {
        rows("Popular tracks", popularTracks, kind: .tracks, countLabel: "scrobbles")
        rows("Popular albums", popularAlbums, kind: .albums, countLabel: "scrobbles")
        if (info?.userScrobbles ?? 0) > 0 {
            rows("Your top tracks", yourTracks, kind: .tracks, countLabel: "plays", empty: "None of your top tracks are by \(title).")
            rows("Your top albums", yourAlbums, kind: .albums, countLabel: "plays", empty: "None of your top albums are by \(title).")
        }
        carousel("Similar artists", related, kind: .artists)
    }

    @ViewBuilder private func albumSections(_ info: MusicPageInfo) -> some View {
        Section("Tracks") {
            if info.tracks.isEmpty {
                Text("last.fm doesn't have a tracklist for this album.").foregroundStyle(.secondary)
            }
            ForEach(info.tracks) { track in
                Link(destination: track.url) {
                    HStack(spacing: 12) {
                        Text("\(track.rank)").font(.footnote.bold()).foregroundStyle(.secondary)
                            .monospacedDigit().frame(minWidth: 20)
                        Text(track.name).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        if let duration = track.duration {
                            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        carousel("More by \(artistName)", related, kind: .albums)
    }

    @ViewBuilder private func trackSections(_ info: MusicPageInfo) -> some View {
        carousel("Similar tracks", related, kind: .tracks)
    }

    @ViewBuilder private func rows(_ title: String, _ entries: [ProfileChartEntry]?, kind: ChartKind,
                                   countLabel: String, empty: String? = nil) -> some View {
        if entries == nil || entries?.isEmpty == false || empty != nil {
            Section(title) {
                if let entries {
                    if entries.isEmpty, let empty { Text(empty).foregroundStyle(.secondary) }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        LinkRow(url: entry.link.url, title: entry.link.name,
                                trailing: entry.count > 0 ? "\(entry.count.formatted(.number.notation(.compactName))) \(countLabel)" : nil) {
                            HStack(spacing: 10) {
                                Text("\(index + 1)").font(.footnote.bold()).foregroundStyle(.secondary)
                                    .monospacedDigit().frame(width: 20)
                                ChartArtwork(kind: kind, entry: entry, size: 44)
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func carousel(_ title: String, _ entries: [ProfileChartEntry]?, kind: ChartKind) -> some View {
        if entries?.isEmpty != true {
            Section(title) {
                if let entries {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(entries) { entry in
                                Link(destination: entry.link.url) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ChartArtwork(kind: kind, entry: entry, size: 110)
                                        Text(entry.link.name).font(.caption.bold()).foregroundStyle(.primary).lineLimit(2)
                                        if kind != .artists {
                                            Text(entry.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .frame(width: 110, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Loading

    private func loadInfo() async {
        error = nil
        do {
            let result = try await lastFM.musicPageInfo(item)
            guard !Task.isCancelled else { return }
            info = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadRelated() async {
        switch item {
        case .artist(let artist):
            async let tracks = lastFM.artistTopTracks(artist, limit: 10)
            async let albums = lastFM.artistTopAlbums(artist, limit: 5)
            async let similar = lastFM.similarArtists(artist)
            popularTracks = await tracks
            popularAlbums = await albums
            related = await similar
        case .album(let artist, let name):
            let albums = await lastFM.artistTopAlbums(artist, limit: 16)
            related = albums.filter { $0.link.name.caseInsensitiveCompare(name) != .orderedSame && $0.link.url != item.url }
        case .track(let artist, let name):
            related = await lastFM.similarTracks(artist: artist, track: name)
        }
    }

    private func loadYours() async {
        guard isArtist, let info, let plays = info.userScrobbles, plays > 0 else { return }
        let names: Set<String> = [info.name, item.name]
        async let tracks = lastFM.libraryTop(.tracks, artist: names, expectedPlays: plays, limit: 10)
        async let albums = lastFM.libraryTop(.albums, artist: names, expectedPlays: plays, limit: 5)
        yourTracks = await tracks
        yourAlbums = await albums
    }
}

private struct DescriptionSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Monthly scrobbles

struct MonthlyCount: Identifiable {
    let start: Date
    let count: Int
    var id: Date { start }
}

enum MonthlyChartCache {
    struct Entry { let counts: [String: Int]; let fetched: Date }
    static var entries: [String: Entry] = [:]
    static let currentMonthLifetime: TimeInterval = 10 * 60
}

extension LastFMClient {
    /// The listener's scrobbles of one artist, album or track in each of the last 12 months (current month last).
    /// Uses the user.getWeekly*Chart endpoints with month ranges; finished months are cached for the session.
    func monthlyScrobbles(for item: MusicItem, canonicalName: String, canonicalArtist: String?) async -> [MonthlyCount] {
        guard let username else { return [] }
        let calendar = Calendar.current
        let now = Date()
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let starts = (0..<12).compactMap { calendar.date(byAdding: .month, value: $0 - 11, to: thisMonth) }

        let method: String, root: String, row: String
        let keys: Set<String>
        switch item {
        case .artist(let name):
            (method, root, row) = ("user.getWeeklyArtistChart", "weeklyartistchart", "artist")
            keys = [ListeningReport.artistKey(name), ListeningReport.artistKey(canonicalName)]
        case .album(let artist, let name):
            (method, root, row) = ("user.getWeeklyAlbumChart", "weeklyalbumchart", "album")
            keys = [ListeningReport.albumKey(artist: artist, album: name),
                    ListeningReport.albumKey(artist: canonicalArtist ?? artist, album: canonicalName)]
        case .track(let artist, let name):
            (method, root, row) = ("user.getWeeklyTrackChart", "weeklytrackchart", "track")
            keys = [ListeningReport.trackKey(artist: artist, title: name),
                    ListeningReport.trackKey(artist: canonicalArtist ?? artist, title: canonicalName)]
        }

        var counts: [Date: Int] = [:]
        await withTaskGroup(of: (Date, [String: Int]?).self) { group in
            var pending = starts.makeIterator()
            func addNext() {
                guard let start = pending.next() else { return }
                group.addTask {
                    let end = min(calendar.date(byAdding: .month, value: 1, to: start) ?? now, now)
                    return (start, await self.monthChart(method: method, root: root, row: row, user: username,
                                                         from: start, to: end, isCurrent: start == thisMonth))
                }
            }
            for _ in 0..<4 { addNext() }
            for await (start, chart) in group {
                counts[start] = chart.map { chart in keys.reduce(0) { $0 + (chart[$1] ?? 0) } } ?? 0
                addNext()
            }
        }
        return starts.map { MonthlyCount(start: $0, count: counts[$0] ?? 0) }
    }

    private func monthChart(method: String, root: String, row: String, user: String,
                            from start: Date, to end: Date, isCurrent: Bool) async -> [String: Int]? {
        let cacheKey = "\(user.lowercased())|\(method)|\(Int(start.timeIntervalSince1970))"
        if let cached = MonthlyChartCache.entries[cacheKey],
           !isCurrent || Date().timeIntervalSince(cached.fetched) < MonthlyChartCache.currentMonthLifetime {
            return cached.counts
        }
        guard let json = try? await request(["method": method, "user": user,
                                             "from": String(Int(start.timeIntervalSince1970)),
                                             "to": String(Int(end.timeIntervalSince1970))]),
              let container = json[root] as? [String: Any] else { return nil }
        let rows = container[row] as? [[String: Any]] ?? (container[row] as? [String: Any]).map { [$0] } ?? []
        var counts: [String: Int] = [:]
        for entry in rows {
            guard let name = entry["name"] as? String, let plays = Self.count(entry["playcount"]) else { continue }
            let artist = (entry["artist"] as? [String: Any])?["#text"] as? String ?? ""
            let key = switch row {
            case "artist": ListeningReport.artistKey(name)
            case "album": ListeningReport.albumKey(artist: artist, album: name)
            default: ListeningReport.trackKey(artist: artist, title: name)
            }
            counts[key, default: 0] += plays
        }
        MonthlyChartCache.entries[cacheKey] = .init(counts: counts, fetched: Date())
        return counts
    }
}

struct MonthlyItemChart: View {
    let months: [MonthlyCount]

    private var peak: Int? {
        guard let max = months.map(\.count).max(), max > 0 else { return nil }
        return months.firstIndex { $0.count == max }
    }

    /// 0 plus at most two evenly spaced, round ticks (e.g. 0/250/500 or 0/1000/2000).
    static func axisTicks(for maximum: Int) -> [Int] {
        guard maximum > 0 else { return [0, 1] }
        let half = Double(maximum) / 2
        let magnitude = pow(10, floor(log10(half)))
        let fraction = half / magnitude
        let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10
        let step = max(1, Int((nice * magnitude).rounded(.up)))
        return [0, step, step * 2]
    }

    private func letter(_ date: Date) -> String {
        Calendar.current.veryShortMonthSymbols[Calendar.current.component(.month, from: date) - 1]
    }

    var body: some View {
        let ticks = Self.axisTicks(for: months.map(\.count).max() ?? 0)
        Chart(Array(months.enumerated()), id: \.offset) { index, month in
            BarMark(x: .value("Month", String(index)), y: .value("Scrobbles", month.count), width: .ratio(0.7))
                .foregroundStyle(index == peak ? Color.accentColor : Color.accentColor.opacity(0.35))
                .accessibilityLabel(month.start.formatted(.dateTime.month(.wide).year()))
                .accessibilityValue("\(month.count) scrobbles")
        }
        .chartXScale(domain: months.indices.map(String.init))
        .chartXAxis {
            AxisMarks { value in
                if let index = value.as(String.self).flatMap(Int.init), months.indices.contains(index) {
                    AxisValueLabel(letter(months[index].start))
                }
            }
        }
        .chartYScale(domain: 0...(ticks.last ?? 1))
        .chartYAxis {
            AxisMarks(position: .trailing, values: ticks) { value in
                AxisGridLine()
                AxisValueLabel { if let count = value.as(Int.self) { Text(count.formatted()) } }
            }
        }
        .frame(height: 130)
    }
}

// MARK: - Share sheet

enum ShareSheet {
    /// The system share sheet for a last.fm link, with "Open in last.fm" as the first action.
    static func present(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: [OpenInLastFMActivity(url: url)])
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.maxX - 40, y: 40, width: 1, height: 1)
        top.present(controller, animated: true)
    }
}

private final class OpenInLastFMActivity: UIActivity {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { UIActivity.ActivityType("com.swagrelated.scrap.openInLastFM") }
    override var activityTitle: String? { "Open in last.fm" }
    override var activityImage: UIImage? { UIImage(systemName: "safari") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        UIApplication.shared.open(url)
        activityDidFinish(true)
    }
}
