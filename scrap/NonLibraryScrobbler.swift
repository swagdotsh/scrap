import Foundation
import MediaPlayer

@MainActor
final class NonLibraryScrobbler {
    private struct Observation {
        let track: PlayingTrack
        let startedAt: Date
        var furthest: TimeInterval
        var scrobbled = false
    }

    private let lastFM: LastFMClient
    private var current: Observation?
    private var libraryMembership: [MPMediaEntityPersistentID: Bool] = [:]

    init(lastFM: LastFMClient) {
        self.lastFM = lastFM
    }

    func observe(track: PlayingTrack?, persistentID: MPMediaEntityPersistentID?, position: TimeInterval, isPlaying: Bool, now: Date = .now) {
        guard UserDefaults.standard.bool(forKey: "nonLibraryScrobbling"),
              let track, let persistentID, !isInLibrary(persistentID) else {
            current = nil
            return
        }
        guard position.isFinite, position >= 0 else { return }
        if var observation = current, observation.track == track {
            let restarted = observation.scrobbled && position < 5 && observation.furthest > position + 30
            if restarted {
                current = Observation(track: track, startedAt: now, furthest: position)
            } else {
                observation.furthest = max(observation.furthest, position)
                current = observation
            }
        } else {
            guard isPlaying else { return }
            current = Observation(track: track, startedAt: now.addingTimeInterval(-position), furthest: position)
        }
        scrobbleIfReady()
    }

    private func scrobbleIfReady() {
        guard var observation = current, !observation.scrobbled,
              let duration = observation.track.duration, duration > 30,
              observation.furthest >= min(240, duration / 2) else { return }
        observation.scrobbled = true
        current = observation
        lastFM.scrobble(observation.track, startedAt: observation.startedAt)
    }

    private func isInLibrary(_ id: MPMediaEntityPersistentID) -> Bool {
        guard id != 0 else { return false }
        if let known = libraryMembership[id] { return known }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: id, forProperty: MPMediaItemPropertyPersistentID))
        let found = !(query.items ?? []).isEmpty
        libraryMembership[id] = found
        return found
    }
}
