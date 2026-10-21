import Foundation
import MediaPlayer
import Combine

@MainActor
final class PlayCountScrobbler: ObservableObject {
    @Published private(set) var authorization = MPMediaLibrary.authorizationStatus()
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "lastPlayCountSync") as? Date
    @Published private(set) var isSyncing = false
    @Published private(set) var status = "Not synced yet."

    private let lastFM: LastFMClient
    private let snapshotURL = URL.applicationSupportDirectory.appending(path: "playCounts.json")

    private static let maximumAge: TimeInterval = 14 * 24 * 60 * 60
    private static let maximumPlaysPerSong = 10

    init(lastFM: LastFMClient) {
        self.lastFM = lastFM
    }

    func requestAccess() async {
        authorization = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        if authorization == .authorized { await sync() }
    }

    func sync() async {
        guard authorization == .authorized, lastFM.canScrobble, !lastFM.scrobblingPaused, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let songs = MPMediaQuery.songs().items ?? []
        let current = Dictionary(songs.map { ($0.persistentID, $0.playCount) }, uniquingKeysWith: max)
        guard let previous = loadSnapshot() else {
            saveSnapshot(current)
            status = "Tracking \(songs.count) songs. New plays will scrobble from now on."
            return
        }

        let now = Date()
        var plays: [(track: PlayingTrack, startedAt: Date)] = []
        var playedSongs: [(track: PlayingTrack, storeID: String)] = []
        for song in songs {
            guard let old = previous[song.persistentID], song.playCount > old,
                  let title = song.title, let artist = song.artist,
                  song.playbackDuration > 30, let lastPlayed = song.lastPlayedDate else { continue }
            let track = PlayingTrack(title: title, artist: artist, album: song.albumTitle ?? "", duration: song.playbackDuration)
            playedSongs.append((track, song.playbackStoreID))
            for index in 0..<min(song.playCount - old, Self.maximumPlaysPerSong) {
                let startedAt = lastPlayed.addingTimeInterval(-song.playbackDuration * Double(index + 1))
                if now.timeIntervalSince(startedAt) < Self.maximumAge { plays.append((track, startedAt)) }
            }
        }

        if let earliest = plays.map(\.startedAt).min() {
            do {
                plays = try await removingAlreadyScrobbled(plays, since: earliest)
            } catch {
                status = "Couldn't check recent scrobbles: \(error.localizedDescription) Will try again."
                return
            }
        }

        plays.sort { $0.startedAt < $1.startedAt }
        lastFM.scrobble(plays)
        if UserDefaults.standard.bool(forKey: "loveAppleMusicFavorites") {
            Task {
                for song in playedSongs where await AppleMusicFavorites.isFavorited(storeID: song.storeID) {
                    lastFM.loveAppleMusicFavorite(song.track)
                }
            }
        }
        saveSnapshot(current)
        lastSync = now
        UserDefaults.standard.set(now, forKey: "lastPlayCountSync")
        status = plays.isEmpty ? "No new plays." : "Found \(plays.count) new play\(plays.count == 1 ? "" : "s")."
    }

    private func removingAlreadyScrobbled(_ plays: [(track: PlayingTrack, startedAt: Date)], since earliest: Date) async throws
        -> [(track: PlayingTrack, startedAt: Date)] {
        let window: TimeInterval = 15 * 60
        let recent = try await lastFM.recentScrobbles(since: earliest.addingTimeInterval(-window))
        var unmatched = recent
        return plays.filter { play in
            let names = lastFM.scrobbledNames(for: play.track)
            guard let match = unmatched.firstIndex(where: {
                ($0.artist.caseInsensitiveCompare(play.track.artist) == .orderedSame || $0.artist.caseInsensitiveCompare(names.artist) == .orderedSame)
                    && ($0.title.caseInsensitiveCompare(play.track.title) == .orderedSame || $0.title.caseInsensitiveCompare(names.title) == .orderedSame)
                    && abs($0.date.timeIntervalSince(play.startedAt)) < window
            }) else { return true }
            unmatched.remove(at: match)
            return false
        }
    }

    private func loadSnapshot() -> [MPMediaEntityPersistentID: Int]? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode([MPMediaEntityPersistentID: Int].self, from: data)
    }

    private func saveSnapshot(_ counts: [MPMediaEntityPersistentID: Int]) {
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(counts).write(to: snapshotURL, options: .atomic)
    }
}
