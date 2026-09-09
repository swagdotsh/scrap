import Foundation
import Combine

@MainActor
final class ScrobbleEngine: ObservableObject {
    @Published private(set) var currentlyTracking: PlayingTrack?
    @Published private(set) var accumulatedPlayTime: TimeInterval = 0
    @Published private(set) var hasScrobbledCurrent = false
    func suspendTiming() {
        wasPlaying = false
        lastUpdate = nil
    }

    private var lastUpdate: Date?
    private var wasPlaying = false
    private var startedAt: Date?
    private var sentNowPlaying = false
    var onNowPlaying: ((PlayingTrack) -> Void)?
    var onScrobble: ((PlayingTrack, Date) -> Void)?

    func update(track: PlayingTrack?, isPlaying: Bool, restarted: Bool = false, now: Date = Date()) {
        // Count only observed playback intervals. Long gaps (sleep or a blocked app) don't count.
        if wasPlaying, let lastUpdate {
            let elapsed = now.timeIntervalSince(lastUpdate)
            if elapsed >= 0 && elapsed <= 3 { accumulatedPlayTime += elapsed }
            checkThreshold()
        }
        if track != currentlyTracking || restarted {
            currentlyTracking = track
            accumulatedPlayTime = 0
            hasScrobbledCurrent = false
            startedAt = nil
            sentNowPlaying = false
        }
        if let track, isPlaying {
            if startedAt == nil { startedAt = now }
            if !sentNowPlaying {
                sentNowPlaying = true
                onNowPlaying?(track)
            }
        }
        wasPlaying = isPlaying && track != nil
        lastUpdate = now
    }

    private func checkThreshold() {
        guard let track = currentlyTracking, let startedAt, !hasScrobbledCurrent,
              let duration = track.duration, duration > 30 else { return }
        if accumulatedPlayTime >= min(240, duration / 2) {
            hasScrobbledCurrent = true
            onScrobble?(track, startedAt)
        }
    }
}
