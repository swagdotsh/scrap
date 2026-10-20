import WidgetKit
import SwiftUI
import AppIntents

enum TopArtistPeriod: String, AppEnum {
    case week = "7day", month = "1month", year = "12month", overall

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [TopArtistPeriod: DisplayRepresentation] = [
        .week: "Last 7 days", .month: "Last 30 days", .year: "Last 365 days", .overall: "All time"
    ]

    var shortTitle: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .year: "365 days"
        case .overall: "All time"
        }
    }
}

struct TopArtistIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Top Artist"
    static let description = IntentDescription("Your most scrobbled artists.")

    @Parameter(title: "Period", default: .week)
    var period: TopArtistPeriod
}

struct TopArtistEntry: TimelineEntry {
    struct Artist {
        let name: String
        let plays: Int
        var image: UIImage?
    }

    let date: Date
    let period: TopArtistPeriod
    var artists: [Artist] = []
    var signedIn = true

    static let sample = TopArtistEntry(date: .now, period: .week, artists: [
        Artist(name: "Summrs", plays: 142), Artist(name: "Yeat", plays: 96), Artist(name: "YoungBoy Never Broke Again", plays: 71)
    ])
}

struct TopArtistProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TopArtistEntry { .sample }

    func snapshot(for configuration: TopArtistIntent, in context: Context) async -> TopArtistEntry {
        guard context.isPreview else { return await load(configuration.period, family: context.family) }
        var sample = TopArtistEntry.sample
        sample.artists[0].image = await WidgetLastFM.image(await WidgetLastFM.artistPortraitURL("Summrs"), width: 500)
        return sample
    }

    func timeline(for configuration: TopArtistIntent, in context: Context) async -> Timeline<TopArtistEntry> {
        let entry = await load(configuration.period, family: context.family)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func load(_ period: TopArtistPeriod, family: WidgetFamily) async -> TopArtistEntry {
        var entry = TopArtistEntry(date: .now, period: period)
        guard let credentials = WidgetLastFM.credentials else {
            entry.signedIn = false
            return entry
        }
        let limit = [.systemMedium, .accessoryRectangular].contains(family) ? 3 : 1
        guard let json = try? await WidgetLastFM.request(["method": "user.getTopArtists", "user": credentials.username,
                                                          "period": period.rawValue, "limit": String(limit)], credentials: credentials) else { return entry }
        let root = json["topartists"] as? [String: Any]
        let rows = root?["artist"] as? [[String: Any]] ?? (root?["artist"] as? [String: Any]).map { [$0] } ?? []
        entry.artists = rows.prefix(limit).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return TopArtistEntry.Artist(name: name, plays: WidgetLastFM.count(row["playcount"]))
        }
        if let top = entry.artists.first {
            let width: CGFloat = family == .accessoryCircular ? 200 : 500
            if family != .accessoryInline, family != .accessoryRectangular {
                entry.artists[0].image = await WidgetLastFM.image(await WidgetLastFM.artistPortraitURL(top.name), width: width)
            }
        }
        return entry
    }
}

struct TopArtistWidgetView: View {
    let entry: TopArtistEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if !entry.signedIn {
                message("Open scrap to sign in to last.fm.")
            } else if let top = entry.artists.first {
                switch family {
                case .systemSmall: small(top)
                case .accessoryCircular: circular(top)
                case .accessoryRectangular: rectangular
                case .accessoryInline: inline(top)
                default: medium(top)
                }
            } else {
                message("No scrobbles in the last \(entry.period.shortTitle.lowercased()).")
            }
        }
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private var background: some View {
        if family == .systemSmall, entry.signedIn, let image = entry.artists.first?.image {
            Image(uiImage: image).resizable().scaledToFill()
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom))
        } else if family == .accessoryCircular {
            AccessoryWidgetBackground()
        } else if [.accessoryRectangular, .accessoryInline].contains(family) {
            Color.clear
        } else if family == .systemSmall {
            LinearGradient(colors: [Color(red: 0.16, green: 0.37, blue: 0.96), Color(red: 0.34, green: 0.75, blue: 0.98)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            Color(.systemBackground)
        }
    }

    private func small(_ artist: TopArtistEntry.Artist) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer()
            Text("TOP ARTIST · \(entry.period.shortTitle.uppercased())")
                .font(.caption2.bold()).foregroundStyle(.white.opacity(0.8))
            Text(artist.name).font(.headline).foregroundStyle(.white).lineLimit(2)
            Text("\(artist.plays.formatted()) plays").font(.caption).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ top: TopArtistEntry.Artist) -> some View {
        HStack(spacing: 14) {
            Group {
                if let image = top.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.mic").font(.largeTitle).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(.rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
                Text("TOP ARTISTS · \(entry.period.shortTitle.uppercased())")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                ForEach(Array(entry.artists.enumerated()), id: \.offset) { index, artist in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary).monospacedDigit()
                        Text(artist.name).font(index == 0 ? .headline : .subheadline).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(artist.plays.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func circular(_ artist: TopArtistEntry.Artist) -> some View {
        Group {
            if let image = artist.image {
                Image(uiImage: image).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
            } else {
                Text(initials(artist.name)).font(.title3.bold()).widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Circle())
        .accessibilityLabel("Top artist: \(artist.name), \(artist.plays) plays")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Top artists · \(entry.period.shortTitle)").font(.caption2.bold()).widgetAccentable()
            ForEach(Array(entry.artists.enumerated()), id: \.offset) { index, artist in
                HStack(spacing: 4) {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    Text(artist.name).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(artist.plays.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ artist: TopArtistEntry.Artist) -> some View {
        Label("\(artist.name) · \(artist.plays.formatted()) plays", systemImage: "music.mic")
    }

    private func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    private func message(_ text: String) -> some View {
        Group {
            switch family {
            case .accessoryInline, .accessoryCircular, .accessoryRectangular:
                Text(entry.signedIn ? "No scrobbles" : "Open scrap").font(.caption)
            default:
                Text(text).font(.footnote).foregroundStyle(family == .systemSmall ? .white : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}

struct TopArtistWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TopArtist", intent: TopArtistIntent.self, provider: TopArtistProvider()) { entry in
            TopArtistWidgetView(entry: entry)
        }
        .configurationDisplayName("Top Artist")
        .description("Your most scrobbled artists.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
