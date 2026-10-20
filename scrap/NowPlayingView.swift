import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var scrobbler: PlayCountScrobbler
    @EnvironmentObject private var nowPlaying: NowPlayingListener
    @State private var details: ListeningDetails?
    @State private var animatedCover: UIImage?
    @AppStorage("animatedAlbumCovers") private var animatedSetting = false
    @ObservedObject private var conditions = DeviceConditions.shared

    private var animatedCovers: Bool { animatedSetting && !conditions.limitsAnimation }

    var body: some View {
        List {
            if let track = nowPlaying.track {
                Section {
                    trackCard(track)
                    if let details {
                        Text(details.summary(for: track)).font(.subheadline).foregroundStyle(.secondary)
                        if !details.trackTags.isEmpty { TagChips(tags: details.trackTags) }
                    }
                }
                if let details {
                    artistSections(track.artist, details: details.artist)
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            } else {
                emptyState
            }
        }
        .tint(.primary)
        .refreshable { await scrobbler.sync(); await lastFM.retryPending() }
        .task(id: nowPlaying.track) {
            details = nil
            guard let track = nowPlaying.track else { return }
            let result = await lastFM.listeningDetails(for: track)
            if !Task.isCancelled { details = result }
        }
        .task(id: "\(nowPlaying.track?.artist ?? "")|\(nowPlaying.track?.album ?? "")|\(animatedCovers)") {
            animatedCover = nil
            guard animatedCovers, let track = nowPlaying.track,
                  let url = await lastFM.albumCoverURL(artist: track.artist, album: track.album) else { return }
            let image = await CoverLoader.load(url, animated: true)
            if !Task.isCancelled, CoverLoader.isAnimated(image) { animatedCover = image }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch scrobbler.authorization {
        case .authorized:
            ContentUnavailableView("Nothing playing", systemImage: "music.note",
                                   description: Text("Play something in Apple Music and it'll show up here."))
        case .denied, .restricted:
            ContentUnavailableView {
                Label("No access to Apple Music", systemImage: "lock")
            } description: {
                Text("scrap needs access to Apple Music to see what you play.")
            } actions: {
                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            }
        default:
            ContentUnavailableView {
                Label("Allow Apple Music", systemImage: "music.note")
            } description: {
                Text("scrap reads your library's play counts to scrobble them.")
            } actions: {
                Button("Allow access") {
                    Task {
                        await scrobbler.requestAccess()
                        if scrobbler.authorization == .authorized { nowPlaying.start() }
                    }
                }
                .prominentButtonStyle()
                .tint(.accentColor)
            }
        }
    }

    private func trackCard(_ track: PlayingTrack) -> some View {
        HStack(spacing: 12) {
            Group {
                if let animatedCover {
                    AnimatedImageView(image: animatedCover)
                } else if let image = nowPlaying.artwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Link(destination: track.trackURL) {
                    Text(track.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                }
                Link(destination: track.artistURL) {
                    Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                }
                if !track.album.isEmpty {
                    Link(destination: track.albumURL) {
                        Text(track.album).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.borderless)
            Spacer()
            loveButton(for: track)
        }
        .task(id: track) { await lastFM.refreshLovedState(for: track) }
    }

    private func loveButton(for track: PlayingTrack) -> some View {
        let loved = lastFM.lovedState(for: track) ?? false
        return Button {
            Task { await lastFM.love(track, loved: !loved) }
        } label: {
            Image(systemName: loved ? "heart.fill" : "heart")
                .font(.title2)
                .foregroundStyle(loved ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(lastFM.lovedState(for: track) == nil || lastFM.loveRequests.contains([track.artist, track.title]))
        .accessibilityLabel(loved ? "Unlove" : "Love")
    }

    @ViewBuilder private func artistSections(_ name: String, details: ArtistDetails) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                ArtistPortrait(name: name, size: 72)
                Text(details.biography.isEmpty ? "No biography available." : details.biography)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(6)
            }
            if let plays = details.totalPlays {
                LabeledContent("Total plays on last.fm", value: plays.formatted())
            }
            if let url = details.url {
                Link("Read more on last.fm", destination: url)
            }
        } header: {
            Text("About \(name)")
        }

        if !details.topAlbums.isEmpty {
            Section("Top albums") {
                ForEach(details.topAlbums) { album in
                    LinkRow(url: album.url, title: album.name) { RemoteArtwork(url: album.imageURL, symbol: "opticaldisc") }
                }
            }
        }

        if !details.topTracks.isEmpty {
            Section("Top tracks") {
                ForEach(details.topTracks) { track in
                    LinkRow(url: track.url, title: track.name) { RemoteArtwork(url: track.imageURL) }
                }
            }
        }

        if !details.tags.isEmpty {
            Section("Tags") { TagChips(tags: details.tags) }
        }

        if !details.similar.isEmpty {
            Section("Similar artists") {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(details.similar) { artist in
                            Link(destination: artist.url) {
                                VStack(spacing: 6) {
                                    ArtistPortrait(name: artist.name, size: 80)
                                    Text(artist.name).font(.caption).foregroundStyle(.primary)
                                        .lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(width: 88)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}
