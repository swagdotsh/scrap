import Charts
import SwiftUI

struct ReportPeriodPicker: View {
    let kind: ReportKind
    let earliest: Date
    let selected: ReportPeriod
    let onSelect: (ReportPeriod) -> Void
    @State private var day: Date
    @State private var year: Int

    init(kind: ReportKind, earliest: Date, selected: ReportPeriod, onSelect: @escaping (ReportPeriod) -> Void) {
        self.kind = kind
        self.earliest = earliest
        self.selected = selected
        self.onSelect = onSelect
        _day = State(initialValue: selected.interval.start)
        _year = State(initialValue: ReportPeriod.calendar.component(.year, from: selected.interval.start))
    }

    private var calendar: Calendar { ReportPeriod.calendar }
    private var latest: ReportPeriod { .latest(kind) }
    private var firstYear: Int { calendar.component(.year, from: earliest) }
    private var lastYear: Int { calendar.component(.year, from: ReportPeriod.latest(kind).interval.start) }

    private func isAvailable(_ period: ReportPeriod) -> Bool {
        period.isReleased() && period.interval.end > earliest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a \(kind.noun)").font(.headline)
            switch kind {
            case .week: weekPicker
            case .month: monthPicker
            case .year: yearPicker
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var weekPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("Week", selection: $day, in: min(earliest, latest.lastDay)...latest.lastDay, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onChange(of: day) { _, newDay in
                    let week = ReportPeriod.containing(newDay, kind: .week)
                    if isAvailable(week), week != selected { onSelect(week) }
                }
            Text("Pick any day to see its week (Saturday to Friday).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var monthPicker: some View {
        VStack(spacing: 10) {
            HStack {
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(year <= firstYear).accessibilityLabel("Previous year")
                Spacer()
                Text(String(year)).font(.headline.monospacedDigit())
                Spacer()
                Button { year += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(year >= lastYear).accessibilityLabel("Next year")
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
                    let period = ReportPeriod.containing(date, kind: .month)
                    gridButton(date.formatted(.dateTime.month(.abbreviated)), period: period)
                }
            }
        }
    }

    private var yearPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach((min(firstYear, lastYear)...lastYear).reversed(), id: \.self) { year in
                let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
                gridButton(String(year), period: ReportPeriod.containing(date, kind: .year))
            }
        }
    }

    private func gridButton(_ title: String, period: ReportPeriod) -> some View {
        let isSelected = period == selected
        return Button { onSelect(period) } label: {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable(period))
        .opacity(isAvailable(period) ? 1 : 0.35)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ListeningClockChart: View {
    let hourly: [Int]

    private var peak: Int? {
        guard let max = hourly.max(), max > 0 else { return nil }
        return hourly.firstIndex(of: max)
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        let uses12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
        return uses12Hour ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    var body: some View {
        Chart(Array(hourly.enumerated()), id: \.offset) { hour, count in
            BarMark(x: .value("Hour", String(hour)), y: .value("Scrobbles", count), width: .ratio(0.7))
                .foregroundStyle(hour == peak ? Color.accentColor : Color.accentColor.opacity(0.35))
                .accessibilityLabel(Self.hourLabel(hour))
                .accessibilityValue("\(count) scrobbles")
        }
        .chartXScale(domain: (0..<24).map(String.init))
        .chartXAxis {
            AxisMarks { value in
                if let hour = value.as(String.self).flatMap(Int.init), hour % 6 == 0 {
                    AxisValueLabel(Self.hourLabel(hour), anchor: .topLeading, collisionResolution: .disabled)
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 90)
    }
}

struct MonthlyScrobblesChart: View {
    let monthly: [Int]

    private var peak: Int? {
        guard let max = monthly.max(), max > 0 else { return nil }
        return monthly.firstIndex(of: max)
    }

    private func name(_ index: Int) -> String {
        Calendar.current.shortMonthSymbols[index]
    }

    var body: some View {
        Chart(Array(monthly.enumerated()), id: \.offset) { index, count in
            BarMark(x: .value("Month", name(index)), y: .value("Scrobbles", count), width: .ratio(0.7))
                .foregroundStyle(index == peak ? Color.accentColor : Color.accentColor.opacity(0.35))
                .accessibilityValue("\(count) scrobbles")
        }
        .chartXScale(domain: Calendar.current.shortMonthSymbols)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(height: 130)
    }
}

struct TopTagsList: View {
    let tags: [ListeningReport.Tag]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(tags) { tag in
                Link(destination: tag.url) {
                    HStack(spacing: 10) {
                        Text(tag.name).font(.callout).foregroundStyle(.primary).frame(width: 120, alignment: .leading).lineLimit(1)
                        GeometryReader { proxy in
                            Capsule().fill(Color.accentColor.opacity(0.6))
                                .frame(width: max(6, proxy.size.width * tag.weight), height: 8)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the \(tag.name) tag on last.fm")
            }
        }
    }
}
