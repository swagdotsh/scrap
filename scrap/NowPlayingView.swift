import SwiftUI
import MediaPlayer

struct NowPlayingView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var scrobbler: PlayCountScrobbler
    @EnvironmentObject private var nowPlaying: NowPlayingListener
    @State private var details: ListeningDetails?
    @State private var animatedCover: UIImage?
    @State private var remote: RecentScrobble?
    @State private var remoteUser: String?
    @AppStorage("animatedAlbumCovers") private var animatedSetting = false
    @AppStorage("removeAlbumTypeSuffix") private var removeAlbumTypeSuffix = false
    @AppStorage("removeAppleMusicEdition") private var removeAppleMusicEdition = false
    @AppStorage("usePrimaryArtist") private var usePrimaryArtist = false
    @AppStorage("removeFeaturedArtists") private var removeFeaturedArtists = false
    @AppStorage("preservedArtistNames") private var preservedArtistNames = LastFMClient.defaultPreservedArtistNames
    @ObservedObject private var conditions = DeviceConditions.shared

    private var animatedCovers: Bool { animatedSetting && !conditions.limitsAnimation }

    private var remoteTrack: PlayingTrack? {
        remote.map { PlayingTrack(title: $0.title, artist: $0.artist, album: $0.album, duration: nil) }
    }

    private func isThisDevice(_ remote: PlayingTrack, local: PlayingTrack) -> Bool {
        let names = lastFM.scrobbledNames(for: local)
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        return (same(remote.artist, local.artist) || same(remote.artist, names.artist))
            && (same(remote.title, local.title) || same(remote.title, names.title))
    }

    private var shown: (track: PlayingTrack, isRemote: Bool)? {
        let local = nowPlaying.track
        if let local, nowPlaying.isPlaying { return (local, false) }
        if let remoteTrack, !(local.map { isThisDevice(remoteTrack, local: $0) } ?? false) { return (remoteTrack, true) }
        if let local { return (local, false) }
        return nil
    }

    private var shownKey: String {
        shown.map { "\($0.isRemote)|\($0.track.artist)|\($0.track.title)|\($0.track.album)" } ?? ""
    }

    var body: some View {
        List {
            if let (track, isRemote) = shown {
                Section {
                    trackCard(track, isRemote: isRemote)
                    if let details {
                        summary(details, track: track).font(.subheadline).foregroundStyle(.secondary)
                        if !details.trackTags.isEmpty { TagChips(tags: details.trackTags) }
                    }
                } header: {
                    if isRemote {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Now playing from another device").font(.headline).foregroundStyle(.primary)
                            Text("Reported from last.fm. This isn't coming from this device.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .padding(.bottom, 4)
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
        .refreshable { await scrobbler.sync(); await lastFM.retryPending(); await loadRemote() }
        .task(id: "\(lastFM.username ?? "")|\(shownKey)") {
            details = nil
            guard let track = shown?.track else { return }
            let result = await lastFM.listeningDetails(for: track)
            if !Task.isCancelled { details = result }
        }
        .task(id: "\(lastFM.username ?? "")|\(nowPlaying.isPlaying)") {
            if remoteUser != lastFM.username { remote = nil; remoteUser = lastFM.username }
            guard !nowPlaying.isPlaying else { return }
            while !Task.isCancelled {
                await loadRemote()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: "\(shown?.track.artist ?? "")|\(shown?.track.album ?? "")|\(animatedCovers)") {
            animatedCover = nil
            guard animatedCovers, let track = shown?.track,
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

    private func summary(_ details: ListeningDetails, track: PlayingTrack) -> Text {
        guard let artistCount = details.artistCount, let trackCount = details.trackCount else {
            return Text("Listening history unavailable.")
        }
        let artist = Text(track.artist).bold().foregroundStyle(.primary)
        let title = Text(track.title).bold().foregroundStyle(.primary)
        if artistCount == 0 { return Text("You've never scrobbled \(artist) before.") }
        if trackCount == 0 { return Text("You've scrobbled \(artist) \(artistCount.formatted()) times, but not this track.") }
        return Text("You've scrobbled \(artist) \(artistCount.formatted()) times and \(title) \(trackCount.formatted()) times.")
    }

    private func scrobblingAsNote(_ track: PlayingTrack) -> String? {
        let names = lastFM.scrobbledNames(for: track)
        guard names.title != track.title || names.artist != track.artist || names.album != track.album else { return nil }
        var note = "Scrobbling as \(names.title) by \(names.artist)"
        if !names.album.isEmpty { note += " on \(names.album)" }
        return note
    }

    private func loadRemote() async {
        let username = lastFM.username
        guard let result = try? await lastFM.recentScrobbles(limit: 1), !Task.isCancelled,
              lastFM.username == username else { return }
        remote = result.nowPlaying
    }

    private func trackCard(_ track: PlayingTrack, isRemote: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let animatedCover {
                    AnimatedImageView(image: animatedCover)
                } else if isRemote {
                    CoverImage(url: remote?.coverURL) {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                    }
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
                        .multilineTextAlignment(.leading)
                }
                Link(destination: track.artistURL) {
                    Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                }
                if !track.album.isEmpty {
                    Link(destination: track.albumURL) {
                        Text(track.album).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !isRemote, let note = scrobblingAsNote(track) {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.top, 2)
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
                Link("More about \(name)", destination: url)
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
