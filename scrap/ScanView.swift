import SwiftUI
import MediaPlayer

struct MissedPlay: Identifiable {
    let id: MPMediaEntityPersistentID
    let track: PlayingTrack
    let startedAt: Date
    let artwork: UIImage?
}

enum MissedPlayScanner {
    static let window: TimeInterval = 14 * 24 * 60 * 60

    @MainActor
    static func scan(lastFM: LastFMClient, now: Date = .now) async throws -> [MissedPlay] {
        let cutoff = now.addingTimeInterval(-window)
        let songs = (MPMediaQuery.songs().items ?? []).filter {
            ($0.lastPlayedDate ?? .distantPast) >= cutoff && $0.playbackDuration > 30 && $0.title != nil && $0.artist != nil
        }
        guard !songs.isEmpty else { return [] }
        let scrobbled = try await lastFM.scrobbledPlays(from: cutoff.addingTimeInterval(-3600), to: now)
            .map { (artist: $0.artist.lowercased(), title: $0.title.lowercased(), date: $0.date) }
        let pending = lastFM.pendingPlays
            .map { (artist: $0.track.artist.lowercased(), title: $0.track.title.lowercased(), date: $0.startedAt) }
        let known = scrobbled + pending

        return songs.compactMap { song -> MissedPlay? in
            guard let title = song.title, let artist = song.artist, let lastPlayed = song.lastPlayedDate else { return nil }
            let startedAt = lastPlayed.addingTimeInterval(-song.playbackDuration)
            let tolerance = song.playbackDuration + 15 * 60
            let matched = known.contains {
                $0.title == title.lowercased() && artist.lowercased().hasPrefix($0.artist)
                    && abs($0.date.timeIntervalSince(startedAt)) < tolerance
            }
            guard !matched, startedAt >= cutoff else { return nil }
            let track = PlayingTrack(title: title, artist: artist, album: song.albumTitle ?? "", duration: song.playbackDuration)
            return MissedPlay(id: song.persistentID, track: track, startedAt: startedAt,
                              artwork: song.artwork?.image(at: CGSize(width: 88, height: 88)))
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}

struct ScanView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var scrobbler: PlayCountScrobbler
    @Environment(\.dismiss) private var dismiss
    @State private var plays: [MissedPlay]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(plays ?? []) { play in
                    Link(destination: play.track.trackURL) {
                        HStack(spacing: 12) {
                            Group {
                                if let artwork = play.artwork {
                                    Image(uiImage: artwork).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "music.note").foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(play.track.title).foregroundStyle(.primary).lineLimit(1)
                                Text(play.track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(play.startedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .onDelete { plays?.remove(atOffsets: $0) }
            }
            .tint(.primary)
            .overlay { overlay }
            .safeAreaInset(edge: .bottom) {
                if let plays, !plays.isEmpty {
                    VStack(spacing: 8) {
                        Button {
                            lastFM.scrobble(plays.map { ($0.track, $0.startedAt) })
                            dismiss()
                        } label: {
                            Text("Scrobble these?").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        Text("Scrobbles older than 2 weeks will be rejected.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .navigationTitle(plays.map { $0.isEmpty ? "Scan" : "\($0.count) missed" } ?? "Scanning…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await scan() }
        }
    }

    @ViewBuilder private var overlay: some View {
        if scrobbler.authorization != .authorized {
            ContentUnavailableView("No access to Apple Music", systemImage: "lock",
                                   description: Text("scrap needs access to your library to look for missed plays."))
        } else if plays == nil, error == nil {
            ProgressView("Looking for missed plays…")
        } else if plays?.isEmpty == true {
            ContentUnavailableView("Nothing missed", systemImage: "checkmark.circle",
                                   description: Text("Everything you've played in the last 2 weeks is on last.fm."))
        }
    }

    private func scan() async {
        guard scrobbler.authorization == .authorized else { return }
        await scrobbler.sync()
        await lastFM.retryPending()
        do {
            let result = try await MissedPlayScanner.scan(lastFM: lastFM)
            guard !Task.isCancelled else { return }
            plays = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't check your last.fm history. \(error.localizedDescription)"
        }
    }
}
