import Foundation
import Testing
@testable import scrap

@MainActor
struct scrapTests {
    private let track = PlayingTrack(title: "A&B + C", artist: "Artist", album: "Album", duration: 60)

    @Test func pausesDoNotCountAndRepeatStartsANewScrobble() {
        let engine = ScrobbleEngine()
        let start = Date(timeIntervalSince1970: 1000)
        var submissions: [Date] = []
        engine.onScrobble = { _, date in submissions.append(date) }
        for second in 0...15 { engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(Double(second))) }
        engine.update(track: track, isPlaying: false, now: start.addingTimeInterval(16))
        engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(100))
        #expect(engine.accumulatedPlayTime == 16)
        for second in 101...114 { engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(Double(second))) }
        #expect(submissions == [start])
        engine.update(track: track, isPlaying: true, restarted: true, now: start.addingTimeInterval(115))
        for second in 116...145 { engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(Double(second))) }
        #expect(submissions == [start, start.addingTimeInterval(115)])
    }

    @Test func sleepAndShortTracksDoNotScrobble() {
        let engine = ScrobbleEngine()
        var count = 0
        engine.onScrobble = { _, _ in count += 1 }
        let start = Date(timeIntervalSince1970: 1000)
        engine.update(track: track, isPlaying: true, now: start)
        engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(600))
        #expect(engine.accumulatedPlayTime == 0)
        let short = PlayingTrack(title: "Short", artist: "Artist", album: "", duration: 30)
        for second in 601...650 { engine.update(track: short, isPlaying: true, now: start.addingTimeInterval(Double(second))) }
        #expect(count == 0)
    }

    @Test func pausedTrackDoesNotPublishNowPlaying() {
        let engine = ScrobbleEngine()
        var count = 0
        engine.onNowPlaying = { _ in count += 1 }
        engine.update(track: track, isPlaying: false)
        #expect(count == 0)
        engine.update(track: track, isPlaying: true)
        engine.update(track: track, isPlaying: true)
        #expect(count == 1)
    }

    @Test func savedAccountWithoutAppCredentialsIsNotShownAsConnected() {
        let status = LastFMClient.accountStatus(isConfigured: false, hasSession: true, username: "listener")
        #expect(status.contains("Account saved as listener"))
        #expect(!status.contains("Connected as"))
        #expect(LastFMClient.accountStatus(isConfigured: true, hasSession: false, username: "listener").contains("Connect your"))
        #expect(LastFMClient.accountStatus(isConfigured: true, hasSession: true, username: "listener") == "Connected as listener.")
    }

    @Test func environmentParserHandlesQuotesAndEquals() {
        let values = AppConfiguration.parse("# ignored\nLASTFM_API_KEY = 'abc=123'\nLASTFM_SHARED_SECRET=\"secret\"\n")
        #expect(values["LASTFM_API_KEY"] == "abc=123")
        #expect(values["LASTFM_SHARED_SECRET"] == "secret")
    }

    @Test func listeningHistoryDistinguishesZeroAndUnavailable() {
        #expect(ListeningDetails(artistCount: 0, trackCount: 0).summary(for: track) == "You've never scrobbled Artist before.")
        #expect(ListeningDetails(artistCount: 12, trackCount: 0).summary(for: track) == "You've scrobbled Artist 12 times, but not this track.")
        #expect(ListeningDetails(artistCount: 12, trackCount: 3).summary(for: track) == "You've scrobbled to Artist 12 times and A&B + C 3 times.")
        #expect(ListeningDetails().summary(for: track) == "Listening history unavailable.")
    }

    @Test func friendsDecodeRecentAndMissingListening() {
        let friend = FriendActivity.parse(["name": "alex", "recenttrack": ["name": "Song", "artist": ["#text": "Artist"]]])
        #expect(friend?.track == "Song")
        #expect(friend?.artist == "Artist")
        #expect(FriendActivity.parse(["name": "alex"])?.track == nil)
        #expect(FriendActivity.parse([:]) == nil)
    }

    @Test func artistBiographyAndLinksAreCleaned() {
        #expect(ArtistDetails.plainBiography("A &amp; B. <a href='https://last.fm'>Read more</a>") == "A & B.")
        #expect(ArtistDetails.plainBiography("<a href='https://last.fm'>Read more</a>").isEmpty)
        let rows: [[String: Any]] = (1...7).map { ["name": "Tag \($0)", "url": "http://www.last.fm/tag/\($0)"] }
        let links = MusicLink.parse(rows, limit: 5)
        #expect(links.count == 5)
        #expect(links.first?.url.scheme == "https")
        #expect(MusicLink.parse([["name": "Invalid", "url": "javascript:alert(1)"]]).isEmpty)
    }

    @Test func suspendedScrobblingExcludesPausedTime() {
        let engine = ScrobbleEngine()
        let start = Date(timeIntervalSince1970: 1000)
        engine.update(track: track, isPlaying: true, now: start)
        engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(1))
        engine.suspendTiming()
        engine.update(track: track, isPlaying: false, now: start.addingTimeInterval(2))
        engine.update(track: track, isPlaying: false, now: start.addingTimeInterval(60))
        #expect(engine.accumulatedPlayTime == 1)
        engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(61))
        engine.update(track: track, isPlaying: true, now: start.addingTimeInterval(62))
        #expect(engine.accumulatedPlayTime == 2)
    }

    @Test func formEncodingPreservesSpecialCharacters() {
        #expect(LastFMClient.formBody(["track": "A&B + C=é"]) == "track=A%26B%20%2B%20C%3D%C3%A9")
    }
}
