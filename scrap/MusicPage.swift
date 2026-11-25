import AppKit
import Charts
import Combine
import SwiftUI

// MARK: - Items

enum MusicItem: Hashable, Identifiable {
    case artist(String)
    case album(artist: String, name: String)
    case track(artist: String, name: String)
    case tag(String)

    var id: String { url.absoluteString }

    var name: String {
        switch self {
        case .artist(let name), .album(_, let name), .track(_, let name), .tag(let name): name
        }
    }

    var artist: String {
        switch self {
        case .artist(let name), .album(let name, _), .track(let name, _): name
        case .tag: ""
        }
    }

    var url: URL {
        switch self {
        case .artist(let artist): Self.lastFMURL([artist])
        case .album(let artist, let name): Self.lastFMURL([artist, name])
        case .track(let artist, let name): Self.lastFMURL([artist, "_", name])
        case .tag(let name): Self.lastFMURL([name], section: "tag")
        }
    }

    init?(url: URL) {
        guard let host = url.host?.lowercased(), host == "last.fm" || host.hasSuffix(".last.fm"),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
        var parts = path.split(separator: "/").map(String.init)
        if parts.count > 1, parts[0].count == 2, ["music", "tag"].contains(parts[1]) { parts.removeFirst() }
        guard parts.first == "music" || parts.first == "tag" else { return nil }
        let names = parts.dropFirst()
            .filter { !$0.hasPrefix("+") }
            .map { ($0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? $0) }
        guard let artist = names.first, !artist.isEmpty else { return nil }
        if parts.first == "tag" {
            guard names.count == 1 else { return nil }
            self = .tag(artist)
            return
        }
        switch names.count {
        case 1: self = .artist(artist)
        case 2: self = names[1] == "_" ? .artist(artist) : .album(artist: artist, name: names[1])
        default: self = .track(artist: artist, name: names[2])
        }
    }

    private static func lastFMURL(_ components: [String], section: String = "music") -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~ ")
        let path = components.map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: " ", with: "+")
        }.joined(separator: "/")
        return URL(string: "https://www.last.fm/\(section)/" + path)!
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
    var imageAlternatives: [URL] = []
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
            let images = ArtworkCandidates.urls(row["image"])
            return MusicPageInfo(
                name: row["name"] as? String ?? name, artist: albumArtist,
                url: MusicLink.parse(row).first?.url,
                imageURL: images.first, imageAlternatives: images,
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
                imageURL: album?.imageURL, imageAlternatives: album?.imageAlternatives ?? [],
                listeners: Self.count(row["listeners"]),
                scrobbles: Self.count(row["playcount"]),
                userScrobbles: Self.count(row["userplaycount"]),
                description: Self.pageDescription(row["wiki"]),
                tags: MusicLink.parse((row["toptags"] as? [String: Any])?["tag"], limit: 8),
                album: album)
        case .tag(let tag):
            let json = try await request(["method": "tag.getInfo", "tag": tag])
            guard let row = json["tag"] as? [String: Any] else { throw pageFailure }
            let similar = try? await request(["method": "tag.getSimilar", "tag": tag])
            let name = row["name"] as? String ?? tag
            return MusicPageInfo(
                name: name,
                url: MusicItem.tag(name).url,
                listeners: Self.count(row["reach"]),
                scrobbles: Self.count(row["total"]),
                description: Self.pageDescription(row["wiki"]),
                tags: MusicLink.parse((similar?["similartags"] as? [String: Any])?["tag"], limit: 12))
        }
    }

    func tagTop(_ kind: ChartKind, tag: String, limit: Int) async -> [ProfileChartEntry] {
        let singular = String(kind.rawValue.dropLast())
        guard let json = try? await request(["method": "tag.getTop" + kind.rawValue.capitalized, "tag": tag,
                                             "limit": String(limit)]) else { return [] }
        let root = (json["top" + kind.rawValue] ?? json[kind.rawValue]) as? [String: Any]
        return Self.chartEntries(root?[singular], limit: limit)
    }

    func libraryChart(_ kind: ChartKind, pages: Int) async -> [ProfileChartEntry] {
        guard let username else { return [] }
        let key = "\(username.lowercased())|\(kind.rawValue)"
        var cache = LibraryChartCache.pages[key] ?? .init()
        if Date().timeIntervalSince(cache.date) > LibraryChartCache.lifetime { cache = .init() }
        let singular = String(kind.rawValue.dropLast())
        while cache.fetched < min(pages, cache.total), !Task.isCancelled {
            let page = cache.fetched + 1
            guard let json = try? await request(["method": "user.getTop" + kind.rawValue.capitalized, "user": username,
                                                 "period": "overall", "limit": String(LibraryChartCache.pageSize),
                                                 "page": String(page)]),
                  let root = json["top" + kind.rawValue] as? [String: Any] else { break }
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
        return cache.entries
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

// MARK: - Window

extension View {
    func musicPages(client: LastFMClient) -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard let item = MusicItem(url: url) else { return .systemAction }
            MusicPageController.shared.show(item, client: client)
            return .handled
        })
    }
}

@MainActor
final class MusicPageController: ObservableObject {
    static let shared = MusicPageController()
    @Published private(set) var stack: [MusicItem] = []
    private var window: NSWindow?

    func show(_ item: MusicItem, client: LastFMClient) {
        stack = [item]
        let window = window ?? makeWindow(client: client)
        updateTitle()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func push(_ item: MusicItem) {
        guard item != stack.last else { return }
        stack.append(item)
        updateTitle()
    }

    func back() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        updateTitle()
    }

    private func updateTitle() {
        window?.title = stack.last?.name ?? "scrap"
    }

    private func makeWindow(client: LastFMClient) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 420)
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: MusicPageWindow(controller: self, client: client))
        window.setContentSize(NSSize(width: 560, height: 720))
        window.center()
        self.window = window
        return window
    }
}

private struct MusicPageWindow: View {
    @ObservedObject var controller: MusicPageController
    @ObservedObject var client: LastFMClient

    var body: some View {
        VStack(spacing: 0) {
            if let item = controller.stack.last {
                HStack {
                    if controller.stack.count > 1 {
                        Button { controller.back() } label: { Label("Back", systemImage: "chevron.left") }
                            .keyboardShortcut("[", modifiers: .command)
                            .help("Back")
                    }
                    Spacer()
                    ShareButton(url: item.url)
                        .fixedSize()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                MusicPageView(item: item, client: client)
                    .id(item)
            }
        }
        .frame(minWidth: 440, minHeight: 420)
        .environment(\.openURL, OpenURLAction { url in
            guard let page = MusicItem(url: url) else { return .systemAction }
            controller.push(page)
            return .handled
        })
    }
}

private struct ShareButton: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share") ?? NSImage()
        let button = NSButton(title: "Share", image: image, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.toolTip = "Share"
        context.coordinator.url = url
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.url = url
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var url: URL?
        private var picker: NSSharingServicePicker?

        @objc func share(_ sender: NSButton) {
            guard let url else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = self
            self.picker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                                  proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
            guard let url else { return proposedServices }
            let image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil) ?? NSImage()
            let open = NSSharingService(title: "Open in last.fm", image: image, alternateImage: nil) {
                NSWorkspace.shared.open(url)
            }
            return [open] + proposedServices
        }
    }
}

// MARK: - Page

struct MusicPageView: View {
    let item: MusicItem
    @ObservedObject var client: LastFMClient
    @State private var info: MusicPageInfo?
    @State private var error: String?
    @State private var showingDescription = false
    @State private var expanded: Set<String> = []
    @State private var tagArtists: [ProfileChartEntry]?
    @State private var yourArtists: [ProfileChartEntry]?
    @State private var popularTracks: [ProfileChartEntry]?
    @State private var popularAlbums: [ProfileChartEntry]?
    @State private var yourTracks: [ProfileChartEntry]?
    @State private var yourAlbums: [ProfileChartEntry]?
    @State private var related: [ProfileChartEntry]?
    @State private var monthly: [MonthlyCount]?

    private var title: String { info?.name ?? item.name }
    private var artistName: String { info?.artist ?? (isArtist ? title : item.artist) }
    private var isArtist: Bool { if case .artist = item { true } else { false } }
    private var isTag: Bool { if case .tag = item { true } else { false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let error, info == nil {
                    ContentUnavailableView {
                        Label("Couldn't load \(item.name)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await loadInfo() } }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    hero
                    if let info {
                        statsSection(info)
                        if !info.tags.isEmpty {
                            section(isTag ? "Similar tags" : "Tags") { TagChips(tags: info.tags) }
                        }
                        aboutSection(info)
                        if client.username != nil { monthlySection }
                        switch item {
                        case .artist: artistSections
                        case .album: albumSections(info)
                        case .track: trackSections
                        case .tag: tagSections
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .sheet(isPresented: $showingDescription) {
            DescriptionSheet(title: title, text: info?.description ?? "")
        }
        .task { await loadInfo() }
        .task { await loadRelated() }
        .task(id: info?.userScrobbles) { await loadYours() }
        .task(id: "\(info?.name ?? "")|\(tagArtists?.count ?? -1)") {
            guard let info else { return }
            if isTag {
                guard let tagArtists else { return }
                let keys = Set(tagArtists.map { ListeningReport.artistKey($0.link.name) })
                async let months = client.monthlyScrobbles(for: item, canonicalName: info.name, canonicalArtist: nil, artistKeys: keys)
                await loadTagYours(tagArtists)
                monthly = await months
            } else {
                monthly = await client.monthlyScrobbles(for: item, canonicalName: info.name, canonicalArtist: info.artist)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !isArtist && !isTag {
                    Text(creditLine).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Group {
                if isArtist {
                    ArtistPortrait(name: title, size: 260)
                } else if isTag {
                    if let top = tagArtists?.first {
                        ArtistPortrait(name: top.link.name, size: 260)
                            .help("\(top.link.name), the most popular artist tagged \(title)")
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: 260, height: 260)
                            .overlay(Image(systemName: "tag").font(.system(size: 60)).foregroundStyle(.secondary))
                    }
                } else {
                    RemoteAlbumArtwork(url: info?.imageURL, alternatives: info?.imageAlternatives ?? []) {
                        RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                            .overlay(Image(systemName: albumOrTrackSymbol).font(.system(size: 60)).foregroundStyle(.secondary))
                    }
                    .frame(width: 260, height: 260)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            .frame(maxWidth: .infinity)
        }
    }

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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statsSection(_ info: MusicPageInfo) -> some View {
        HStack(alignment: .top) {
            stat("Listeners", value: info.listeners)
            Divider()
            stat(isTag ? "Taggings" : "Scrobbles", value: info.scrobbles)
            Divider()
            stat("Your scrobbles", value: info.userScrobbles ?? (client.username == nil || isTag ? nil : 0))
                .help(isTag ? "All-time plays of popular \(info.name) artists you listen to" : "")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(value?.formatted() ?? "—").font(.title3.bold()).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func aboutSection(_ info: MusicPageInfo) -> some View {
        section("About") {
            if info.description.isEmpty {
                Text("No description available.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.description).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(5)
                    if info.description.count > 280 {
                        Button("View more") { showingDescription = true }
                            .font(.callout.bold())
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var monthlySection: some View {
        section("Your scrobbles") {
            if let monthly {
                MonthlyItemChart(months: monthly).padding(.vertical, 6)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 130)
            }
        }
    }

    @ViewBuilder private var artistSections: some View {
        rows("Popular tracks", popularTracks, kind: .tracks, countLabel: "scrobbles", collapsible: true)
        rows("Popular albums", popularAlbums, kind: .albums, countLabel: "scrobbles", collapsible: true)
        if (info?.userScrobbles ?? 0) > 0 {
            rows("Your top tracks", yourTracks, kind: .tracks, countLabel: "plays", empty: "None of your top tracks are by \(title).",
                 collapsible: true)
            rows("Your top albums", yourAlbums, kind: .albums, countLabel: "plays", empty: "None of your top albums are by \(title).",
                 collapsible: true)
        }
        carousel("Similar artists", related, kind: .artists)
    }

    @ViewBuilder private var tagSections: some View {
        rows("Popular artists", tagArtists.map { Array($0.prefix(10)) }, kind: .artists, countLabel: "", collapsible: true)
        rows("Popular albums", popularAlbums, kind: .albums, countLabel: "", collapsible: true)
        rows("Popular tracks", popularTracks, kind: .tracks, countLabel: "", collapsible: true)
        if client.username != nil {
            rows("Your top artists", yourArtists, kind: .artists, countLabel: "plays",
                 empty: "None of your top artists are among the most popular \(title) artists.", collapsible: true)
            rows("Your top albums", yourAlbums, kind: .albums, countLabel: "plays",
                 empty: "None of your top albums are by popular \(title) artists.", collapsible: true)
            rows("Your top tracks", yourTracks, kind: .tracks, countLabel: "plays",
                 empty: "None of your top tracks are by popular \(title) artists.", collapsible: true)
        }
    }

    @ViewBuilder private func albumSections(_ info: MusicPageInfo) -> some View {
        section("Tracks") {
            if info.tracks.isEmpty {
                Text("last.fm doesn't have a tracklist for this album.").foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(info.tracks) { track in
                    Link(destination: track.url) {
                        HStack(spacing: 12) {
                            Text("\(track.rank)").font(.callout.bold()).foregroundStyle(.secondary)
                                .monospacedDigit().frame(minWidth: 20)
                            Text(track.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            if let duration = track.duration {
                                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if track.id != info.tracks.last?.id { Divider() }
                }
            }
        }
        carousel("More by \(artistName)", related, kind: .albums)
    }

    @ViewBuilder private var trackSections: some View {
        carousel("Similar tracks", related, kind: .tracks)
    }

    @ViewBuilder private func rows(_ title: String, _ entries: [ProfileChartEntry]?, kind: ChartKind,
                                   countLabel: String, empty: String? = nil, collapsible: Bool = false) -> some View {
        let limit = collapsible && !expanded.contains(title) ? 5 : nil
        if entries == nil || entries?.isEmpty == false || empty != nil {
            section(title) {
                if let entries {
                    if entries.isEmpty, let empty { Text(empty).foregroundStyle(.secondary) }
                    ForEach(Array(entries.prefix(limit ?? entries.count).enumerated()), id: \.element.id) { index, entry in
                        Link(destination: entry.link.url) {
                            HStack(spacing: 10) {
                                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                                    .monospacedDigit().frame(width: 20)
                                ChartArtwork(kind: kind, entry: entry, size: 40, client: client)
                                Text(entry.link.name).font(.callout).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 0)
                                if entry.count > 0, !countLabel.isEmpty {
                                    Text("\(entry.count.formatted(.number.notation(.compactName))) \(countLabel)")
                                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let limit, entries.count > limit {
                        Button("View more") { expanded.insert(title) }
                            .font(.callout.bold())
                            .buttonStyle(.link)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func carousel(_ title: String, _ entries: [ProfileChartEntry]?, kind: ChartKind) -> some View {
        if entries?.isEmpty != true {
            section(title) {
                if let entries {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(entries) { entry in
                                Link(destination: entry.link.url) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ChartArtwork(kind: kind, entry: entry, size: 110, client: client)
                                        Text(entry.link.name).font(.caption.bold()).foregroundStyle(.primary).lineLimit(2)
                                        if kind != .artists {
                                            Text(entry.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .frame(width: 110, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(entry.link.name)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.automatic)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func loadInfo() async {
        error = nil
        do {
            let result = try await client.musicPageInfo(item)
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
            async let tracks = client.artistTopTracks(artist, limit: 10)
            async let albums = client.artistTopAlbums(artist, limit: 10)
            async let similar = client.similarArtists(artist)
            popularTracks = await tracks
            popularAlbums = await albums
            related = await similar
        case .album(let artist, let name):
            let albums = await client.artistTopAlbums(artist, limit: 16)
            related = albums.filter { $0.link.name.caseInsensitiveCompare(name) != .orderedSame && $0.link.url != item.url }
        case .track(let artist, let name):
            related = await client.similarTracks(artist: artist, track: name)
        case .tag(let tag):
            async let artists = client.tagTop(.artists, tag: tag, limit: LibraryChartCache.pageSize)
            async let albums = client.tagTop(.albums, tag: tag, limit: 10)
            async let tracks = client.tagTop(.tracks, tag: tag, limit: 10)
            tagArtists = await artists
            popularAlbums = await albums
            popularTracks = await tracks
        }
    }

    private func loadTagYours(_ artists: [ProfileChartEntry]) async {
        guard client.username != nil else { return }
        let names = Set(artists.map { $0.link.name.lowercased() })
        async let libraryArtists = client.libraryChart(.artists, pages: 2)
        async let libraryAlbums = client.libraryChart(.albums, pages: 2)
        async let libraryTracks = client.libraryChart(.tracks, pages: 2)
        let mine = await libraryArtists.filter { names.contains($0.link.name.lowercased()) }
        yourArtists = Array(mine.prefix(10))
        info?.userScrobbles = mine.reduce(0) { $0 + $1.count }
        yourAlbums = Array(await libraryAlbums.filter { names.contains($0.artist.lowercased()) }.prefix(10))
        yourTracks = Array(await libraryTracks.filter { names.contains($0.artist.lowercased()) }.prefix(10))
    }

    private func loadYours() async {
        guard isArtist, let info, let plays = info.userScrobbles, plays > 0 else { return }
        let names: Set<String> = [info.name, item.name]
        async let tracks = client.libraryTop(.tracks, artist: names, expectedPlays: plays, limit: 10)
        async let albums = client.libraryTop(.albums, artist: names, expectedPlays: plays, limit: 10)
        yourTracks = await tracks
        yourAlbums = await albums
    }
}

struct TagChips: View {
    let tags: [MusicLink]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    Link(tag.name, destination: tag.url)
                        .font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
    }
}

struct ChartArtwork: View {
    let kind: ChartKind
    let entry: ProfileChartEntry
    let size: CGFloat
    @ObservedObject var client: LastFMClient
    @State private var covers: [URL] = []

    var body: some View {
        if kind == .artists {
            ArtistPortrait(name: entry.link.name, size: size)
        } else {
            RemoteAlbumArtwork(url: entry.link.imageURL ?? covers.first,
                               alternatives: entry.link.imageAlternatives + covers.dropFirst()) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay(Image(systemName: kind == .albums ? "opticaldisc" : "music.note").foregroundStyle(.secondary))
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 10 : 6))
            .task(id: entry.id) {
                guard entry.link.imageURL == nil else { return }
                covers = kind == .tracks
                    ? await client.trackArtwork(artist: entry.artist, track: entry.link.name)
                    : await client.albumArtwork(artist: entry.artist, album: entry.link.name)
            }
        }
    }
}

private struct DescriptionSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .frame(minWidth: 420, idealWidth: 500, maxWidth: 900, minHeight: 300, idealHeight: 380, maxHeight: 1200)
    }
}

// MARK: - Monthly chart

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
    func monthlyScrobbles(for item: MusicItem, canonicalName: String, canonicalArtist: String?,
                          artistKeys: Set<String> = []) async -> [MonthlyCount] {
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
        case .tag:
            (method, root, row) = ("user.getWeeklyArtistChart", "weeklyartistchart", "artist")
            keys = artistKeys
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
