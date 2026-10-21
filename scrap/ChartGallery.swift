import AppKit
import SwiftUI

@MainActor
final class ChartGalleryController {
    static let shared = ChartGalleryController()
    private var windows: [ChartKind: NSWindow] = [:]

    func show(_ kind: ChartKind, period: ChartPeriod, client: LastFMClient) {
        let window = windows[kind] ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 420, height: 320)
            window.center()
            windows[kind] = window
            return window
        }()
        window.title = kind.title
        window.subtitle = period.title
        window.contentViewController = NSHostingController(rootView: ChartGalleryView(kind: kind, period: period, client: client))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ChartGalleryView: View {
    let kind: ChartKind
    let period: ChartPeriod
    @ObservedObject var client: LastFMClient
    @State private var entries: [ProfileChartEntry]?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            if let error { Text(error).foregroundStyle(.red).padding() }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(Array((entries ?? []).enumerated()), id: \.element.id) { index, entry in
                    Link(destination: entry.link.url) { cell(entry, rank: index + 1) }
                        .buttonStyle(.plain)
                        .help("Open \(entry.link.name) on Last.fm")
                }
            }
            .padding(20)
        }
        .overlay {
            if entries == nil, error == nil { ProgressView() }
            else if entries?.isEmpty == true { Text("Nothing scrobbled in this period.").foregroundStyle(.secondary) }
        }
        .frame(minWidth: 420, minHeight: 320)
        .task { await load() }
    }

    private func cell(_ entry: ProfileChartEntry, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { GalleryArtwork(kind: kind, entry: entry, client: client) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    Text("\(rank)")
                        .font(.caption.bold()).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(7)
                }
            Text(entry.link.name).font(.callout.bold()).lineLimit(1).padding(.top, 4)
            if kind != .artists {
                Text(entry.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(entry.count.formatted()) scrobbles").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            let result = try await client.profileChart(kind, period: period, limit: 50)
            guard !Task.isCancelled else { return }
            entries = result
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn’t load \(kind.title.lowercased()). \(error.localizedDescription)"
        }
    }
}

private struct GalleryArtwork: View {
    let kind: ChartKind
    let entry: ProfileChartEntry
    @ObservedObject var client: LastFMClient
    @State private var trackCovers: [URL] = []

    var body: some View {
        GeometryReader { proxy in
            if kind == .artists {
                ArtistPortrait(name: entry.link.name, size: proxy.size.width)
            } else {
                RemoteAlbumArtwork(url: entry.link.imageURL ?? trackCovers.first, alternatives: entry.link.imageAlternatives + trackCovers.dropFirst()) {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: kind == .albums ? "opticaldisc" : "music.note").font(.title).foregroundStyle(.secondary))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .task(id: entry.id) {
            guard kind == .tracks, entry.link.imageURL == nil else { return }
            trackCovers = await client.trackArtwork(artist: entry.artist, track: entry.link.name)
        }
    }
}
