import Charts
import SwiftUI

/// Calendar-style picker for a historical week, month or year.
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
        .padding(14)
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
        .frame(width: 240)
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
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 3), spacing: 6) {
                ForEach(1...12, id: \.self) { month in
                    let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
                    let period = ReportPeriod.containing(date, kind: .month)
                    gridButton(date.formatted(.dateTime.month(.abbreviated)), period: period)
                }
            }
        }
        .frame(width: 216)
    }

    private var yearPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 6), count: 4), spacing: 6) {
            ForEach((min(firstYear, lastYear)...lastYear).reversed(), id: \.self) { year in
                let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
                gridButton(String(year), period: ReportPeriod.containing(date, kind: .year))
            }
        }
        .frame(width: 242)
    }

    private func gridButton(_ title: String, period: ReportPeriod) -> some View {
        let isSelected = period == selected
        return Button { onSelect(period) } label: {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
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

/// Scrobbles per hour of the day, with the busiest hour highlighted.
struct ListeningClockChart: View {
    let hourly: [Int]

    private var peak: Int? {
        guard let max = hourly.max(), max > 0 else { return nil }
        return hourly.firstIndex(of: max)
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }

    var body: some View {
        Chart(Array(hourly.enumerated()), id: \.offset) { hour, count in
            BarMark(x: .value("Hour", hour), y: .value("Scrobbles", count), width: .ratio(0.7))
                .foregroundStyle(hour == peak ? Color.accentColor : Color.accentColor.opacity(0.35))
                .accessibilityLabel(Self.hourLabel(hour))
                .accessibilityValue("\(count) scrobbles")
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel { if let hour = value.as(Int.self) { Text(Self.hourLabel(hour)) } }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 70)
    }
}

/// Scrobbles per month of a year, with the busiest month highlighted.
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
        .frame(height: 110)
    }
}

/// Tags with bars sized relative to the top tag.
struct TopTagsList: View {
    let tags: [ListeningReport.Tag]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(tags) { tag in
                Link(destination: tag.url) {
                    HStack(spacing: 10) {
                        Text(tag.name).font(.callout).frame(width: 120, alignment: .leading).lineLimit(1)
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
                .help("Open the \(tag.name) tag on last.fm")
            }
        }
    }
}
