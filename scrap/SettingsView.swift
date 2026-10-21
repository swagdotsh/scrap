import SwiftUI
import MediaPlayer

struct SettingsView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @EnvironmentObject private var scrobbler: PlayCountScrobbler
    @EnvironmentObject private var nowPlaying: NowPlayingListener
    @EnvironmentObject private var notifier: Notifier
    @Environment(\.dismiss) private var dismiss
    @AppStorage("removeAlbumTypeSuffix") private var removeAlbumTypeSuffix = false
    @AppStorage("removeAppleMusicEdition") private var removeAppleMusicEdition = false
    @AppStorage("usePrimaryArtist") private var usePrimaryArtist = false
    @AppStorage("removeFeaturedArtists") private var removeFeaturedArtists = false
    @AppStorage("loveAppleMusicFavorites") private var loveAppleMusicFavorites = false
    @AppStorage("backgroundWork") private var backgroundWork = true
    @AppStorage("nonLibraryScrobbling") private var nonLibraryScrobbling = false
    @AppStorage("animatedAlbumCovers") private var animatedAlbumCovers = false
    @ObservedObject private var conditions = DeviceConditions.shared
    @AppStorage("notifyMilestones") private var notifyMilestones = true
    @AppStorage("notifyNewArtists") private var notifyNewArtists = true
    @AppStorage("notifyWeeklyReport") private var notifyWeeklyReport = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $lastFM.scrobblingPaused) {
                    Text("Pause scrobbling")
                    Text("Stops sending plays and now-playing updates to last.fm.")
                }
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
                Text("Plays of songs in your library are scrobbled when scrap opens or iOS gives it time in the background.")
            }

            Section {
                Toggle(isOn: $loveAppleMusicFavorites) {
                    Text("Love favorited songs")
                    Text("When you play a song you've favorited in Apple Music, scrap loves it on last.fm too.")
                }
                .onChange(of: loveAppleMusicFavorites) { _, enabled in
                    guard enabled else { return }
                    Task { if await !AppleMusicFavorites.requestAccess() { loveAppleMusicFavorites = false } }
                }
                Toggle(isOn: $backgroundWork) {
                    Text("Background Work")
                    Text("Lets iOS wake scrap now and then to fetch what's playing and scrobble new plays. iOS decides how often.")
                }
                .onChange(of: backgroundWork) { scrapApp.scheduleRefresh() }
                Toggle(isOn: $nonLibraryScrobbling) {
                    Text("Non-Library Track Scrobbling")
                    Text("Scrobbles songs that aren't in your library once they've played halfway or 4 minutes. Only works while scrap is open or woken by Background Work.")
                }
            }

            Section("Notifications") {
                Toggle(isOn: $notifyMilestones) {
                    Text("Milestones")
                    Text("Every \(Notifier.milestoneStep.formatted()) scrobbles.")
                }
                Toggle(isOn: $notifyNewArtists) {
                    Text("New artist discovered")
                    Text("When you scrobble an artist for the first time.")
                }
                Toggle(isOn: $notifyWeeklyReport) {
                    Text("Weekly report")
                    Text(reportTimeDescription)
                }
                .onChange(of: notifyWeeklyReport) { Task { await notifier.scheduleWeeklyReports() } }
            }
            .onChange(of: notifyMilestones || notifyNewArtists || notifyWeeklyReport) { _, anyOn in
                if anyOn { Task { await notifier.requestAuthorization() } }
            }

            Section("Appearance") {
                Toggle(isOn: $animatedAlbumCovers) {
                    Text("Animated album covers")
                    Text(conditions.reason ?? "Shows animated covers where last.fm has them. Uses more data and battery.")
                }
                .disabled(conditions.limitsAnimation)
            }

            Section("Metadata") {
                Toggle(isOn: $removeAlbumTypeSuffix) {
                    Text("Remove “- Single” and “- EP”")
                    Text("Scrobbles “Song - Single” as “Song”.")
                }
                if removeAlbumTypeSuffix {
                    Toggle(isOn: $removeAppleMusicEdition) {
                        Text("Also remove “(Apple Music Edition)”")
                        Text("Drops Apple Music's edition tag from album names.")
                    }
                }
                Toggle(isOn: $removeFeaturedArtists) {
                    Text("Remove “(feat.)” and “(with)” from song titles")
                    Text("“Wants and Needs (feat. Lil Baby)” is scrobbled as “Wants and Needs”.")
                }
                Toggle(isOn: $usePrimaryArtist) {
                    Text("Scrobble only the primary artist")
                    Text("“Yeat & Drake” is scrobbled as “Yeat”.")
                }
            }

            Section("Account") {
                Text(lastFM.status).foregroundStyle(.secondary)
                Button("Sign out", role: .destructive) {
                    lastFM.signOut()
                    dismiss()
                }
                .disabled(lastFM.isBusy || lastFM.isSending)
            }
        }
        .navigationTitle("Settings")
    }

    private var reportTimeDescription: String {
        let zurich = TimeZone(identifier: "Europe/Zurich")!
        let next = Notifier.upcomingReportDates(count: 1).first ?? .now
        let zone = zurich.isDaylightSavingTime(for: next) ? "Central European Summer Time" : "Central European Time"
        let time = next.formatted(date: .omitted, time: .shortened)
        let local = Calendar.current.component(.weekday, from: next) == 6 ? time : "\(next.formatted(.dateTime.weekday(.wide))) \(time)"
        return "Every Friday at 16:00 \(zone), which is \(local) for you."
    }
}
