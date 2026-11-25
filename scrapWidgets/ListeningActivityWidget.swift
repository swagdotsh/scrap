import WidgetKit
import SwiftUI

enum DailyScrobbles {
    static let weeks = 20
    static let fetchLimit = 70

    static var calendar: Calendar { Calendar.current }

    static func firstDay(now: Date = .now) -> Date {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
    }

    static func days(now: Date = .now) -> [Date] {
        let today = calendar.startOfDay(for: now)
        var days: [Date] = []
        var day = firstDay(now: now)
        while day <= today {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return days
    }

    private static func fileURL(_ username: String) -> URL? {
        let name = username.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.swagrelated.scrap")?
            .appendingPathComponent("Library/Application Support/DailyScrobbles", isDirectory: true)
            .appendingPathComponent("\(name).json")
    }

    static func load(_ username: String) -> [Int: Int] {
        guard let url = fileURL(username), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static func save(_ counts: [Int: Int], username: String) {
        guard let url = fileURL(username),
              let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) })) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func key(_ day: Date) -> Int { Int(day.timeIntervalSince1970) }

    static func daysToFetch(_ days: [Date], saved: [Int: Int], now: Date = .now) -> [Date] {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        return days.reversed().filter { $0 >= yesterday || saved[key($0)] == nil }
    }

    static func refresh(credentials: WidgetLastFM.Credentials, now: Date = .now) async -> (counts: [Int: Int], complete: Bool) {
        let days = days(now: now)
        let shown = Set(days.map(key))
        var counts = load(credentials.username).filter { shown.contains($0.key) }
        let pending = daysToFetch(days, saved: counts, now: now)
        let batch = Array(pending.prefix(fetchLimit))
        var next = 0
        await withTaskGroup(of: (Int, Int?).self) { group in
            func add() {
                guard next < batch.count else { return }
                let day = batch[next]
                next += 1
                group.addTask { (key(day), await count(on: day, credentials: credentials)) }
            }
            for _ in 0..<6 { add() }
            for await (day, value) in group {
                if let value { counts[day] = value }
                add()
            }
        }
        save(counts, username: credentials.username)
        return (counts, days.allSatisfy { counts[key($0)] != nil })
    }

    private static func count(on day: Date, credentials: WidgetLastFM.Credentials) async -> Int? {
        guard let end = calendar.date(byAdding: .day, value: 1, to: day),
              let json = try? await WidgetLastFM.request(["method": "user.getRecentTracks", "user": credentials.username, "limit": "1",
                                                          "from": String(key(day)), "to": String(key(end) - 1)],
                                                         credentials: credentials),
              let attributes = (json["recenttracks"] as? [String: Any])?["@attr"] as? [String: Any],
              attributes["total"] != nil else { return nil }
        return WidgetLastFM.count(attributes["total"])
    }

    static func levels(_ counts: [Int]) -> (Int) -> Int {
        let active = counts.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return { _ in 0 } }
        func quantile(_ fraction: Double) -> Int { active[min(active.count - 1, Int(Double(active.count - 1) * fraction))] }
        let first = quantile(0.25), second = quantile(0.5), third = quantile(0.75)
        return { count in
            if count <= 0 { return 0 }
            if count <= first { return 1 }
            if count <= second { return 2 }
            if count <= third { return 3 }
            return 4
        }
    }
}

struct ListeningActivityEntry: TimelineEntry {
    let date: Date
    var counts: [Int?] = []
    var signedIn = true

    var total: Int { counts.reduce(0) { $0 + ($1 ?? 0) } }

    static var sample: ListeningActivityEntry {
        let days = DailyScrobbles.days()
        let counts: [Int?] = days.enumerated().map { index, day in
            let weekday = DailyScrobbles.calendar.component(.weekday, from: day)
            let wave = (index * 37 + weekday * 11) % 17
            return wave < 3 ? 0 : wave * 6 + (weekday == 1 || weekday == 7 ? 30 : 0)
        }
        return ListeningActivityEntry(date: .now, counts: counts)
    }
}

struct ListeningActivityProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListeningActivityEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (ListeningActivityEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
            return
        }
        Task { completion(await Self.load().entry) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningActivityEntry>) -> Void) {
        Task {
            let (entry, complete) = await Self.load()
            let next = Date.now.addingTimeInterval(complete ? 30 * 60 : 5 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private static func load() async -> (entry: ListeningActivityEntry, complete: Bool) {
        guard let credentials = WidgetLastFM.credentials else {
            return (ListeningActivityEntry(date: .now, signedIn: false), true)
        }
        let (counts, complete) = await DailyScrobbles.refresh(credentials: credentials)
        let days = DailyScrobbles.days()
        return (ListeningActivityEntry(date: .now, counts: days.map { counts[DailyScrobbles.key($0)] }), complete)
    }
}

struct ListeningActivityWidgetView: View {
    let entry: ListeningActivityEntry
    @Environment(\.colorScheme) private var colorScheme

    private let spacing: CGFloat = 3

    var body: some View {
        Group {
            if !entry.signedIn {
                Text("Open scrap to sign in to last.fm.").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("LISTENING").font(.caption2.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.total.formatted()) scrobbles · \(DailyScrobbles.weeks) weeks")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    grid
                }
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var grid: some View {
        let level = DailyScrobbles.levels(entry.counts.compactMap { $0 })
        let columns = DailyScrobbles.weeks
        return GeometryReader { proxy in
            let side = max(4, min((proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns),
                                  (proxy.size.height - spacing * 6) / 7))
            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            let index = column * 7 + row
                            if index < entry.counts.count {
                                RoundedRectangle(cornerRadius: side / 4)
                                    .fill(color(entry.counts[index].map(level)))
                                    .frame(width: side, height: side)
                            } else {
                                Color.clear.frame(width: side, height: side)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityElement()
        .accessibilityLabel("\(entry.total.formatted()) scrobbles in the last \(DailyScrobbles.weeks) weeks")
    }

    private func color(_ level: Int?) -> Color {
        let dark = colorScheme == .dark
        switch level ?? 0 {
        case 1: return dark ? Color(red: 0.06, green: 0.20, blue: 0.42) : Color(red: 0.74, green: 0.85, blue: 0.98)
        case 2: return dark ? Color(red: 0.09, green: 0.36, blue: 0.70) : Color(red: 0.45, green: 0.66, blue: 0.95)
        case 3: return dark ? Color(red: 0.24, green: 0.55, blue: 0.92) : Color(red: 0.18, green: 0.46, blue: 0.88)
        case 4: return dark ? Color(red: 0.58, green: 0.80, blue: 1.00) : Color(red: 0.05, green: 0.30, blue: 0.70)
        default: return Color.primary.opacity(dark ? 0.10 : 0.07)
        }
    }
}

struct ListeningActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ListeningActivity", provider: ListeningActivityProvider()) { entry in
            ListeningActivityWidgetView(entry: entry)
        }
        .configurationDisplayName("Listening Activity")
        .description("Your scrobbles per day for the last 20 weeks. The bluer a square, the more you listened that day.")
        .supportedFamilies([.systemMedium])
    }
}
