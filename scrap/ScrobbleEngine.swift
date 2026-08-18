import Foundation

@MainActor
final class ScrobbleEngine: ObservableObject {
    @Published private(set) var currentlyTracking: PlayingTrack?
    @Published private(set) var accumulatedPlayTime: TimeInterval = 0
    @Published private(set) var hasScrobbledCurrent = false

    private var timer: Timer?
    private var lastTickDate: Date?

    // Hooks — wire these to your Last.fm API calls
    var onNowPlaying: ((PlayingTrack) -> Void)?
    var onScrobble: ((PlayingTrack) -> Void)?

    func update(track: PlayingTrack?, isPlaying: Bool) {
        guard let track else {
            stopTracking()
            return
        }

        if track != currentlyTracking {
            // New track — reset state, fire now-playing
            startTracking(track)
        }

        isPlaying ? resumeTimer() : pauseTimer()
    }

    private func startTracking(_ track: PlayingTrack) {
        currentlyTracking = track
        accumulatedPlayTime = 0
        hasScrobbledCurrent = false
        pauseTimer()

        // Last.fm rule: skip anything 30s or shorter entirely
        if let duration = track.duration, duration <= 30 {
            currentlyTracking = nil
            return
        }

        onNowPlaying?(track)
    }

    private func stopTracking() {
        pauseTimer()
        currentlyTracking = nil
        accumulatedPlayTime = 0
        hasScrobbledCurrent = false
    }

    private func resumeTimer() {
        guard timer == nil else { return }
        lastTickDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func pauseTimer() {
        timer?.invalidate()
        timer = nil
        lastTickDate = nil
    }

    private func tick() {
        guard let last = lastTickDate else { return }
        let now = Date()
        accumulatedPlayTime += now.timeIntervalSince(last)
        lastTickDate = now

        checkScrobbleThreshold()
    }

    private func checkScrobbleThreshold() {
        guard let track = currentlyTracking, !hasScrobbledCurrent else { return }

        let fourMinutes: TimeInterval = 240
        let halfDuration = (track.duration ?? .infinity) / 2
        let threshold = min(fourMinutes, halfDuration)

        if accumulatedPlayTime >= threshold {
            hasScrobbledCurrent = true
            onScrobble?(track)
        }
    }
}