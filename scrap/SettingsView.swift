import SwiftUI
import MediaPlayer

struct SettingsView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var scrobbler: PlayCountScrobbler
    @EnvironmentObject private var nowPlaying: NowPlayingListener
    @Environment(\.dismiss) private var dismiss
    @AppStorage("removeAlbumTypeSuffix") private var removeAlbumTypeSuffix = false
    @AppStorage("removeAppleMusicEdition") private var removeAppleMusicEdition = false
    @AppStorage("usePrimaryArtist") private var usePrimaryArtist = false
    @AppStorage("loveAppleMusicFavorites") private var loveAppleMusicFavorites = false

    var body: some View {
        Form {
            Section {
                Toggle("Pause scrobbling", isOn: $lastFM.scrobblingPaused)
                switch scrobbler.authorization {
                case .authorized:
                    LabeledContent("Status", value: scrobbler.status)
                    if let lastSync = scrobbler.lastSync {
                        LabeledContent("Last checked") { Text("\(Text(lastSync, style: .relative)) ago") }
                    }
                    if lastFM.pendingCount > 0 {
                        LabeledContent("Waiting to send", value: "\(lastFM.pendingCount)")
                    }
                    Button(scrobbler.isSyncing ? "Checking…" : "Check for new plays") {
                        Task { await scrobbler.sync(); await lastFM.retryPending() }
                    }
                    .disabled(scrobbler.isSyncing || lastFM.isSending)
                case .denied, .restricted:
                    Text("scrap needs access to Apple Music to see what you've played.")
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                default:
                    Button("Allow access to Apple Music") {
                        Task {
                            await scrobbler.requestAccess()
                            if scrobbler.authorization == .authorized { nowPlaying.start() }
                        }
                    }
                }
            } header: {
                Text("Scrobbling")
            } footer: {
                Text("Plays of songs in your library are scrobbled when scrap opens or iOS gives it time in the background. Songs played outside your library aren't counted.")
            }

            Section {
                Toggle("Love favorited songs", isOn: $loveAppleMusicFavorites)
                    .onChange(of: loveAppleMusicFavorites) { _, enabled in
                        guard enabled else { return }
                        Task { if await !AppleMusicFavorites.requestAccess() { loveAppleMusicFavorites = false } }
                    }
            } footer: {
                Text("When you play a song you've favorited in Apple Music, scrap loves it on last.fm too.")
            }

            Section("Metadata") {
                Toggle("Remove “- Single” and “- EP”", isOn: $removeAlbumTypeSuffix)
                if removeAlbumTypeSuffix {
                    Toggle("Also remove “(Apple Music Edition)”", isOn: $removeAppleMusicEdition)
                }
                Toggle("Scrobble only the primary artist", isOn: $usePrimaryArtist)
            }

            Section("Account") {
                Text(lastFM.status).foregroundStyle(.secondary)
                Button("Sign out", role: .destructive) {
                    lastFM.signOut()
                    dismiss()
                }
                .disabled(lastFM.isBusy || lastFM.isSending)
            }

            Section {
                Link("scrap on GitHub", destination: URL(string: "https://github.com/swagdotsh/scrap")!)
            }
        }
        .navigationTitle("Settings")
    }
}
