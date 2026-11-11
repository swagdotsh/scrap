import Foundation
import Testing
@testable import scrap

@MainActor
struct ListeningReportTests {
    private let calendar = ReportPeriod.calendar

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func play(_ title: String, _ artist: String, _ album: String = "", at date: Date) -> ScrobbledPlay {
        ScrobbledPlay(title: title, artist: artist, album: album, date: date, imageURL: nil)
    }

    @Test func periodsCoverWeeksMonthsAndYears() {
        let week = ReportPeriod.containing(date(2026, 11, 11), kind: .week)
        #expect(calendar.component(.weekday, from: week.interval.start) == 7)
        #expect(week.interval.start == date(2026, 11, 7, 0))
        #expect(week.lastDay == date(2026, 11, 13, 0))

        let month = ReportPeriod.containing(date(2026, 11, 11), kind: .month)
        #expect(month.interval.start == date(2026, 11, 1, 0))
        #expect(month.interval.end == date(2026, 12, 1, 0))
        #expect(month.previous.interval.start == date(2026, 10, 1, 0))
        #expect(month.next.interval.start == date(2026, 12, 1, 0))

        let year = ReportPeriod.containing(date(2026, 3, 1), kind: .year)
        #expect(year.interval.start == date(2026, 1, 1, 0))
        #expect(year.title == "2026")
    }

    @Test func monthlyAndYearlyReportsComeOutOnTheFirstFridayAfter() {
        let october = ReportPeriod.containing(date(2026, 10, 15), kind: .month)
        let release = october.releaseDate
        #expect(calendar.component(.weekday, from: release) == 6 || calendar.component(.weekday, from: release) == 7)
        #expect(release > october.interval.end)
        #expect(release < calendar.date(byAdding: .day, value: 8, to: october.interval.end)!)

        // November 11, 2026: October's report (out Friday, November 6) is the latest; November's isn't out yet.
        #expect(ReportPeriod.latest(.month, now: date(2026, 11, 11)) == october)
        #expect(ReportPeriod.latest(.month, now: date(2026, 11, 2)).interval.start == date(2026, 9, 1, 0))
        #expect(ReportPeriod.latest(.year, now: date(2026, 11, 11)).interval.start == date(2025, 1, 1, 0))
        #expect(ReportPeriod.latest(.week, now: date(2026, 11, 11)).interval.start == date(2026, 10, 31, 0))
        #expect(ReportPeriod.latest(.week, now: date(2026, 11, 13)).interval.start == date(2026, 11, 7, 0))
    }

    @Test func talliesRankByPlaysThenFirstPlayed() {
        let plays = [
            play("A", "Yeat", "2093", at: date(2026, 1, 3, 9)),
            play("B", "Drake", "For All The Dogs", at: date(2026, 1, 3, 22)),
            play("A", "yeat", "2093", at: date(2026, 1, 4, 22)),
            play("C", "Drake", "", at: date(2026, 2, 10, 22)),
        ]
        let top = ListeningReport.rankings(plays)
        #expect(top.artists.map(\.count) == [2, 2])
        #expect(top.artists.first?.play.artist == "Yeat")
        #expect(top.albums.first?.play.album == "2093")
        #expect(top.albums.count == 2)
        #expect(top.tracks.first?.count == 2)

        let hours = ListeningReport.hourly(plays)
        #expect(hours.count == 24 && hours[22] == 3 && hours[9] == 1)
        let months = ListeningReport.monthly(plays)
        #expect(months[0] == 3 && months[1] == 1)

        let day = ListeningReport.busiest(plays, by: .day)
        #expect(day?.interval.start == date(2026, 1, 3, 0))
        #expect(day?.scrobbles == 2)
        let month = ListeningReport.busiest(plays, by: .month)
        #expect(month?.interval.start == date(2026, 1, 1, 0))
        #expect(month?.topArtist?.name == "Yeat")
        #expect(month?.topTrack?.name == "A")
        #expect(month?.topAlbum?.name == "2093")
    }

    @Test func tagsAreWeightedByPlaysAndSkipNoise() {
        let tags = ListeningReport.combineTags([
            (plays: 10, artist: "Yeat", tags: [("trap", 100), ("rage", 40), ("seen live", 90), ("Yeat", 50)]),
            (plays: 5, artist: "Drake", tags: [("rap", 100), ("Trap", 20)]),
        ])
        #expect(tags.map(\.name) == ["trap", "rap", "rage"])
        #expect(tags.first?.weight == 1)
        #expect(tags.first?.url.absoluteString == "https://www.last.fm/tag/trap")
        #expect(ListeningReport.combineTags([]).isEmpty)
    }

    @Test func reportsRoundTripAndOnlyRecentWeeksAreStored() throws {
        let now = date(2026, 11, 11)
        let latest = ReportPeriod.latest(.week, now: now)
        #expect(ReportStore.isStored(latest, now: now))
        var period = latest
        for _ in 0..<3 { period = period.previous }
        #expect(ReportStore.isStored(period, now: now))
        #expect(!ReportStore.isStored(period.previous, now: now))
        #expect(!ReportStore.isStored(ReportPeriod.latest(.month, now: now), now: now))

        let item = ListeningReport.Item(name: "Yeat", count: 3, url: URL(string: "https://www.last.fm/music/Yeat")!)
        var report = ListeningReport(period: latest, scrobbles: 3, previousScrobbles: 1, topArtist: item, builtAt: latest.interval.end)
        report.hourly = Array(repeating: 0, count: 24)
        let decoded = try JSONDecoder().decode(ListeningReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.period == latest)
        #expect(decoded.topArtist?.name == "Yeat")
        #expect(decoded.isFinal)
    }
}
