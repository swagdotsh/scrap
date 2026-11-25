import Foundation
import Testing
@testable import scrap

@MainActor
struct MusicPageTests {
    @Test func parsesLastFMMusicURLs() throws {
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/music/Daft+Punk"))) == .artist("Daft Punk"))
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/music/Daft+Punk/Discovery")))
                == .album(artist: "Daft Punk", name: "Discovery"))
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/music/Daft+Punk/_/One+More+Time")))
                == .track(artist: "Daft Punk", name: "One More Time"))
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/de/music/AC%2FDC/_/T.N.T.")))
                == .track(artist: "AC/DC", name: "T.N.T."))
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/music/Daft+Punk/+wiki"))) == .artist("Daft Punk"))
    }

    @Test func parsesPlayingTrackURLs() {
        let track = PlayingTrack(title: "Me & You", artist: "Simon + Garfunkel", album: "Live 1969", duration: nil)
        #expect(MusicItem(url: track.artistURL) == .artist("Simon + Garfunkel"))
        #expect(MusicItem(url: track.albumURL) == .album(artist: "Simon + Garfunkel", name: "Live 1969"))
        #expect(MusicItem(url: track.trackURL) == .track(artist: "Simon + Garfunkel", name: "Me & You"))
    }

    @Test func parsesTagURLs() throws {
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/tag/hip+hop"))) == .tag("hip hop"))
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/de/tag/rock"))) == .tag("rock"))
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/tag/rock/artists"))) == nil)
        #expect(MusicItem.tag("hip hop").url.absoluteString == "https://www.last.fm/tag/hip+hop")
    }

    @Test func roundTripsItemURLs() {
        let items: [MusicItem] = [.artist("Sigur Rós"), .album(artist: "Björk", name: "Homogenic"),
                                  .track(artist: "AC/DC", name: "Back in Black"), .tag("drum and bass")]
        for item in items { #expect(MusicItem(url: item.url) == item) }
    }

    @Test func ignoresOtherLastFMLinks() throws {
        #expect(MusicItem(url: try #require(URL(string: "https://www.last.fm/user/someone"))) == nil)
        #expect(MusicItem(url: try #require(URL(string: "https://open.spotify.com/music/x"))) == nil)
    }

    @Test func monthlyChartAxisUsesThreeRoundedTicks() {
        #expect(MonthlyItemChart.axisTicks(for: 500) == [0, 250, 500])
        #expect(MonthlyItemChart.axisTicks(for: 2_000) == [0, 1_000, 2_000])
        #expect(MonthlyItemChart.axisTicks(for: 7) == [0, 5, 10])
        #expect(MonthlyItemChart.axisTicks(for: 0) == [0, 1])
    }

    @Test func topAlbumsDropEditionsAndCreditedDuplicates() throws {
        let names = ["Luh Leakyz Vol. 1", "Luh Leakyz Vol. 1 Yeat & Lyfestyle Corporation", "Luh Leakyz Vol. 1 [Explicit]",
                     "Luh Leakyz Vol. 1 (Deluxe)", "Luh Leakyz Vol. 2", "Luh Leakyz Vol. 1 Remixes"]
        let albums = try names.map { MusicLink(name: $0, url: try #require(URL(string: "https://www.last.fm/music/Yeat/" + $0.replacingOccurrences(of: " ", with: "+").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))) }
        let kept = ArtistDetails.distinctAlbums(albums, artist: "Yeat").map(\.name)
        #expect(kept == ["Luh Leakyz Vol. 1", "Luh Leakyz Vol. 2", "Luh Leakyz Vol. 1 Remixes"])
    }
}
