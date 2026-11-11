import SwiftUI

private enum Page: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing", reports = "Reports", scrobbles = "Scrobbles", profile = "Profile", friends = "Friends"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .reports: "chart.pie"
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
    @ObservedObject var updateChecker: UpdateChecker
    var isMenuBar = false
    @AppStorage("animatedAlbumCovers") private var animatedAlbumCovers = true
    @AppStorage("prioritizeAnimatedCovers") private var prioritizeAnimatedCovers = false
    @AppStorage("menuBarBackgroundOpacity") private var menuBarBackgroundOpacity = 0.95
    @AppStorage("removeAlbumTypeSuffix") private var removeAlbumTypeSuffix = false
    @AppStorage("removeAppleMusicEdition") private var removeAppleMusicEdition = false
    @AppStorage("usePrimaryArtist") private var usePrimaryArtist = false
    @AppStorage("removeFeaturedArtists") private var removeFeaturedArtists = false
    @AppStorage("preservedArtistNames") private var preservedArtistNames = LastFMClient.defaultPreservedArtistNames
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("selectedPage") private var selection: Page = .nowPlaying
    @AppStorage("profileChartPeriod") private var chartPeriod: ChartPeriod = .week
    @AppStorage("reportKind") private var reportKind: ReportKind = .week
    /// A historical period the user picked; nil follows the latest report.
    @State private var reportPeriod: ReportPeriod?
    @State private var report: ListeningReport?
    @State private var sessionReports: [ReportPeriod: ListeningReport] = [:]
    @State private var reportUser = ""
    @State private var reportRefresh = 0
    @State private var reportProgress: (done: Int, total: Int)?
    @State private var showPeriodPicker = false
    @State private var accountStart: Date?
    @State private var details: ListeningDetails?
    @State private var recent: [RecentScrobble] = []
    @State private var remoteNowPlaying: RecentScrobble?
    @State private var profile: ListenerProfile?
    @State private var topArtists: [ProfileChartEntry] = []
    @State private var topAlbums: [ProfileChartEntry] = []
    @State private var topSongs: [ProfileChartEntry] = []
    @State private var isLoading = false
    @State private var pageError: String?
    @State private var refreshID = 0

    private var detailTaskID: String {
        [listener.track?.title ?? "", listener.track?.artist ?? "", listener.track?.album ?? "", client.username ?? "", String(client.canScrobble), String(usePrimaryArtist), preservedArtistNames].joined(separator: "\u{001F}")
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
                Button {
                    PreferencesController.shared.show(client: client, updateChecker: updateChecker)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                if isMenuBar {
                    Button("Quit scrap") { NSApplication.shared.terminate(nil) }
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
                        case .reports: reportsPage
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
        .background(isMenuBar ? Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : min(1, max(0.5, menuBarBackgroundOpacity))) : .clear)
        .task(id: "love-\(detailTaskID)") {
            guard let track = listener.track else { return }
            await client.refreshLovedState(for: track)
        }
        .task(id: "\(detailTaskID)-animated-\(animatedAlbumCovers && prioritizeAnimatedCovers)") {
            details = nil
            guard let track = listener.track else { return }
            let result = await client.listeningDetails(for: artistDetailsTrack(track), preferAnimatedCovers: animatedAlbumCovers && prioritizeAnimatedCovers) { partial in
                guard !Task.isCancelled else { return }
                details = partial
            }
            guard !Task.isCancelled else { return }
            details = result
        }
        .task(id: "\(selection.rawValue)-\(client.username ?? "")-\(client.canScrobble)-\(refreshID)-\(selection == .profile ? chartPeriod.rawValue : "")-\(selection == .reports ? reportTaskID : "")") {
            guard client.canScrobble else {
                profile = nil; recent = []; remoteNowPlaying = nil; topArtists = []; topAlbums = []; topSongs = []
                isLoading = false
                return
            }
            guard selection != .nowPlaying else { return }
            if selection == .friends { await client.refreshFriends(); return }
            if selection == .reports {
                await loadReport()
                return
            }
            if selection == .scrobbles {
                isLoading = recent.isEmpty
                pageError = nil
                while !Task.isCancelled {
                    do {
                        let result = try await client.recentScrobbles()
                        guard !Task.isCancelled else { return }
                        recent = result.scrobbles
                        remoteNowPlaying = result.nowPlaying
                        pageError = nil
                    } catch {
                        guard !Task.isCancelled else { return }
                        pageError = error.localizedDescription
                    }
                    isLoading = false
                    try? await Task.sleep(for: .seconds(30))
                }
                return
            }
            isLoading = true
            pageError = nil
            do {
                let result = try await client.profile()
                guard !Task.isCancelled else { return }
                profile = result
                async let artists = client.profileChart(.artists, period: chartPeriod)
                async let albums = client.profileChart(.albums, period: chartPeriod)
                async let songs = client.profileChart(.tracks, period: chartPeriod)
                let (loadedArtists, loadedAlbums, loadedSongs) = try await (artists, albums, songs)
                guard !Task.isCancelled else { return }
                topArtists = loadedArtists; topAlbums = loadedAlbums; topSongs = loadedSongs
            } catch {
                guard !Task.isCancelled else { return }
                pageError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 10) {
        if let source = listener.source {
            Text("Now playing from \(source.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: 20) {
            Group {
                if animatedAlbumCovers, let image = details?.coverImage {
                    AlbumArtwork(image: image)
                } else if !animatedAlbumCovers, let url = details?.coverURL {
                    RemoteAlbumArtwork(url: url, alternatives: details?.coverAlternatives ?? []) {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                            .overlay(Image(systemName: "music.note").font(.system(size: 32)).foregroundStyle(.tertiary))
                    }
                } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    .overlay(Image(systemName: "music.note").font(.system(size: 32)).foregroundStyle(.tertiary))
                }
            }
            .frame(width: 136, height: 136).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Album artwork")
            VStack(alignment: .leading, spacing: 12) {
                if let track = listener.track {
                    HStack(alignment: .center, spacing: 12) {
                        Link(destination: track.trackURL) {
                            Text(track.title).font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        }.buttonStyle(.plain)
                        let loved = client.lovedState(for: track) ?? false
                        Button {
                            Task {
                                if client.lovedState(for: track) == nil {
                                    await client.refreshLovedState(for: track)
                                }
                                guard let current = client.lovedState(for: track) else { return }
                                await client.love(track, loved: !current)
                            }
                        } label: {
                            Image(systemName: loved ? "heart.fill" : "heart")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(loved ? Color.pink : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!client.canScrobble || client.loveRequests.contains([track.artist, track.title]))
                        .help(loved ? "Unlove on last.fm" : "Love on last.fm")
                        .accessibilityLabel(loved ? "Unlove on last.fm" : "Love on last.fm")
                    }
                    nowPlayingMetadata(track)
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: progress(track))
                        .accessibilityLabel("Scrobble progress")
                    listeningSummary(artistDetailsTrack(track))
                        .font(.callout).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let details {
                        linkChips(details.trackTags)
                    }
                    if !listener.isPlaying { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Nothing playing").font(.title2.bold())
                    Text("Play something in an enabled music app.").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        if let track = listener.track, let details {
            aboutArtist(artistDetailsTrack(track).artist, details: details.artist)
        }
        }.padding(.top, 16)
    }

    private func artistDetailsTrack(_ track: PlayingTrack) -> PlayingTrack {
        let metadata = LastFMClient.metadata(
            for: track,
            removeAlbumTypeSuffix: false,
            usePrimaryArtist: usePrimaryArtist,
            preservedArtistNames: preservedArtistNames
        )
        return PlayingTrack(title: track.title, artist: metadata["artist"] ?? track.artist,
                            album: track.album, duration: track.duration)
    }

    private func nowPlayingMetadata(_ track: PlayingTrack) -> Text {
        let metadata = LastFMClient.metadata(
            for: track,
            removeAlbumTypeSuffix: removeAlbumTypeSuffix,
            removeAppleMusicEdition: removeAppleMusicEdition,
            usePrimaryArtist: usePrimaryArtist,
            preservedArtistNames: preservedArtistNames,
            removeFeaturedArtists: removeFeaturedArtists
        )
        let titleNote = metadata["track"].flatMap { $0 == track.title ? nil : "\nScrobbling the title as \($0)" } ?? ""
        let artistNote = metadata["artist"].flatMap { $0 == track.artist ? nil : " (scrobbling as \($0))" } ?? ""
        let albumNote = metadata["album"].flatMap { $0 == track.album ? nil : " (scrobbling as \($0))" } ?? ""
        return linkedName(track.artist, url: track.artistURL) + Text(artistNote)
            + Text(track.album.isEmpty ? "" : " - ")
            + linkedName(track.album, url: track.albumURL).italic() + Text(albumNote) + Text(titleNote)
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
        return Text("You've scrobbled ") + linkedName(track.artist, url: track.artistURL).bold() + Text(" \(artistCount) times and ") + linkedName(track.title, url: track.trackURL).bold() + Text(" \(trackCount) times.")
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
                        if let url = details.url { Link("Read more on last.fm", destination: url).font(.caption) }
                    } else {
                        ArtistPortrait(name: name, size: 72)
                        Text("No biography available.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let plays = details.totalPlays {
                        if let url = details.url {
                            Link("\(plays.formatted()) total plays on last.fm", destination: url).font(.caption)
                        } else {
                            Text("\(plays.formatted()) total plays on last.fm").font(.caption)
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
                                RemoteAlbumArtwork(url: item.imageURL, alternatives: item.imageAlternatives) {
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
                                profileImage(item.imageURL, size: 32, alternatives: item.imageAlternatives)
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
            if listener.isPlaying, let track = listener.track {
                nowPlayingCard(title: track.title, artist: track.artist, url: track.trackURL,
                               coverURL: details?.coverURL, alternatives: details?.coverAlternatives ?? [])
            } else if let remote = remoteNowPlaying {
                nowPlayingCard(title: remote.title, artist: remote.artist, url: remote.destination,
                               coverURL: remote.coverURL, alternatives: remote.coverAlternatives,
                               note: "Playing on another device, according to last.fm")
            }
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
                        RemoteAlbumArtwork(url: row.coverURL, alternatives: row.coverAlternatives) {
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
                    .help("Open \(row.title) on last.fm")
                    Divider()
                }
                if !recent.isEmpty { Text("Latest 50 scrobbles").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func nowPlayingCard(title: String, artist: String, url: URL, coverURL: URL?, alternatives: [URL], note: String? = nil) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                RemoteAlbumArtwork(url: coverURL, alternatives: alternatives) {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("Now playing")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Open \(title) on last.fm")
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
            Text("Recent listening · refreshes hourly while scrap is running")
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
                            if friend.isNowPlaying {
                                Label("Now playing", systemImage: "waveform").font(.caption).foregroundStyle(Color.accentColor)
                            } else if let playedAt = friend.playedAt {
                                Text(playedAt, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(friend.name)’s last.fm profile")
                Divider()
            }
            if let updated = client.friendsUpdatedAt {
                if client.friends.isEmpty { Text("No friends returned by last.fm.").foregroundStyle(.secondary) }
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).italic().foregroundStyle(.secondary)
            }
        }
    }

    private var shownPeriod: ReportPeriod { reportPeriod ?? .latest(reportKind) }
    private var reportTaskID: String { "\(shownPeriod.kind.rawValue)-\(Int(shownPeriod.interval.start.timeIntervalSince1970))" }
    /// last.fm launched in 2002; used until the account's sign-up date is known.
    private var earliestReportDate: Date { accountStart ?? Date(timeIntervalSince1970: 1_009_843_200) }

    private func loadReport() async {
        let period = shownPeriod
        let username = client.username ?? ""
        let forced = reportRefresh != refreshID
        if reportUser != username || forced {
            sessionReports = [:]
            reportUser = username
            reportRefresh = refreshID
        }
        pageError = nil
        if let cached = sessionReports[period] { report = cached; return }
        // Recent weeks are saved on this Mac; a finished one doesn't need rebuilding.
        report = forced ? nil : ReportStore.load(period, username: username)
        if let report, report.isFinal { sessionReports[period] = report; return }
        isLoading = true
        reportProgress = nil
        if accountStart == nil { accountStart = try? await client.profile()?.registered }
        do {
            let result = try await client.listeningReport(for: period) { done, total in
                reportProgress = (done, total)
            }
            guard !Task.isCancelled else { return }
            report = result
            sessionReports[period] = result
            ReportStore.save(result, username: username)
        } catch {
            guard !Task.isCancelled else { return }
            pageError = "Couldn’t build your report. \(error.localizedDescription)"
        }
        isLoading = false
        reportProgress = nil
    }

    private func showPeriod(_ period: ReportPeriod) {
        reportPeriod = period == .latest(period.kind) ? nil : period
    }

    private var reportsPage: some View {
        let period = shownPeriod
        let latest = ReportPeriod.latest(reportKind)
        let noun = reportKind.noun
        return VStack(alignment: .leading, spacing: 16) {
            pageHeader("Reports")
            Picker("Report", selection: $reportKind) {
                ForEach(ReportKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: reportKind) { _, _ in reportPeriod = nil }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button { showPeriod(period.previous) } label: { Image(systemName: "chevron.left") }
                        .disabled(period.previous.interval.end <= earliestReportDate)
                        .help("Previous \(noun)")
                    Button { showPeriodPicker = true } label: {
                        HStack(spacing: 6) {
                            Text(period.title).font(.headline)
                            Image(systemName: "calendar").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose a \(noun)")
                    .popover(isPresented: $showPeriodPicker, arrowEdge: .bottom) {
                        ReportPeriodPicker(kind: reportKind, earliest: earliestReportDate, selected: period) { picked in
                            showPeriod(picked)
                            showPeriodPicker = false
                        }
                    }
                    Button { showPeriod(period.next) } label: { Image(systemName: "chevron.right") }
                        .disabled(period == latest)
                        .help("Next \(noun)")
                    Spacer()
                    if period != latest { Button("Latest") { reportPeriod = nil }.controlSize(.small) }
                }
                .buttonStyle(.borderless)
                if period == latest {
                    Text("Next \(reportKind == .week ? "" : reportKind == .month ? "monthly " : "yearly ")report \(latest.next.releaseDate.formatted(.dateTime.weekday(.wide).month().day()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(reportProgress.map { $0.total > 1 ? "Building your report… \($0.done) of \($0.total) pages" : "Building your report…" } ?? "Building your report…")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let pageError { Text(pageError).foregroundStyle(.red) }
            if let report, report.period == period { reportContent(report) }
        }
    }

    @ViewBuilder private func reportContent(_ report: ListeningReport) -> some View {
        let noun = report.period.kind.noun
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(report.scrobbles.formatted()).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
            Text("scrobbles").foregroundStyle(.secondary)
            Spacer()
            if report.previousScrobbles > 0 {
                let change = Double(report.scrobbles - report.previousScrobbles) / Double(report.previousScrobbles)
                Label(change.formatted(.percent.precision(.fractionLength(0))), systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.headline).foregroundStyle(change >= 0 ? .green : .red)
            }
        }
        Text("Previous \(noun): \(report.previousScrobbles.formatted())").font(.caption).foregroundStyle(.secondary)
        Text("Top of the \(noun)").font(.subheadline.bold()).padding(.top, 4)
        if let artist = report.topArtist { reportRow(artist, subtitle: "Top artist", artist: true) }
        if let album = report.topAlbum { reportRow(album, subtitle: "Top album · \(album.artist)", symbol: "opticaldisc") }
        if let track = report.topTrack { reportRow(track, subtitle: "Top track · \(track.artist)", symbol: "music.note") }
        if report.topArtist == nil { Text("No scrobbles this \(noun).").font(.caption).foregroundStyle(.secondary) }
        if report.scrobbles > 0 {
            if report.period.kind == .year, !report.monthly.isEmpty {
                Text("Scrobbles by month").font(.subheadline.bold()).padding(.top, 4)
                MonthlyScrobblesChart(monthly: report.monthly)
            }
            if let month = report.busiestMonth {
                highlightSection("Month you scrobbled the most", title: month.interval.start.formatted(.dateTime.month(.wide)), highlight: month)
            }
            if let day = report.busiestDay {
                highlightSection("Day you scrobbled the most", title: day.interval.start.formatted(.dateTime.weekday(.wide).month().day()), highlight: day)
            }
            if let peak = report.peakHour {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Listening clock").font(.subheadline.bold())
                    Text("You listened the most around \(ListeningClockChart.hourLabel(peak)), with \(report.hourly[peak].formatted()) scrobbles in that hour.")
                        .font(.caption).foregroundStyle(.secondary)
                    ListeningClockChart(hourly: report.hourly)
                }
                .padding(.top, 4)
            }
            if !report.topTags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top tags").font(.subheadline.bold())
                    TopTagsList(tags: report.topTags)
                    Text("Based on the tags of your top artists, weighted by plays.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        discoverySection("New artists", items: report.newArtists, noun: noun, artists: true)
        discoverySection("New albums", items: report.newAlbums, noun: noun, symbol: "opticaldisc")
        discoverySection("New tracks", items: report.newTracks, noun: noun, symbol: "music.note")
        Text("Checks your \(ListeningReport.discoveryCheckLimit) most-played artists, albums and tracks of the \(noun).")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func highlightSection(_ heading: String, title: String, highlight: ListeningReport.Highlight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).font(.subheadline.bold())
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("\(highlight.scrobbles.formatted()) scrobbles").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            if let artist = highlight.topArtist { reportRow(artist, subtitle: "Top artist", artist: true) }
            if let track = highlight.topTrack { reportRow(track, subtitle: "Top track · \(track.artist)", symbol: "music.note") }
            if let album = highlight.topAlbum { reportRow(album, subtitle: "Top album · \(album.artist)", symbol: "opticaldisc") }
        }
        .padding(.top, 4)
    }

    private func discoverySection(_ title: String, items: [ListeningReport.Item], noun: String, artists: Bool = false, symbol: String = "music.note") -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(items.isEmpty ? title : "\(title) (\(items.count))").font(.subheadline.bold()).padding(.top, 4)
            if items.isEmpty { Text("Nothing new this \(noun).").font(.caption).foregroundStyle(.secondary) }
            ForEach(items) { item in
                reportRow(item, subtitle: artists ? nil : item.artist, artist: artists, symbol: symbol)
            }
        }
    }

    private func reportRow(_ item: ListeningReport.Item, subtitle: String?, artist: Bool = false, symbol: String = "music.note") -> some View {
        Link(destination: item.url) {
            HStack(spacing: 10) {
                if artist { ArtistPortrait(name: item.name, size: 36) }
                else { profileImage(item.imageURL, size: 36, symbol: symbol) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.callout).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(item.count.formatted()) play\(item.count == 1 ? "" : "s")").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(item.name) on last.fm")
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
                        if let url = profile.url { Link("View on last.fm", destination: url).font(.caption) }
                        Button("Reconnect last.fm") { Task { await client.beginAuth() } }.disabled(client.isBusy)
                        if client.pendingToken != nil {
                            Button("I've approved it") { Task { await client.completeAuth() } }.disabled(client.isBusy)
                            Text(client.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Most played").font(.headline)
                    Spacer()
                    Picker("Period", selection: $chartPeriod) {
                        ForEach(ChartPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(.top, 8)
                chartSection(.artists, entries: topArtists)
                chartSection(.albums, entries: topAlbums)
                chartSection(.tracks, entries: topSongs)
            }

        }
    }

    private func profileImage(_ url: URL?, size: CGFloat, symbol: String = "opticaldisc", alternatives: [URL] = []) -> some View {
        RemoteAlbumArtwork(url: url, alternatives: alternatives) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                .overlay(Image(systemName: symbol).foregroundStyle(.secondary))
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func chartSection(_ kind: ChartKind, entries: [ProfileChartEntry]) -> some View {
        let artists = kind == .artists
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title).font(.subheadline.bold())
                Spacer()
                if !entries.isEmpty {
                    Button("See more") { ChartGalleryController.shared.show(kind, period: chartPeriod, client: client) }
                        .buttonStyle(.link).font(.caption)
                        .help("Show your top 50 \(kind.rawValue) for \(chartPeriod.title.lowercased())")
                }
            }
            if entries.isEmpty && !isLoading { Text("Nothing scrobbled in this period.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                Link(destination: item.link.url) {
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.caption.bold()).monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
                        if artists { ArtistPortrait(name: item.link.name, size: 36) }
                        else { profileImage(item.link.imageURL, size: 36, alternatives: item.link.imageAlternatives) }
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
                Text("Add your last.fm app credentials to .env, then rebuild scrap.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(client.sessionKey == nil ? "Connect last.fm" : "Reconnect last.fm") { Task { await client.beginAuth() } }
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
