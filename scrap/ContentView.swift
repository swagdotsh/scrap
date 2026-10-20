//
//  ContentView.swift
//  scrap
//
//  Created by don on 20.10.2026.
//

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
        .sheet(isPresented: $showingProfile) {
            ProfileView(profile: profile)
        }
        .sheet(isPresented: $showingScan) {
            ScanView()
        }
        .task(id: lastFM.username) {
            profile = try? await lastFM.profile()
        }
        .task {
            await notifier.requestAuthorization()
            await notifier.refresh()
        }
    }

    private func screen<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Scan…") { showingScan = true }
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
        guard let url = await lastFM.beginAuth() else { return }
        let callback = try? await webAuthenticationSession.authenticate(using: url, callbackURLScheme: LastFMClient.authCallbackScheme)
        await lastFM.completeAuth(callback: callback)
        if lastFM.canScrobble, scrobbler.authorization == .notDetermined { await scrobbler.requestAccess() }
        if scrobbler.authorization == .authorized { nowPlaying.start() }
    }
}

// MARK: - Shared pieces

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
