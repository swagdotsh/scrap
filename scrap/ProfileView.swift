import SwiftUI

struct ProfileView: View {
    let profile: ListenerProfile?
    @EnvironmentObject private var lastFM: LastFMClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage("profileChartPeriod") private var period = ChartPeriod.week
    @State private var charts: [ChartKind: [ProfileChartEntry]] = [:]
    @State private var error: String?
    @State private var libraryCounts: [ChartKind: Int] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let profile {
                    Section {
                        Link(destination: profile.url ?? URL(string: "https://www.last.fm")!) {
                            HStack(spacing: 14) {
                                Avatar(url: profile.avatarURL, size: 64)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(.title3.bold()).foregroundStyle(.primary)
                                    if !profile.realName.isEmpty {
                                        Text(profile.realName).foregroundStyle(.secondary)
                                    }
                                    Text("\(profile.playCount.formatted()) scrobbles").font(.subheadline).foregroundStyle(.secondary)
                                    if let registered = profile.registered {
                                        Text("Joined \(registered.formatted(.dateTime.day().month(.abbreviated).year()))")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    Section("last.fm and You") {
                        libraryRow("Artists", systemImage: "music.mic", kind: .artists)
                        libraryRow("Albums", systemImage: "square.stack", kind: .albums)
                        libraryRow("Tracks", systemImage: "music.note", kind: .tracks)
                    }
                }

                Section {
                    Picker("Period", selection: $period) {
                        ForEach(ChartPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if let error { Text(error).foregroundStyle(.red) }
                }

                ForEach(ChartKind.allCases, id: \.self) { kind in
                    Section {
                        if let entries = charts[kind] {
                            if entries.isEmpty {
                                Text("Nothing scrobbled in this period.").foregroundStyle(.secondary)
                            }
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                LinkRow(url: entry.link.url, title: entry.link.name,
                                        subtitle: kind == .artists ? nil : entry.artist,
                                        trailing: "\(entry.count.formatted()) plays") {
                                    HStack(spacing: 10) {
                                        Text("\(index + 1)").font(.footnote.bold()).foregroundStyle(.secondary)
                                            .monospacedDigit().frame(width: 20)
                                        ChartArtwork(kind: kind, entry: entry, size: 44)
                                    }
                                }
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    } header: {
                        HStack {
                            Text(kind.title)
                            Spacer()
                            if charts[kind]?.isEmpty == false {
                                NavigationLink("Show more") { ChartGalleryView(kind: kind, period: period) }
                                    .font(.subheadline)
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
            .tint(.primary)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task(id: "\(lastFM.username ?? "")|\(period)") { await load() }
            .task(id: lastFM.username) { await loadLibraryCounts() }
        }
        .musicPages()
    }

    private func libraryRow(_ title: String, systemImage: String, kind: ChartKind) -> some View {
        LabeledContent {
            if let count = libraryCounts[kind] {
                Text(count.formatted()).monospacedDigit()
            } else {
                ProgressView()
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func loadLibraryCounts() async {
        let known: [ChartKind: Int?] = [.artists: profile?.artistCount, .albums: profile?.albumCount, .tracks: profile?.trackCount]
        libraryCounts = known.compactMapValues { $0 }
        await withTaskGroup(of: (ChartKind, Int?).self) { group in
            for kind in ChartKind.allCases where libraryCounts[kind] == nil {
                group.addTask { (kind, await lastFM.libraryCount(kind)) }
            }
            for await (kind, count) in group {
                guard !Task.isCancelled else { return }
                libraryCounts[kind] = count ?? 0
            }
        }
    }

    private func load() async {
        charts = [:]
        error = nil
        await withTaskGroup(of: (ChartKind, [ProfileChartEntry]?).self) { group in
            for kind in ChartKind.allCases {
                group.addTask { [period] in (kind, try? await lastFM.profileChart(kind, period: period, limit: 5)) }
            }
            for await (kind, entries) in group {
                guard !Task.isCancelled else { return }
                charts[kind] = entries ?? []
                if entries == nil { error = "Couldn't load some of your charts. Pull down to try again." }
            }
        }
    }
}
