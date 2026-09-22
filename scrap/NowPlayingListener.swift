import AppKit
import ApplicationServices
import Combine

enum PlaybackService: String, CaseIterable {
    case appleMusic
    case spotify
    case untitled

    var bundleID: String {
        switch self {
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .untitled: "com.untitledinbrackets.untitled-macos"
        }
    }

    var name: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .untitled: "[untitled]"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .appleMusic: UserDefaults.standard.object(forKey: "scrobbleAppleMusic") as? Bool ?? true
        case .spotify: UserDefaults.standard.bool(forKey: "scrobbleSpotify")
        case .untitled: UserDefaults.standard.bool(forKey: "scrobbleUntitled")
        }
    }
}

@MainActor
final class NowPlayingListener: ObservableObject {
    @Published private(set) var track: PlayingTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var source: PlaybackService?
    @Published private(set) var errorMessage: String?
    var onUpdate: ((PlayingTrack?, Bool, Bool) -> Void)?
    private var timer: Timer?
    private var previousPosition: Double?
    private var previousID: String?

    private struct Snapshot {
        let source: PlaybackService
        let track: PlayingTrack
        let isPlaying: Bool
        let position: Double
        let id: String?
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        var snapshots: [Snapshot] = []
        var firstError: String?
        for service in PlaybackService.allCases where service.isEnabled {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: service.bundleID).isEmpty else { continue }
            let (snapshot, error) = read(service)
            if let snapshot { snapshots.append(snapshot) }
            if firstError == nil { firstError = error }
        }

        let playing = snapshots.filter(\.isPlaying)
        let selected: Snapshot?
        if playing.count > 1 {
            let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            selected = playing.first(where: { $0.source.bundleID == frontmostID })
                ?? playing.first(where: { $0.source == source })
                ?? playing.first
        } else {
            selected = playing.first
                ?? snapshots.first(where: { $0.source == source })
                ?? snapshots.first
        }

        guard let selected else {
            errorMessage = firstError
            publish(nil, source: nil, playing: false)
            return
        }
        errorMessage = nil
        let duration = selected.track.duration ?? 0
        let repeated = selected.source == source && selected.id == previousID && duration > 0
            && (previousPosition ?? 0) >= duration - 3 && selected.position < 3
        let changed = selected.source != source || (previousID != nil && selected.id != previousID)
        previousID = selected.id
        previousPosition = selected.position
        publish(selected.track, source: selected.source, playing: selected.isPlaying, restarted: repeated || changed)
    }

    private func read(_ service: PlaybackService) -> (Snapshot?, String?) {
        if service == .untitled {
            if !AXIsProcessTrusted() {
                return (nil, "Add & enable scrap in System Settings -> Privacy & Security -> Device Control and Data Access to scrobble [untitled].")
            }
            guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: service.bundleID).first,
                  let playback = UntitledPlaybackReader.read(pid: application.processIdentifier) else { return (nil, nil) }
            return (Snapshot(source: service, track: playback.track, isPlaying: playback.isPlaying, position: playback.position, id: playback.id), nil)
        }
        let scriptSource: String
        switch service {
        case .appleMusic:
            scriptSource = """
            tell application id "com.apple.Music"
                if player state is stopped then return {"stopped"}
                return {player state as text, name of current track, artist of current track, album of current track, duration of current track, player position, persistent ID of current track}
            end tell
            """
        case .spotify:
            scriptSource = """
            tell application id "com.spotify.client"
                if player state is stopped then return {"stopped"}
                return {player state as text, name of current track, artist of current track, album of current track, duration of current track, player position, id of current track}
            end tell
            """
        case .untitled:
            return (nil, nil)
        }
        var scriptError: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else { return (nil, nil) }
        let result = script.executeAndReturnError(&scriptError)
        if let scriptError {
            let message = (scriptError[NSAppleScript.errorMessage] as? String)
                ?? "Allow scrap to read \(service.name) in System Settings -> Privacy & Security -> Automation."
            return (nil, message)
        }
        guard result.numberOfItems == 7,
              let title = result.atIndex(2)?.stringValue,
              let artist = result.atIndex(3)?.stringValue,
              !title.isEmpty, !artist.isEmpty else { return (nil, nil) }
        let id = result.atIndex(7)?.stringValue
        if service == .spotify, let id, !id.hasPrefix("spotify:track:") && !id.hasPrefix("spotify:local:") {
            return (nil, nil)
        }
        let rawDuration = result.atIndex(5)?.doubleValue ?? 0
        let track = PlayingTrack(title: title, artist: artist, album: result.atIndex(4)?.stringValue ?? "", duration: Self.duration(rawDuration, from: service))
        return (Snapshot(source: service, track: track, isPlaying: result.atIndex(1)?.stringValue == "playing", position: result.atIndex(6)?.doubleValue ?? 0, id: id), nil)
    }

    static func duration(_ raw: Double, from service: PlaybackService) -> TimeInterval? {
        guard raw > 0 else { return nil }
        return service == .spotify ? raw / 1000 : raw
    }

    private func publish(_ track: PlayingTrack?, source: PlaybackService?, playing: Bool, restarted: Bool = false) {
        self.track = track
        self.source = source
        isPlaying = playing
        if track == nil { previousPosition = nil; previousID = nil }
        onUpdate?(track, playing, restarted)
    }
}
