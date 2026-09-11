import AppKit
import Combine

@MainActor
final class NowPlayingListener: ObservableObject {
    @Published private(set) var track: PlayingTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    var onUpdate: ((PlayingTrack?, Bool, Bool) -> Void)?
    private var timer: Timer?
    private var previousPosition: Double?
    private var previousID: String?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty == false else {
            publish(nil, playing: false)
            return
        }
        let source = """
        tell application "Music"
            if player state is stopped then return {"stopped"}
            return {player state as text, name of current track, artist of current track, album of current track, duration of current track, player position, persistent ID of current track}
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return }
        let result = script.executeAndReturnError(&error)
        if let error {
            errorMessage = (error[NSAppleScript.errorMessage] as? String) ?? "Allow Scrap to read Music in System Settings → Privacy & Security → Automation."
            publish(nil, playing: false)
            return
        }
        errorMessage = nil
        guard result.numberOfItems == 7,
              let title = result.atIndex(2)?.stringValue,
              let artist = result.atIndex(3)?.stringValue,
              !title.isEmpty, !artist.isEmpty else {
            publish(nil, playing: false)
            return
        }
        let duration = result.atIndex(5)?.doubleValue ?? 0
        let position = result.atIndex(6)?.doubleValue ?? 0
        let id = result.atIndex(7)?.stringValue
        
        let repeated = id == previousID && duration > 0 && (previousPosition ?? 0) >= duration - 3 && position < 3
        let changedID = previousID != nil && id != previousID
        previousID = id
        previousPosition = position
        publish(PlayingTrack(title: title, artist: artist, album: result.atIndex(4)?.stringValue ?? "", duration: duration > 0 ? duration : nil), playing: result.atIndex(1)?.stringValue == "playing", restarted: repeated || changedID)
    }

    private func publish(_ track: PlayingTrack?, playing: Bool, restarted: Bool = false) {
        self.track = track
        isPlaying = playing
        if track == nil { previousPosition = nil; previousID = nil }
        onUpdate?(track, playing, restarted)
    }
}
