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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let lastFM = LastFMClient()
        let scrobbler = PlayCountScrobbler(lastFM: lastFM)
        let nowPlaying = NowPlayingListener()
        nowPlaying.onNowPlaying = { [weak nowPlaying] track in
            lastFM.updateNowPlaying(track)
            let storeID = nowPlaying?.storeID
            Task { if await AppleMusicFavorites.isFavorited(storeID: storeID) { lastFM.loveAppleMusicFavorite(track) } }
        }
        nowPlaying.onTrackChange = { Task { await scrobbler.sync() } }
        _lastFM = StateObject(wrappedValue: lastFM)
        _scrobbler = StateObject(wrappedValue: scrobbler)
        _nowPlaying = StateObject(wrappedValue: nowPlaying)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(lastFM)
                .environmentObject(scrobbler)
                .environmentObject(nowPlaying)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard scrobbler.authorization == .authorized else { break }
                nowPlaying.start()
                Task {
                    await scrobbler.sync()
                    await lastFM.retryPending()
                }
            case .background:
                Self.scheduleRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) { [scrobbler, lastFM] in
            Self.scheduleRefresh()
            await scrobbler.sync()
            await lastFM.retryPending()
        }
    }

    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        BGTaskScheduler.shared.submitTaskRequest(request) { _ in }
    }
}
