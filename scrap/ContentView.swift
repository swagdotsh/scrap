import SwiftUI

private enum Page: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing", scrobbles = "Scrobbles", profile = "Profile", friends = "Friends"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .scrobbles: "clock.arrow.circlepath"
        case .profile: "person.crop.circle"
        case .friends: "person.2"
        }
    }
}

struct ContentView: View {
    @ObservedObject var listener: NowPlayingListener
    @ObservedObject var engine: ScrobbleEngine
    @ObservedObject var client: LastFMClient
    var isMenuBar = false
    @State private var selection: Page = .nowPlaying
    @State private var details: ListeningDetails?
    @State private var recent: [RecentScrobble] = []
    @State private var profile: ListenerProfile?
    @State private var topArtists: [ProfileChartEntry] = []
    @State private var topAlbums: [ProfileChartEntry] = []
    @State private var topSongs: [ProfileChartEntry] = []
    @State private var isLoading = false
    @State private var pageError: String?
    @State private var refreshID = 0

    private var detailTaskID: String {
        [listener.track?.title ?? "", listener.track?.artist ?? "", listener.track?.album ?? "", client.username ?? "", String(client.canScrobble)].joined(separator: "\u{001F}")
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Page.allCases) { page in
                    Button { selection = page } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                            .font(.system(size: 12, weight: selection == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(selection == page ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == page ? .isSelected : [])
                }
                Spacer()
                if isMenuBar {
                    Button("Quit Scrap") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(10)
                }
            }
            .padding(10).frame(width: 142).frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selection {
                        case .nowPlaying: nowPlaying
                        case .scrobbles: scrobbles
                        case .profile: profilePage
                        case .friends: friendsPage
                        }
                        if let error = listener.errorMessage, selection == .nowPlaying {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        if !client.canScrobble { connectionControls }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }
                HStack {
                    Spacer()
                    Circle()
                        .fill(!client.canScrobble ? Color.orange : client.lastFMReachable == true ? Color.green : client.lastFMReachable == false ? Color.red : Color.orange)
                        .frame(width: 8, height: 8)
                        .help(client.connectionHelp)
                        .accessibilityLabel(client.connectionHelp)
                    Text(client.canScrobble ? "Connected as \(client.username ?? "")" : "Not connected")
                        .font(.caption).italic().foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.bottom, 14)
            }
        }
        .frame(width: 680, height: 350)
        .task(id: detailTaskID) {
            details = nil
            guard let track = listener.track else { return }
            let result = await client.listeningDetails(for: track) { partial in
                guard !Task.isCancelled else { return }
                details = partial
            }
            guard !Task.isCancelled else { return }
            details = result
        }
        .task(id: "\(selection.rawValue)-\(client.username ?? "")-\(client.canScrobble)-\(refreshID)") {
            guard client.canScrobble else {
                profile = nil; recent = []; topArtists = []; topAlbums = []; topSongs = []
                isLoading = false
                return
            }
            guard selection != .nowPlaying else { return }
            if selection == .friends { await client.refreshFriends(); return }
            isLoading = true
            pageError = nil
            do {
                if selection == .scrobbles {
                    let rows = try await client.recentScrobbles()
                    guard !Task.isCancelled else { return }
                    recent = rows
                } else {
                    let result = try await client.profile()
                    guard !Task.isCancelled else { return }
                    profile = result
                    let artists = try await client.profileChart(kind: "artists")
                    let albums = try await client.profileChart(kind: "albums")
                    let songs = try await client.profileChart(kind: "tracks")
                    guard !Task.isCancelled else { return }
                    topArtists = artists; topAlbums = albums; topSongs = songs
                }
            } catch {
                guard !Task.isCancelled else { return }
                pageError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .top, spacing: 20) {
            Group {
                if let image = details?.coverImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    .overlay(Image(systemName: "music.note").font(.system(size: 32)).foregroundStyle(.tertiary))
                }
            }
            .frame(width: 136, height: 136).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Album artwork")
            VStack(alignment: .leading, spacing: 12) {
                if let track = listener.track {
                    Link(destination: track.trackURL) {
                        Text(track.title).font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.plain)
                    (linkedName(track.artist, url: track.artistURL) + Text(track.album.isEmpty ? "" : " · ") + linkedName(track.album, url: track.albumURL).italic())
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: progress(track))
                        .accessibilityLabel("Scrobble progress")
                    listeningSummary(track)
                        .font(.callout).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let details {
                        linkChips(details.trackTags)
                    }
                    if !listener.isPlaying { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Nothing playing").font(.title2.bold())
                    Text("Play something in Apple Music.").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        if let track = listener.track, let details {
            aboutArtist(track.artist, details: details.artist)
        }
        }.padding(.top, 16)
    }

    private func linkedName(_ name: String, url: URL) -> Text {
        var text = AttributedString(name)
        text.link = url
        text.foregroundColor = Color(nsColor: .secondaryLabelColor)
        return Text(text)
    }

    private func listeningSummary(_ track: PlayingTrack) -> Text {
        guard let details else { return Text("Loading your listening history…") }
        guard let artistCount = details.artistCount, let trackCount = details.trackCount else {
            return Text("Listening history unavailable.")
        }
        if artistCount == 0 {
            return Text("You've never scrobbled ") + linkedName(track.artist, url: track.artistURL).bold() + Text(" before.")
        }
        if trackCount == 0 {
            return Text("You've scrobbled ") + linkedName(track.artist, url: track.artistURL).bold() + Text(" \(artistCount) times, but not this track.")
        }
        return Text("You've scrobbled to ") + linkedName(track.artist, url: track.artistURL).bold() + Text(" \(artistCount) times and ") + linkedName(track.title, url: track.trackURL).bold() + Text(" \(trackCount) times.")
    }

    private func linkChips(_ links: [MusicLink]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(links) { item in
                    Link(item.name, destination: item.url)
                        .font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
        }.scrollIndicators(.automatic)
    }

    private func aboutArtist(_ name: String, details: ArtistDetails) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    if let url = details.url {
                        Link("About \(name)", destination: url).font(.headline)
                    } else {
                        Text("About \(name)").font(.headline)
                    }
                    if !details.biography.isEmpty {
                        ArtistBiography(name: name, text: details.biography)
                        if let url = details.url { Link("Read more on Last.fm", destination: url).font(.caption) }
                    } else {
                        ArtistPortrait(name: name, size: 72)
                        Text("No biography available.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let plays = details.totalPlays {
                        if let url = details.url {
                            Link("\(plays.formatted()) total plays on Last.fm", destination: url).font(.caption)
                        } else {
                            Text("\(plays.formatted()) total plays on Last.fm").font(.caption)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Top albums").font(.subheadline.bold())
                    if details.topAlbums.isEmpty {
                        Text("No albums available.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(details.topAlbums) { item in
                        Link(destination: item.url) {
                            HStack(spacing: 8) {
                                AsyncImage(url: item.imageURL) { image in image.resizable().scaledToFill() } placeholder: {
                                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                                        .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
                                }
                                .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(item.name).font(.callout)
                            }
                        }
                    }
                    Text("Top tracks").font(.subheadline.bold()).padding(.top, 4)
                    if details.topTracks.isEmpty {
                        Text("No tracks available.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(details.topTracks) { item in
                        Link(destination: item.url) {
                            HStack(spacing: 8) {
                                profileImage(item.imageURL, size: 32)
                                Text(item.name).font(.callout)
                            }
                        }
                    }
                    Text("Tags").font(.subheadline.bold()).padding(.top, 4)
                    if details.tags.isEmpty {
                        Text("No tags available.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        linkChips(details.tags)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Link("Artist images from TheAudioDB", destination: URL(string: "https://www.theaudiodb.com")!)
                .font(.caption2).foregroundStyle(.secondary)
            Text("Similar artists").font(.subheadline.bold())
            if details.similar.isEmpty {
                Text("No similar artists available.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(details.similar) { item in
                            Link(destination: item.url) {
                                VStack(spacing: 8) {
                                    ArtistPortrait(name: item.name, size: 42)
                                    Text(item.name).font(.callout).lineLimit(2)
                                }
                                .frame(width: 112, height: 78)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }.padding(.bottom, 6)
                }.scrollIndicators(.visible)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progress(_ track: PlayingTrack) -> Double {
        guard client.canScrobble, let duration = track.duration, duration > 30 else { return 0 }
        return min(1, engine.accumulatedPlayTime / min(240, duration / 2))
    }

    private var scrobbles: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageHeader("Scrobbles")
            if isLoading { ProgressView() }
            if let pageError { Text(pageError).foregroundStyle(.red) }
            if client.pendingCount > 0 {
                Button("Retry pending (\(client.pendingCount))") { Task { await client.retryPending(); refreshID += 1 } }
                    .disabled(client.isSending || !client.canScrobble)
            }
            if client.canScrobble {
                if !isLoading, recent.isEmpty, pageError == nil { Text("No scrobbles yet.").foregroundStyle(.secondary) }
                ForEach(recent) { row in
                    Link(destination: row.destination) {
                    HStack(spacing: 12) {
                        AsyncImage(url: row.coverURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                                .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Album cover for \(row.title)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.headline)
                            HStack {
                                Text(row.artist)
                                Spacer()
                                Text(row.date.formatted(date: .abbreviated, time: .shortened))
                            }.font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(row.title) on Last.fm")
                    Divider()
                }
                if !recent.isEmpty { Text("Latest 50 scrobbles").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var friendsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Friends").font(.title2.bold())
                Spacer()
                Button { Task { await client.refreshFriends(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(client.friendsLoading || !client.isConfigured || client.username == nil)
                    .help("Refresh friends")
            }
            Text("Recent listening · refreshes hourly while Scrap is running")
                .font(.caption).foregroundStyle(.secondary)
            if client.friendsLoading { ProgressView() }
            if let error = client.friendsError { Text(error).font(.caption).foregroundStyle(.red) }
            ForEach(client.friends) { friend in
                Link(destination: friend.profileURL) {
                    HStack(spacing: 12) {
                        profileImage(friend.avatarURL, size: 44, symbol: "person.crop.circle")
                            .accessibilityLabel("Profile picture of \(friend.name)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(friend.name).font(.headline)
                            Text(friend.track.map { $0 + (friend.artist.map { " · " + $0 } ?? "") } ?? "No recent listening available")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(friend.name)’s Last.fm profile")
                Divider()
            }
            if let updated = client.friendsUpdatedAt {
                if client.friends.isEmpty { Text("No friends returned by Last.fm.").foregroundStyle(.secondary) }
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).italic().foregroundStyle(.secondary)
            }
        }
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader("Profile")
            if isLoading { ProgressView() }
            if let pageError { Text(pageError).foregroundStyle(.red) }
            if let profile {
                HStack(alignment: .center, spacing: 14) {
                    profileImage(profile.avatarURL, size: 64, symbol: "person.crop.circle")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name).font(.title2.bold())
                        if !profile.realName.isEmpty { Text(profile.realName).foregroundStyle(.secondary) }
                        Text("\(profile.playCount) scrobbles").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 10) {
                        if let url = profile.url { Link("View on Last.fm", destination: url).font(.caption) }
                        Button("Reconnect Last.fm") { Task { await client.beginAuth() } }.disabled(client.isBusy)
                        if client.pendingToken != nil {
                            Button("I've approved it") { Task { await client.completeAuth() } }.disabled(client.isBusy)
                            Text(client.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Most played · All time").font(.headline).padding(.top, 8)
                chartSection("Artists", entries: topArtists, artists: true)
                chartSection("Albums", entries: topAlbums)
                chartSection("Songs", entries: topSongs)
            }

        }
    }

    private func profileImage(_ url: URL?, size: CGFloat, symbol: String = "opticaldisc") -> some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                .overlay(Image(systemName: symbol).foregroundStyle(.secondary))
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func chartSection(_ title: String, entries: [ProfileChartEntry], artists: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.bold())
            if entries.isEmpty && !isLoading { Text("No listening data yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(entries) { item in
                Link(destination: item.link.url) {
                    HStack(spacing: 10) {
                        if artists { ArtistPortrait(name: item.link.name, size: 36) }
                        else { profileImage(item.link.imageURL, size: 36) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.link.name).font(.callout).lineLimit(2)
                            if !item.artist.isEmpty { Text(item.artist).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(item.count.formatted()).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func pageHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.title2.bold())
            Spacer()
            Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }
                .disabled(isLoading || !client.canScrobble).help("Refresh")
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !client.isConfigured {
                Text("Add your Last.fm app credentials to .env, then rebuild Scrap.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(client.sessionKey == nil ? "Connect Last.fm" : "Reconnect Last.fm") { Task { await client.beginAuth() } }
                    if client.pendingToken != nil {
                        Button("I've approved it") { Task { await client.completeAuth() } }
                    }
                }.disabled(client.isBusy)
                if !client.canScrobble || client.pendingToken != nil {
                    Text(client.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
