import SwiftUI

struct ReportsView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @State private var report: WeeklyReport?
    @State private var error: String?
    private let week = WeeklyReport.latestWeek()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weekTitle).font(.title2.bold())
                    Text("Next report \(WeeklyReport.nextReportDate(after: week).formatted(.dateTime.weekday(.wide).month().day()))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let report {
                scrobbleSection(report)
                topSection(report)
                discoverySection("New artists", items: report.newArtists, kind: .artists)
                discoverySection("New albums", items: report.newAlbums, kind: .albums)
                discoverySection("New tracks", items: report.newTracks, kind: .tracks)
            } else if error == nil {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Building your report…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tint(.primary)
        .refreshable { await load() }
        .task(id: lastFM.username) { if report == nil { await load() } }
    }

    private var weekTitle: String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: week.end)!
        return "\(week.start.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day()))"
    }

    private func scrobbleSection(_ report: WeeklyReport) -> some View {
        Section("Scrobbles") {
            HStack(alignment: .firstTextBaseline) {
                Text(report.scrobbles.formatted()).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Spacer()
                if report.previousScrobbles > 0 {
                    let change = Double(report.scrobbles - report.previousScrobbles) / Double(report.previousScrobbles)
                    Label(change.formatted(.percent.precision(.fractionLength(0))),
                          systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.headline)
                        .foregroundStyle(change >= 0 ? .green : .red)
                }
            }
            LabeledContent("Previous week", value: report.previousScrobbles.formatted())
        }
    }

    @ViewBuilder private func topSection(_ report: WeeklyReport) -> some View {
        Section("Top of the week") {
            if let artist = report.topArtist {
                LinkRow(url: artist.url, title: artist.name, subtitle: "Top artist", trailing: plays(artist.count)) {
                    ArtistPortrait(name: artist.name, size: 56)
                }
            }
            if let album = report.topAlbum {
                LinkRow(url: album.url, title: album.name, subtitle: "Top album · \(album.artist)", trailing: plays(album.count)) {
                    RemoteArtwork(url: album.imageURL, symbol: "opticaldisc", size: 56)
                }
            }
            if let track = report.topTrack {
                LinkRow(url: track.url, title: track.name, subtitle: "Top track · \(track.artist)", trailing: plays(track.count)) {
                    RemoteArtwork(url: track.imageURL, size: 56)
                }
            }
            if report.topArtist == nil {
                Text("No scrobbles this week.").foregroundStyle(.secondary)
            }
        }
    }

    private func discoverySection(_ title: String, items: [WeeklyReport.Item], kind: ChartKind) -> some View {
        Section {
            if items.isEmpty {
                Text("Nothing new this week.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                LinkRow(url: item.url, title: item.name, subtitle: kind == .artists ? nil : item.artist, trailing: plays(item.count)) {
                    if kind == .artists {
                        ArtistPortrait(name: item.name, size: 44)
                    } else {
                        RemoteArtwork(url: item.imageURL, symbol: kind == .albums ? "opticaldisc" : "music.note")
                    }
                }
            }
        } header: {
            Text(items.isEmpty ? title : "\(title) (\(items.count))")
        } footer: {
            if kind == .tracks {
                Text("Checks your \(WeeklyReport.discoveryCheckLimit) most-played artists, albums and tracks of the week.")
            }
        }
    }

    private func plays(_ count: Int) -> String {
        "\(count.formatted()) play\(count == 1 ? "" : "s")"
    }

    private func load() async {
        do {
            let result = try await lastFM.weeklyReport(for: week)
            guard !Task.isCancelled else { return }
            report = result
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't build your report. \(error.localizedDescription)"
        }
    }
}
