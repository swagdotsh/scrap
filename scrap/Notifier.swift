import Foundation
import UserNotifications
import Combine

@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let milestoneStep = 5000

    private let lastFM: LastFMClient
    private let defaults = UserDefaults.standard
    private var sessionPlays: [String: Int] = [:]
    private var checkedArtists = Set<String>()

    init(lastFM: LastFMClient) {
        self.lastFM = lastFM
        super.init()
        defaults.register(defaults: ["notifyMilestones": true, "notifyNewArtists": true, "notifyWeeklyReport": true])
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func refresh() async {
        await scheduleWeeklyReports()
        await checkMilestone()
    }

    func scheduleWeeklyReports() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("weeklyReport-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard defaults.bool(forKey: "notifyWeeklyReport") else { return }
        for date in Self.upcomingReportDates(count: 4) {
            let week = WeeklyReport.latestWeek(now: date)
            let last = Calendar.current.date(byAdding: .day, value: -1, to: week.end)!
            let content = UNMutableNotificationContent()
            content.title = "Your weekly report is ready"
            content.body = "See your top artist, album and track for \(week.start.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day()))."
            content.sound = .default
            content.userInfo = ["tab": "reports"]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "weeklyReport-\(Int(date.timeIntervalSince1970))", content: content, trigger: trigger))
        }
    }

    static func upcomingReportDates(count: Int, after now: Date = .now) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        var dates: [Date] = []
        var cursor = now
        while dates.count < count,
              let next = calendar.nextDate(after: cursor, matching: DateComponents(hour: 16, minute: 0, weekday: 6), matchingPolicy: .nextTime) {
            dates.append(next)
            cursor = next
        }
        return dates
    }

    func checkMilestone() async {
        guard let profile = try? await lastFM.profile() else { return }
        let reached = profile.playCount / Self.milestoneStep * Self.milestoneStep
        let key = "lastMilestone-\(profile.name.lowercased())"
        guard defaults.object(forKey: key) != nil else {
            defaults.set(reached, forKey: key)
            return
        }
        guard reached > defaults.integer(forKey: key) else { return }
        defaults.set(reached, forKey: key)
        guard defaults.bool(forKey: "notifyMilestones"), reached > 0 else { return }
        post(id: "milestone-\(reached)", title: "\(reached.formatted()) scrobbles!",
             body: "You just passed \(reached.formatted()) scrobbles on last.fm.", tab: "nowPlaying")
    }

    func didScrobble(_ track: PlayingTrack) {
        let artist = track.artist.lowercased()
        sessionPlays[artist, default: 0] += 1
        guard defaults.bool(forKey: "notifyNewArtists"), let username = lastFM.username,
              checkedArtists.insert(artist).inserted else { return }
        var notified = Set(defaults.stringArray(forKey: "notifiedNewArtists") ?? [])
        guard !notified.contains(artist) else { return }
        Task {
            guard let json = try? await lastFM.request(["method": "artist.getInfo", "artist": track.artist, "username": username]),
                  let stats = (json["artist"] as? [String: Any])?["stats"] as? [String: Any],
                  let total = LastFMClient.count(stats["userplaycount"]),
                  total <= sessionPlays[artist, default: 1] else { return }
            notified.insert(artist)
            defaults.set(Array(notified), forKey: "notifiedNewArtists")
            post(id: "newArtist-\(artist)", title: "New artist discovered",
                 body: "You scrobbled \(track.artist) for the first time.", tab: "reports")
        }
    }

    private func post(id: String, title: String, body: String, tab: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["tab": tab]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let tab = response.notification.request.content.userInfo["tab"] as? String else { return }
        await MainActor.run { UserDefaults.standard.set(tab, forKey: "selectedTab") }
    }
}
