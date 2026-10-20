import SwiftUI

struct ChartGalleryView: View {
    let kind: ChartKind
    let period: ChartPeriod
    @EnvironmentObject private var lastFM: LastFMClient
    @State private var entries: [ProfileChartEntry]?
    @State private var error: String?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            if let error {
                Text(error).foregroundStyle(.red).padding()
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(Array((entries ?? []).enumerated()), id: \.element.id) { index, entry in
                    Link(destination: entry.link.url) { cell(entry, rank: index + 1) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .overlay {
            if entries == nil, error == nil { ProgressView() }
        }
        .tint(.primary)
        .navigationTitle(kind.title, subtitle: period.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func cell(_ entry: ProfileChartEntry, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ChartArtwork(kind: kind, entry: entry, size: nil) }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    Text("\(rank)")
                        .font(.caption.bold()).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .badgeBackground()
                        .padding(8)
                }
            Text(entry.link.name).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(1)
                .padding(.top, 4)
            if kind != .artists {
                Text(entry.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(entry.count.formatted()) scrobbles").font(.footnote).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
    }

    private func load() async {
        do {
            let result = try await lastFM.profileChart(kind, period: period, limit: 50)
            guard !Task.isCancelled else { return }
            entries = result
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't load \(kind.title.lowercased()). \(error.localizedDescription)"
        }
    }
}

struct ChartArtwork: View {
    let kind: ChartKind
    let entry: ProfileChartEntry
    var size: CGFloat?
    @EnvironmentObject private var lastFM: LastFMClient
    @State private var trackCover: URL?

    var body: some View {
        if kind == .artists {
            ArtistPortrait(name: entry.link.name, size: size)
        } else {
            RemoteArtwork(url: entry.link.imageURL ?? trackCover, symbol: kind == .albums ? "opticaldisc" : "music.note", size: size)
                .task(id: entry.id) {
                    guard kind == .tracks, entry.link.imageURL == nil else { return }
                    trackCover = await lastFM.trackArtwork(artist: entry.artist, track: entry.link.name)
                }
        }
    }
}
