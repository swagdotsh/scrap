import Foundation

@MainActor
final class NowPlayingListener: ObservableObject {
    @Published var trackTitle: String = "—"
    @Published var artist: String = "—"
    @Published var album: String = "—"
    @Published var playerState: String = "Stopped"

    init() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleMusicNotification(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
    }

    @objc private func handleMusicNotification(_ note: Notification) {
        guard let info = note.userInfo else { return }

        // Keys are documented informally, but consistently: Name, Artist, Album, Player State
        let name = info["Name"] as? String ?? "Unknown"
        let artistName = info["Artist"] as? String ?? "Unknown"
        let albumName = info["Album"] as? String ?? "Unknown"
        let state = info["Player State"] as? String ?? "Unknown"

        Task { @MainActor in
            self.trackTitle = name
            self.artist = artistName
            self.album = albumName
            self.playerState = state
            print("🎵 [\(state)] \(name) — \(artistName) (\(albumName))")
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}