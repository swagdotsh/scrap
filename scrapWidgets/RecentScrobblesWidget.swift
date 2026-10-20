import WidgetKit
import SwiftUI

struct RecentScrobblesEntry: TimelineEntry {
    struct Scrobble {
        let title: String
        let artist: String
        let date: Date?
        var image: UIImage?
        var isNowPlaying: Bool { date == nil }
    }

    let date: Date
    var scrobbles: [Scrobble] = []
    var signedIn = true

    static let sample = RecentScrobblesEntry(date: .now, scrobbles: [
        Scrobble(title: "Sum 2 do", artist: "Yeat", date: nil),
        Scrobble(title: "Swing Ya Pole", artist: "Summrs", date: .now.addingTimeInterval(-240)),
        Scrobble(title: "Gen 5", artist: "Drake", date: .now.addingTimeInterval(-480)),
        Scrobble(title: "Knocked Off", artist: "YoungBoy Never Broke Again", date: .now.addingTimeInterval(-720)),
        Scrobble(title: "Do It", artist: "underscores", date: .now.addingTimeInterval(-960)),
        Scrobble(title: "IN2THAT", artist: "Yeat", date: .now.addingTimeInterval(-1200))
    ])
}

struct RecentScrobblesProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentScrobblesEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (RecentScrobblesEntry) -> Void) {
        if context.isPreview {
            Task { completion(await Self.sampleWithArtwork()) }
            return
        }
        let family = context.family
        Task { completion(await Self.load(family: family)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentScrobblesEntry>) -> Void) {
        let family = context.family
        Task {
            let entry = await Self.load(family: family)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    static func rowCount(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: 1
        case .systemLarge: 6
        default: 3
        }
    }

    private static func sampleWithArtwork() async -> RecentScrobblesEntry {
        var entry = RecentScrobblesEntry.sample
        guard let credentials = WidgetLastFM.credentials else { return entry }
        var images = [UIImage?](repeating: nil, count: entry.scrobbles.count)
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, scrobble) in entry.scrobbles.enumerated() {
                group.addTask {
                    let json = try? await WidgetLastFM.request(["method": "track.getInfo", "artist": scrobble.artist, "track": scrobble.title],
                                                               credentials: credentials)
                    let album = (json?["track"] as? [String: Any])?["album"] as? [String: Any]
                    return (index, await WidgetLastFM.image(WidgetLastFM.imageURL(album?["image"]), width: 120))
                }
            }
            for await (index, image) in group { images[index] = image }
        }
        for index in entry.scrobbles.indices { entry.scrobbles[index].image = images[index] }
        return entry
    }

    private static func load(family: WidgetFamily) async -> RecentScrobblesEntry {
        var entry = RecentScrobblesEntry(date: .now)
        guard let credentials = WidgetLastFM.credentials else {
            entry.signedIn = false
            return entry
        }
        let limit = rowCount(for: family)
        guard let json = try? await WidgetLastFM.request(["method": "user.getRecentTracks", "user": credentials.username,
                                                          "limit": String(limit)], credentials: credentials) else { return entry }
        let root = json["recenttracks"] as? [String: Any]
        let rows = root?["track"] as? [[String: Any]] ?? (root?["track"] as? [String: Any]).map { [$0] } ?? []
        let parsed: [(scrobble: RecentScrobblesEntry.Scrobble, imageURL: URL?)] = rows.prefix(limit).compactMap { row in
            guard let title = row["name"] as? String else { return nil }
            let uts = WidgetLastFM.count((row["date"] as? [String: Any])?["uts"])
            let scrobble = RecentScrobblesEntry.Scrobble(title: title, artist: (row["artist"] as? [String: Any])?["#text"] as? String ?? "",
                                                         date: uts > 0 ? Date(timeIntervalSince1970: TimeInterval(uts)) : nil)
            return (scrobble, WidgetLastFM.imageURL(row["image"]))
        }
        let width: CGFloat = family == .systemSmall ? 300 : 120
        var images = [UIImage?](repeating: nil, count: parsed.count)
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, item) in parsed.enumerated() {
                group.addTask { (index, await WidgetLastFM.image(item.imageURL, width: width)) }
            }
            for await (index, image) in group { images[index] = image }
        }
        entry.scrobbles = zip(parsed, images).map { item, image in
            var scrobble = item.scrobble
            scrobble.image = image
            return scrobble
        }
        return entry
    }
}

struct RecentScrobblesWidgetView: View {
    let entry: RecentScrobblesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if !entry.signedIn {
                message("Open scrap to sign in to last.fm.")
            } else if entry.scrobbles.isEmpty {
                message("No scrobbles yet.")
            } else if family == .systemSmall, let latest = entry.scrobbles.first {
                small(latest)
            } else {
                list
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private func small(_ scrobble: RecentScrobblesEntry.Scrobble) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork(scrobble.image, size: 64)
            Spacer(minLength: 0)
            status(scrobble)
            Text(scrobble.title).font(.subheadline.bold()).lineLimit(2)
            Text(scrobble.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 8) {
            Text("RECENT SCROBBLES").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(Array(entry.scrobbles.enumerated()), id: \.offset) { _, scrobble in
                HStack(spacing: 10) {
                    artwork(scrobble.image, size: family == .systemLarge ? 40 : 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scrobble.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(scrobble.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    status(scrobble)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func status(_ scrobble: RecentScrobblesEntry.Scrobble) -> some View {
        if let date = scrobble.date {
            Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Group {
                if family == .systemSmall {
                    Label("Now playing", systemImage: "waveform")
                } else {
                    Image(systemName: "waveform")
                }
            }
            .font(.caption2.bold()).foregroundStyle(.tint)
        }
    }

    private func artwork(_ image: UIImage?, size: CGFloat) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size / 6))
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct RecentScrobblesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentScrobbles", provider: RecentScrobblesProvider()) { entry in
            RecentScrobblesWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent Scrobbles")
        .description("What you're playing and your last few scrobbles.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
