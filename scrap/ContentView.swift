import SwiftUI
import AuthenticationServices
import MediaPlayer

struct ContentView: View {
    @EnvironmentObject private var lastFM: LastFMClient

    var body: some View {
        if lastFM.canScrobble {
            MainTabs()
        } else {
            ConnectView()
        }
    }
}

private struct MainTabs: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var notifier: Notifier
    @AppStorage("selectedTab") private var selectedTab = "nowPlaying"
    @State private var profile: ListenerProfile?
    @State private var showingProfile = false
    @State private var showingScan = false
    @State private var missedPlays: [MissedPlay] = []
    @State private var scanBanner: ScanBanner?
    @State private var scanTask: Task<Void, Never>?
    @EnvironmentObject private var scrobbler: PlayCountScrobbler

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Now Playing", systemImage: "play.circle.fill", value: "nowPlaying") {
                screen("Now Playing") { NowPlayingView() }
            }
            Tab("Reports", systemImage: "chart.pie.fill", value: "reports") {
                screen("Reports") { ReportsView() }
            }
            Tab("Scrobbles", systemImage: "clock.arrow.circlepath", value: "scrobbles") {
                screen("Scrobbles") { ScrobblesView() }
            }
            Tab("Friends", systemImage: "person.2.fill", value: "friends") {
                screen("Friends") { FriendsView() }
            }
        }
        .minimizesTabBarOnScroll()
        .musicPages()
        .sheet(isPresented: $showingProfile) {
            ProfileView(profile: profile)
        }
        .sheet(isPresented: $showingScan) {
            ScanView(plays: missedPlays)
        }
        .overlay(alignment: .top) {
            if let scanBanner {
                ScanBannerView(banner: scanBanner)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { if scanBanner != .checking { withAnimation { self.scanBanner = nil } } }
            }
        }
        .task(id: lastFM.username) {
            profile = try? await lastFM.profile()
        }
        .task {
            await notifier.requestAuthorization()
            await notifier.refresh()
        }
    }

    private func startScan() {
        scanTask?.cancel()
        scanTask = Task {
            if scrobbler.authorization == .notDetermined { await scrobbler.requestAccess() }
            guard scrobbler.authorization == .authorized else { return await showScanResult(.noAccess) }
            withAnimation { scanBanner = .checking }
            do {
                let plays = try await MissedPlayScanner.check(lastFM: lastFM, scrobbler: scrobbler)
                guard !Task.isCancelled else { return }
                if plays.isEmpty { return await showScanResult(.nothingMissed) }
                withAnimation { scanBanner = nil }
                missedPlays = plays
                showingScan = true
            } catch {
                guard !Task.isCancelled else { return }
                await showScanResult(.failed)
            }
        }
    }

    private func showScanResult(_ banner: ScanBanner) async {
        withAnimation { scanBanner = banner }
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled, scanBanner == banner else { return }
        withAnimation { scanBanner = nil }
    }

    private func screen<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Scan…") { startScan() }
                            .disabled(scanBanner == .checking)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingProfile = true } label: {
                            Avatar(url: profile?.avatarURL, size: 34)
                        }
                        .accessibilityLabel("Profile and settings")
                    }
                    .withoutSharedBackground()
                }
        }
    }
}

private struct ConnectView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var scrobbler: PlayCountScrobbler
    @EnvironmentObject private var nowPlaying: NowPlayingListener
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 56)).foregroundStyle(.tint)
            Text("scrap").font(.largeTitle.bold())
            Text("Connect your last.fm account to scrobble what you play in Apple Music.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            Text(lastFM.status).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { Task { await connect() } } label: {
                Text("Connect last.fm").frame(maxWidth: .infinity)
            }
            .prominentButtonStyle()
            .controlSize(.large)
            .disabled(!lastFM.isConfigured || lastFM.isBusy)
        }
        .padding(24)
    }

    private func connect() async {
        await lastFM.signIn(with: webAuthenticationSession)
        if lastFM.canScrobble, scrobbler.authorization == .notDetermined { await scrobbler.requestAccess() }
        if scrobbler.authorization == .authorized { nowPlaying.start() }
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 34

    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct RemoteArtwork: View {
    let url: URL?
    var symbol = "music.note"
    var size: CGFloat? = 44

    var body: some View {
        CoverImage(url: url) {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size.map { $0 / 6 } ?? 12))
    }
}

struct LinkRow<Artwork: View>: View {
    let url: URL
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                artwork()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

struct TagChips: View {
    let tags: [MusicLink]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    Link(tag.name, destination: tag.url)
                        .font(.footnote).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
