import SwiftUI

struct ReportsView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @AppStorage("reportKind") private var reportKind: ReportKind = .week
    @State private var reportPeriod: ReportPeriod?
    @State private var report: ListeningReport?
    @State private var sessionReports: [ReportPeriod: ListeningReport] = [:]
    @State private var reportUser = ""
    @State private var progress: (done: Int, total: Int)?
    @State private var isLoading = false
    @State private var error: String?
    @State private var accountStart: Date?
    @State private var showingPicker = false

    private var shownPeriod: ReportPeriod { reportPeriod ?? .latest(reportKind) }
    private var taskID: String {
        "\(lastFM.username ?? "")-\(shownPeriod.kind.rawValue)-\(Int(shownPeriod.interval.start.timeIntervalSince1970))"
    }
    private var earliestReportDate: Date { accountStart ?? Date(timeIntervalSince1970: 1_009_843_200) }

    var body: some View {
        List {
            periodSection

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(progress.map { $0.total > 1 ? "Building your report… \($0.done) of \($0.total) pages" : "Building your report…" }
                             ?? "Building your report…")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let report, report.period == shownPeriod {
                reportSections(report)
            }
        }
        .tint(.primary)
        .refreshable { await load(forced: true) }
        .task(id: taskID) { await load(forced: false) }
        .onChange(of: reportKind) { _, _ in reportPeriod = nil }
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                ScrollView {
                    ReportPeriodPicker(kind: reportKind, earliest: earliestReportDate, selected: shownPeriod) { picked in
                        show(picked)
                        showingPicker = false
                    }
                }
                .navigationTitle("Choose a \(reportKind.noun)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingPicker = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Period

    private var periodSection: some View {
        let period = shownPeriod
        let latest = ReportPeriod.latest(reportKind)
        let noun = reportKind.noun
        return Section {
            Picker("Report", selection: $reportKind) {
                ForEach(ReportKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Button { show(period.previous) } label: { Image(systemName: "chevron.left") }
                        .disabled(period.previous.interval.end <= earliestReportDate)
                        .accessibilityLabel("Previous \(noun)")
                    Button { showingPicker = true } label: {
                        HStack(spacing: 6) {
                            Text(period.title).font(.title3.bold()).foregroundStyle(.primary)
                            Image(systemName: "calendar").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("Choose a \(noun)")
                    Spacer(minLength: 0)
                    Button { show(period.next) } label: { Image(systemName: "chevron.right") }
                        .disabled(period == latest)
                        .accessibilityLabel("Next \(noun)")
                }
                .buttonStyle(.borderless)
                HStack {
                    if period == latest {
                        Text("Next \(reportKind == .week ? "" : reportKind == .month ? "monthly " : "yearly ")report \(latest.next.releaseDate.formatted(.dateTime.weekday(.wide).month().day()))")
                    }
                    Spacer()
                    if period != latest {
                        Button("Latest") { reportPeriod = nil }.buttonStyle(.borderless).font(.subheadline.bold())
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func show(_ period: ReportPeriod) {
        reportPeriod = period == .latest(period.kind) ? nil : period
    }

    // MARK: Report

    @ViewBuilder private func reportSections(_ report: ListeningReport) -> some View {
        let noun = report.period.kind.noun
        Section("Scrobbles") {
            HStack(alignment: .firstTextBaseline) {
                Text(report.scrobbles.formatted()).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Spacer()
                if report.previousScrobbles > 0 {
                    let change = Double(report.scrobbles - report.previousScrobbles) / Double(report.previousScrobbles)
                    Label(change.formatted(.percent.precision(.fractionLength(0))),
                          systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.headline)
                        .foregroundStyle(change >= 0 ? .green : .red)
                }
            }
            LabeledContent("Previous \(noun)", value: report.previousScrobbles.formatted())
        }

        Section("Top of the \(noun)") {
            if let artist = report.topArtist { row(artist, subtitle: "Top artist", artist: true) }
            if let album = report.topAlbum { row(album, subtitle: "Top album · \(album.artist)", symbol: "opticaldisc") }
            if let track = report.topTrack { row(track, subtitle: "Top track · \(track.artist)") }
            if report.topArtist == nil { Text("No scrobbles this \(noun).").foregroundStyle(.secondary) }
        }

        if report.scrobbles > 0 {
            if report.period.kind == .year, !report.monthly.isEmpty {
                Section("Scrobbles by month") {
                    MonthlyScrobblesChart(monthly: report.monthly).padding(.vertical, 6)
                }
            }
            if let month = report.busiestMonth {
                highlightSection("Month you scrobbled the most", title: month.interval.start.formatted(.dateTime.month(.wide)), highlight: month)
            }
            if let day = report.busiestDay {
                highlightSection("Day you scrobbled the most", title: day.interval.start.formatted(.dateTime.weekday(.wide).month().day()), highlight: day)
            }
            if let peak = report.peakHour {
                Section {
                    ListeningClockChart(hourly: report.hourly).padding(.vertical, 6)
                } header: {
                    Text("Listening clock")
                } footer: {
                    Text("You listened the most around \(ListeningClockChart.hourLabel(peak)), with \(report.hourly[peak].formatted()) scrobbles in that hour.")
                }
            }
            if !report.topTags.isEmpty {
                Section {
                    TopTagsList(tags: report.topTags).padding(.vertical, 4)
                } header: {
                    Text("Top tags")
                } footer: {
                    Text("Based on the tags of your top artists, weighted by plays.")
                }
            }
        }

        discoverySection("New artists", items: report.newArtists, noun: noun, artists: true)
        discoverySection("New albums", items: report.newAlbums, noun: noun, symbol: "opticaldisc")
        discoverySection("New tracks", items: report.newTracks, noun: noun, footer: true)
    }

    private func highlightSection(_ heading: String, title: String, highlight: ListeningReport.Highlight) -> some View {
        Section(heading) {
            LabeledContent(title, value: "\(highlight.scrobbles.formatted()) scrobbles").font(.headline)
            if let artist = highlight.topArtist { row(artist, subtitle: "Top artist", artist: true) }
            if let track = highlight.topTrack { row(track, subtitle: "Top track · \(track.artist)") }
            if let album = highlight.topAlbum { row(album, subtitle: "Top album · \(album.artist)", symbol: "opticaldisc") }
        }
    }

    private func discoverySection(_ title: String, items: [ListeningReport.Item], noun: String, artists: Bool = false,
                                  symbol: String = "music.note", footer: Bool = false) -> some View {
        Section {
            if items.isEmpty { Text("Nothing new this \(noun).").foregroundStyle(.secondary) }
            ForEach(items) { item in
                row(item, subtitle: artists ? nil : item.artist, artist: artists, symbol: symbol, size: 44)
            }
        } header: {
            Text(items.isEmpty ? title : "\(title) (\(items.count))")
        } footer: {
            if footer {
                Text("Checks your \(ListeningReport.discoveryCheckLimit) most-played artists, albums and tracks of the \(noun).")
            }
        }
    }

    private func row(_ item: ListeningReport.Item, subtitle: String?, artist: Bool = false,
                     symbol: String = "music.note", size: CGFloat = 56) -> some View {
        LinkRow(url: item.url, title: item.name, subtitle: subtitle, trailing: "\(item.count.formatted()) play\(item.count == 1 ? "" : "s")") {
            if artist {
                ArtistPortrait(name: item.name, size: size)
            } else {
                RemoteArtwork(url: item.imageURL, symbol: symbol, size: size)
            }
        }
    }

    // MARK: Loading

    private func load(forced: Bool) async {
        let period = shownPeriod
        let username = lastFM.username ?? ""
        if reportUser != username {
            sessionReports = [:]
            reportUser = username
            accountStart = nil
        }
        if forced { sessionReports[period] = nil }
        error = nil
        if let cached = sessionReports[period] { report = cached; return }
        report = forced ? nil : ReportStore.load(period, username: username)
        if let report, report.isFinal { sessionReports[period] = report; return }
        isLoading = true
        progress = nil
        defer { isLoading = false; progress = nil }
        if accountStart == nil { accountStart = try? await lastFM.profile()?.registered }
        do {
            let result = try await lastFM.listeningReport(for: period) { done, total in
                progress = (done, total)
            }
            guard !Task.isCancelled, lastFM.username == username else { return }
            report = result
            sessionReports[period] = result
            ReportStore.save(result, username: username)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't build your report. \(error.localizedDescription)"
        }
    }
}
