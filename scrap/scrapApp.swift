//
//  scrapApp.swift
//  scrap
//
//  Created by don on 20.10.2026.
//

import SwiftUI
import BackgroundTasks
import MediaPlayer

@main
struct scrapApp: App {
    nonisolated static let refreshTaskID = "com.swagrelated.scrap.sync"

    @StateObject private var lastFM: LastFMClient
    @StateObject private var scrobbler: PlayCountScrobbler
    @StateObject private var nowPlaying: NowPlayingListener
    @StateObject private var notifier: Notifier
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.register(defaults: ["backgroundWork": true])
        let lastFM = LastFMClient()
        let scrobbler = PlayCountScrobbler(lastFM: lastFM)
        let nowPlaying = NowPlayingListener()
        let nonLibrary = NonLibraryScrobbler(lastFM: lastFM)
        let notifier = Notifier(lastFM: lastFM)
        nowPlaying.onNowPlaying = { [weak nowPlaying] track in
            lastFM.updateNowPlaying(track)
            let storeID = nowPlaying?.storeID
            Task { if await AppleMusicFavorites.isFavorited(storeID: storeID) { lastFM.loveAppleMusicFavorite(track) } }
        }
        nowPlaying.onTrackChange = { Task { await scrobbler.sync() } }
        nowPlaying.onRefresh = { track, persistentID, position, isPlaying in
            nonLibrary.observe(track: track, persistentID: persistentID, position: position, isPlaying: isPlaying)
        }
        lastFM.onScrobbled = { notifier.didScrobble($0) }
        _lastFM = StateObject(wrappedValue: lastFM)
        _scrobbler = StateObject(wrappedValue: scrobbler)
        _nowPlaying = StateObject(wrappedValue: nowPlaying)
        _notifier = StateObject(wrappedValue: notifier)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(lastFM)
                .environmentObject(scrobbler)
                .environmentObject(nowPlaying)
                .environmentObject(notifier)
                .onChange(of: lastFM.username, initial: true) { _, username in WidgetSync.update(username: username) }
                .onChange(of: lastFM.pendingCount) { old, new in if new < old { WidgetSync.reload() } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Self.syncSystemSettings(lastFM: lastFM)
                Task { await notifier.refresh() }
                guard scrobbler.authorization == .authorized else { break }
                nowPlaying.start()
                Task {
                    await scrobbler.sync()
                    await lastFM.retryPending()
                }
            case .background:
                Self.scheduleRefresh()
                WidgetSync.reload()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) { [scrobbler, lastFM, nowPlaying, notifier] in
            Self.scheduleRefresh()
            guard UserDefaults.standard.bool(forKey: "backgroundWork") else { return }
            await nowPlaying.refresh()
            await scrobbler.sync()
            await lastFM.retryPending()
            await notifier.refresh()
            await WidgetSync.reload()
        }
    }

    static func syncSystemSettings(lastFM: LastFMClient) {
        let defaults = UserDefaults.standard
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        defaults.set("\(version) (\(build))", forKey: "appVersion")
        if defaults.bool(forKey: "signOutRequested") {
            defaults.set(false, forKey: "signOutRequested")
            lastFM.signOut()
        }
    }

    nonisolated static func scheduleRefresh() {
        guard UserDefaults.standard.bool(forKey: "backgroundWork") else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        if #available(iOS 27, *) {
            BGTaskScheduler.shared.submitTaskRequest(request) { _ in }
        } else {
            try? BGTaskScheduler.shared.submit(request)
        }
    }
}
