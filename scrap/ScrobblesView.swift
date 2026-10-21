import SwiftUI

struct ScrobblesView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var scrobbler: PlayCountScrobbler
    @EnvironmentObject private var nowPlaying: NowPlayingListener
    @State private var scrobbles: [RecentScrobble] = []
    @State private var remoteNowPlaying: RecentScrobble?
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if nowPlaying.isPlaying, let track = nowPlaying.track {
                Section {
                    Link(destination: track.trackURL) {
                        HStack(spacing: 12) {
                            Group {
                                if let image = nowPlaying.artwork {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "music.note").foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).foregroundStyle(.primary).lineLimit(1)
                                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            nowPlayingBadge
                        }
                    }
                }
            } else if let remote = remoteNowPlaying {
                Section {
                    Link(destination: remote.destination) {
                        HStack(spacing: 12) {
                            RemoteArtwork(url: remote.coverURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(remote.title).foregroundStyle(.primary).lineLimit(1)
                                Text(remote.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            nowPlayingBadge
                        }
                    }
                } footer: {
                    Text("Playing on another device, according to last.fm.")
                }
            }

            if lastFM.pendingCount > 0 {
                Section {
                    Button("Send \(lastFM.pendingCount) waiting scrobble\(lastFM.pendingCount == 1 ? "" : "s")") {
                        Task { await lastFM.retryPending() }
                    }
                    .disabled(lastFM.isSending)
                }
            }

            Section {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(scrobbles) { scrobble in
                    LinkRow(url: scrobble.destination, title: scrobble.title, subtitle: scrobble.artist,
                            trailing: scrobble.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))) {
                        RemoteArtwork(url: scrobble.coverURL)
                    }
                }
            }

            if let username = lastFM.username, loaded {
                Section {
                    Link("Show more…", destination: URL(string: "https://www.last.fm/user/")!
                        .appendingPathComponent(username).appendingPathComponent("library"))
                }
            }
        }
        .tint(.primary)
        .refreshable {
            await scrobbler.sync()
            await lastFM.retryPending()
            await load()
        }
        .task(id: "\(nowPlaying.track?.title ?? "")|\(lastFM.pendingCount)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var nowPlayingBadge: some View {
        Text("Now playing")
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
    }

    private func load() async {
        do {
            let result = try await lastFM.recentScrobbles(limit: 50)
            guard !Task.isCancelled else { return }
            scrobbles = result.scrobbles
            remoteNowPlaying = result.nowPlaying
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't load scrobbles. \(error.localizedDescription)"
        }
        loaded = true
    }
}
