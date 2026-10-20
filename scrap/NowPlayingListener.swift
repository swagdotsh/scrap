import Foundation
import MediaPlayer
import UIKit
import Combine

@MainActor
final class NowPlayingListener: ObservableObject {
    @Published private(set) var track: PlayingTrack?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isPlaying = false
    private(set) var storeID: String?

    var onTrackChange: (() -> Void)?
    var onNowPlaying: ((PlayingTrack) -> Void)?
    var onRefresh: ((PlayingTrack?, MPMediaEntityPersistentID?, TimeInterval, Bool) -> Void)?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observers: [NSObjectProtocol] = []
    private var sentNowPlaying: PlayingTrack?
    private var timer: Timer?

    func start() {
        guard observers.isEmpty else { refresh(); return }
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let item = player.nowPlayingItem
        let newTrack = item.flatMap { item -> PlayingTrack? in
            guard let title = item.title, let artist = item.artist else { return nil }
            return PlayingTrack(title: title, artist: artist, album: item.albumTitle ?? "",
                                duration: item.playbackDuration > 0 ? item.playbackDuration : nil)
        }
        let changed = newTrack != track
        track = newTrack
        storeID = item?.playbackStoreID
        isPlaying = player.playbackState == .playing
        if changed {
            artwork = item?.artwork?.image(at: CGSize(width: 600, height: 600))
            onTrackChange?()
        }
        if let newTrack, isPlaying, sentNowPlaying != newTrack {
            sentNowPlaying = newTrack
            onNowPlaying?(newTrack)
        }
        onRefresh?(newTrack, item?.persistentID, player.currentPlaybackTime, isPlaying)
    }
}
