import Foundation
import Testing
@testable import scrap

@MainActor
struct DiscordPresenceTests {
    private let track = PlayingTrack(title: "Wants and Needs", artist: "Drake", album: "Scary Hours 2", duration: 192)

    private func info(album: String? = nil, songLink: URL? = URL(string: "https://song.link/s/abc")) -> DiscordTrackInfo {
        let base = album.map { PlayingTrack(title: track.title, artist: track.artist, album: $0, duration: track.duration) } ?? track
        return DiscordTrackInfo(track: base, service: "Spotify", coverURL: URL(string: "https://lastfm.freetls.fastly.net/i/u/300x300/a.png"), songLinkURL: songLink)
    }

    @Test func framesRoundTripAndWaitForCompleteData() throws {
        let data = try #require(DiscordIPCConnection.encode(.frame, ["cmd": "SET_ACTIVITY", "nonce": "1"]))
        #expect(Array(data.prefix(4)) == [1, 0, 0, 0])
        #expect(Int(data[4]) | Int(data[5]) << 8 == data.count - 8)

        var buffer = data + data.prefix(5)
        let frames = DiscordIPCConnection.decodeFrames(&buffer)
        #expect(frames.count == 1)
        #expect(frames.first?.opcode == 1)
        #expect(frames.first?.payload["cmd"] as? String == "SET_ACTIVITY")
        #expect(buffer.count == 5)
        buffer.append(data.dropFirst(5))
        #expect(DiscordIPCConnection.decodeFrames(&buffer).count == 1)
        #expect(buffer.isEmpty)
    }

    @Test func templatesFillTokensAndHideLinesWithMissingValues() {
        #expect(DiscordActivity.format("by {artist}", info()) == "by Drake")
        #expect(DiscordActivity.format("{title} on {service}", info()) == "Wants and Needs on Spotify")
        #expect(DiscordActivity.format("on {album}", info(album: "")) == "")

        let activity = DiscordActivity.build(info: info(album: ""), settings: DiscordPresenceSettings(albumFormat: "on {album}"), isPlaying: true, startedAt: nil)
        #expect(activity?.albumText == nil)
        #expect(activity?.albumURL == nil)
    }

    @Test func activityPayloadUsesListeningTypeTimestampsAndButtons() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let activity = try #require(DiscordActivity.build(info: info(), settings: DiscordPresenceSettings(), isPlaying: true, startedAt: start))
        let payload = activity.payload
        #expect(payload["type"] as? Int == 2)
        #expect(payload["status_display_type"] as? Int == 1)
        #expect(payload["details"] as? String == "Wants and Needs")
        #expect(payload["state"] as? String == "Drake")
        let timestamps = try #require(payload["timestamps"] as? [String: Any])
        #expect(timestamps["start"] as? Int64 == 1_000_000)
        #expect(timestamps["end"] as? Int64 == 1_192_000)
        let assets = try #require(payload["assets"] as? [String: Any])
        #expect(assets["large_text"] as? String == "Scary Hours 2")
        let buttons = try #require(payload["buttons"] as? [[String: String]])
        #expect(buttons.map { $0["label"] } == ["Listen on song.link", "View on last.fm"])
        #expect(buttons.first?["url"] == "https://song.link/s/abc")
        #expect(activity.statusText(appName: "scrap") == "Drake")
    }

    @Test func pausedBehaviorAndOptionalPieces() {
        #expect(DiscordActivity.build(info: info(), settings: DiscordPresenceSettings(), isPlaying: false, startedAt: .now) == nil)

        var settings = DiscordPresenceSettings(showCover: false, paused: .keep)
        settings.statusSource = .details
        let paused = DiscordActivity.build(info: info(), settings: settings, isPlaying: false, startedAt: .now)
        #expect(paused?.start == nil)
        #expect(paused?.coverURL == nil)
        #expect(paused?.statusText(appName: "scrap") == "Wants and Needs")

        settings.detailsFormat = ""
        #expect(DiscordActivity.build(info: info(), settings: settings, isPlaying: false, startedAt: nil)?.statusSource == .state)
    }

    @Test func buttonsFallBackDedupeAndClampLabels() {
        let settings = DiscordPresenceSettings(button1: .songLink, button1Label: String(repeating: "x", count: 40), button2: .lastFMTrack)
        let buttons = DiscordActivity.build(info: info(songLink: nil), settings: settings, isPlaying: true, startedAt: nil)?.buttons ?? []
        #expect(buttons.count == 1)
        #expect(buttons.first?.url == track.trackURL)
        #expect(buttons.first?.label.count == 32)

        #expect(DiscordActivity.clamp("a", limit: 128).count == 2)
        #expect(DiscordActivity.clamp(String(repeating: "y", count: 200), limit: 128).count == 128)
    }

    @Test func songLinkURLsFromSpotifyAndITunes() {
        #expect(DiscordPresence.songLinkURL(spotifyID: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.absoluteString == "https://song.link/s/4uLU6hMCjMI75M1A2tKUQC")
        #expect(DiscordPresence.songLinkURL(spotifyID: "spotify:local:a:b:c:1") == nil)

        let results: [[String: Any]] = [
            ["trackId": 1, "trackName": "Wants and Needs", "artistName": "Someone Else", "collectionName": "Scary Hours 2"],
            ["trackId": 2, "trackName": "Wants and Needs (feat. Lil Baby)", "artistName": "Drake", "collectionName": "Certified Lover Boy"],
            ["trackId": 3, "trackName": "Wants and Needs (feat. Lil Baby)", "artistName": "Drake", "collectionName": "Scary Hours 2 - EP"],
        ]
        #expect(DiscordPresence.bestITunesMatch(results, for: track)?["trackId"] as? Int == 3)
        #expect(DiscordPresence.bestITunesMatch(Array(results.prefix(1)), for: track) == nil)

        let page = DiscordPresence.appleMusicURL(["trackViewUrl": "https://music.apple.com/us/album/a-milli/1440742903?i=1440743148&uo=4"])
        #expect(page?.absoluteString == "https://music.apple.com/us/album/a-milli/1440742903?i=1440743148")
        #expect(DiscordPresence.appleMusicURL(["trackViewUrl": "https://example.com/x"]) == nil)

        var info = info()
        info.appleMusicURL = page
        let settings = DiscordPresenceSettings(button1: .appleMusic, button2: .none)
        let buttons = DiscordActivity.build(info: info, settings: settings, isPlaying: true, startedAt: nil)?.buttons ?? []
        #expect(buttons.map(\.label) == ["Play on Apple Music"])
        #expect(buttons.first?.url == page)
    }

    @Test func spotifyButtonAndUntitledHasNoButtons() {
        #expect(DiscordPresence.spotifyURL(for: track, source: .spotify, trackID: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.absoluteString
                == "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        #expect(DiscordPresence.spotifyURL(for: track, source: .appleMusic, trackID: "0EA7ADC91E246A67")?.absoluteString
                == "https://open.spotify.com/search/Drake%20Wants%20and%20Needs")

        var spotifyInfo = info()
        spotifyInfo.spotifyURL = URL(string: "https://open.spotify.com/track/abc")
        let settings = DiscordPresenceSettings(button1: .spotify, button2: .lastFMTrack)
        #expect(DiscordActivity.build(info: spotifyInfo, settings: settings, isPlaying: true, startedAt: nil)?.buttons.first?.label == "Play on Spotify")

        spotifyInfo.source = .untitled
        let untitled = DiscordActivity.build(info: spotifyInfo, settings: settings, isPlaying: true, startedAt: nil)
        #expect(untitled?.buttons.isEmpty == true)
        #expect(untitled?.payload["buttons"] == nil)
    }

    @Test func animatedCoversAreFrozenThroughImageProxy() throws {
        let gif = try #require(URL(string: "https://lastfm-img.freetls.fastly.net/i/u/300x300/ba2944136276c89dd14db2d134762306.gif"))
        let frozen = try #require(DiscordPresence.frozenCoverURL(gif))
        let items = URLComponents(url: frozen, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(frozen.host == "wsrv.nl")
        #expect(items.first { $0.name == "url" }?.value == gif.absoluteString)
        #expect(items.first { $0.name == "output" }?.value == "jpg")
    }

    @Test func serviceSettingsOverrideGlobalOnlyWhenTurnedOn() throws {
        let suite = "scrapTests.discord.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("by {artist}", forKey: DiscordKey.stateFormat)
        defaults.set(false, forKey: DiscordKey.showTimestamps)
        defaults.set("{artist} (Spotify)", forKey: DiscordKey.scoped(DiscordKey.stateFormat, .spotify))

        #expect(DiscordPresenceSettings.load(for: .spotify, defaults).stateFormat == "by {artist}")
        defaults.set(true, forKey: DiscordKey.customSettings(.spotify))
        let spotify = DiscordPresenceSettings.load(for: .spotify, defaults)
        #expect(spotify.stateFormat == "{artist} (Spotify)")
        #expect(spotify.showTimestamps == false)
        #expect(DiscordPresenceSettings.load(for: .appleMusic, defaults).stateFormat == "by {artist}")
        #expect(DiscordPresenceSettings.load(defaults).stateFormat == "by {artist}")

        #expect(DiscordPresenceSettings.isShown(for: .untitled, defaults))
        defaults.set(false, forKey: DiscordKey.show(.untitled))
        #expect(!DiscordPresenceSettings.isShown(for: .untitled, defaults))
        #expect(DiscordPresenceSettings.isShown(for: nil, defaults))
    }
}
