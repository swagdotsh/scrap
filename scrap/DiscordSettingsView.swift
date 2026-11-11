import SwiftUI

struct DiscordSettingsView: View {
    @ObservedObject var presence: DiscordPresence
    @State private var scope: PlaybackService?

    var body: some View {
        DiscordSettingsPane(presence: presence, scope: $scope)
            .id(scope?.rawValue ?? "all")
    }
}

/// The settings for one scope: all services, or one service's own settings.
private struct DiscordSettingsPane: View {
    @ObservedObject var presence: DiscordPresence
    @Binding var scope: PlaybackService?
    @AppStorage(DiscordKey.enabled) private var enabled = false
    @AppStorage private var showForService: Bool
    @AppStorage private var customForService: Bool
    @AppStorage private var detailsFormat: String
    @AppStorage private var stateFormat: String
    @AppStorage private var albumFormat: String
    @AppStorage private var statusSource: DiscordStatusSource
    @AppStorage private var showCover: Bool
    @AppStorage private var coverSource: DiscordCoverSource
    @AppStorage private var showTimestamps: Bool
    @AppStorage private var linkNames: Bool
    @AppStorage private var useScrobbleCleanup: Bool
    @AppStorage private var paused: DiscordPausedBehavior
    @AppStorage private var button1: DiscordButtonKind
    @AppStorage private var button1Label: String
    @AppStorage private var button2: DiscordButtonKind
    @AppStorage private var button2Label: String
    @State private var sampleStart = Date().addingTimeInterval(-72)

    init(presence: DiscordPresence, scope: Binding<PlaybackService?>) {
        self.presence = presence
        _scope = scope
        let service = scope.wrappedValue
        // A service's fields start out showing the global values until they're changed.
        let global = DiscordPresenceSettings.load()
        func key(_ name: String) -> String { DiscordKey.scoped(name, service) }
        let flagService = service ?? .appleMusic
        _showForService = AppStorage(wrappedValue: true, DiscordKey.show(flagService))
        _customForService = AppStorage(wrappedValue: false, DiscordKey.customSettings(flagService))
        _detailsFormat = AppStorage(wrappedValue: global.detailsFormat, key(DiscordKey.detailsFormat))
        _stateFormat = AppStorage(wrappedValue: global.stateFormat, key(DiscordKey.stateFormat))
        _albumFormat = AppStorage(wrappedValue: global.albumFormat, key(DiscordKey.albumFormat))
        _statusSource = AppStorage(wrappedValue: global.statusSource, key(DiscordKey.statusSource))
        _showCover = AppStorage(wrappedValue: global.showCover, key(DiscordKey.showCover))
        _coverSource = AppStorage(wrappedValue: global.coverSource, key(DiscordKey.coverSource))
        _showTimestamps = AppStorage(wrappedValue: global.showTimestamps, key(DiscordKey.showTimestamps))
        _linkNames = AppStorage(wrappedValue: global.linkNames, key(DiscordKey.linkNames))
        _useScrobbleCleanup = AppStorage(wrappedValue: global.useScrobbleCleanup, key(DiscordKey.useScrobbleCleanup))
        _paused = AppStorage(wrappedValue: global.paused, key(DiscordKey.paused))
        _button1 = AppStorage(wrappedValue: global.button1, key(DiscordKey.button1))
        _button1Label = AppStorage(wrappedValue: global.button1Label, key(DiscordKey.button1Label))
        _button2 = AppStorage(wrappedValue: global.button2, key(DiscordKey.button2))
        _button2Label = AppStorage(wrappedValue: global.button2Label, key(DiscordKey.button2Label))
    }

    private var editable: Bool { scope == nil || customForService }

    private var settings: DiscordPresenceSettings {
        DiscordPresenceSettings(detailsFormat: detailsFormat, stateFormat: stateFormat, albumFormat: albumFormat,
                                statusSource: statusSource, showCover: showCover, coverSource: coverSource, showTimestamps: showTimestamps,
                                linkNames: linkNames, useScrobbleCleanup: useScrobbleCleanup, paused: paused,
                                button1: button1, button1Label: button1Label, button2: button2, button2Label: button2Label)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("Show what I'm listening to on Discord", isOn: $enabled)
                        statusLine
                    }
                    Divider()
                    scopeControls
                    Divider()
                    form.disabled(!editable)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(width: 377)
            Divider()
            preview
                .frame(width: 270)
                .padding(16)
        }
        .task { await presence.fetchAppName() }
    }

    @ViewBuilder private var scopeControls: some View {
        Picker("Settings for", selection: $scope) {
            Text("All services").tag(PlaybackService?.none)
            Divider()
            ForEach(PlaybackService.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        if let service = scope {
            Toggle("Show activity while playing from \(service.name)", isOn: $showForService)
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Use separate settings for \(service.name)", isOn: $customForService)
                    .disabled(!showForService)
                Text(customForService
                     ? "Changes below only apply to \(service.name). Anything you don't change follows All services."
                     : "\(service.name) uses the settings from All services.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        } else {
            Text("Applies to every service unless it has its own settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
                    Text("Text").font(.headline)
                    templateRow("Track line", text: $detailsFormat, presets: ["{title}", "{title} by {artist}", "{title} – {artist}"])
                    templateRow("Artist line", text: $stateFormat, presets: ["{artist}", "by {artist}", "{artist} on {service}"])
                    templateRow("Album line", text: $albumFormat, presets: ["{album}", "on {album}", "{album} by {artist}"])
                    Text("Use {title}, {artist}, {album} and {service}. A line is hidden when a token in it is empty, such as a song without an album.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("“Listening to …” shows", selection: $statusSource) {
                        ForEach(DiscordStatusSource.allCases) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Text("Display").font(.headline)
                    Toggle("Show the album cover", isOn: $showCover)
                    if showCover {
                        VStack(alignment: .leading, spacing: 5) {
                            Picker("Cover from", selection: $coverSource) {
                                ForEach(DiscordCoverSource.allCases) { Text($0.label).tag($0) }
                            }
                            .fixedSize()
                            if coverSource == .musicApp {
                                Text("Uses the artwork in Apple Music or Spotify, including custom covers. Discord can only show covers from a web link, so Apple Music artwork is uploaded to litterbox.catbox.moe, where it's public to anyone with the link and expires after 72 hours. Falls back to last.fm when a song has no artwork.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 20)
                    }
                    Toggle("Show the time bar", isOn: $showTimestamps)
                    Toggle("Link the track, artist and album to last.fm", isOn: $linkNames)
                    Toggle("Use the name cleanup options from General", isOn: $useScrobbleCleanup)
                    Picker("When paused", selection: $paused) {
                        ForEach(DiscordPausedBehavior.allCases) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Text("Buttons").font(.headline)
                    buttonRow("First button", kind: $button1, label: $button1Label)
                    buttonRow("Second button", kind: $button2, label: $button2Label)
                    Text("Discord doesn't show buttons on your own profile, only to other people. Spotify opens the exact song when it's playing in Spotify, and a Spotify search otherwise. Apple Music is left out when the song isn't in Apple's catalog, and song.link falls back to last.fm. [untitled] projects never show buttons.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(editable ? 1 : 0.5)
    }

    // MARK: Controls

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(presence.activityError ?? presence.status.description)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 20)
    }

    private var statusColor: Color {
        if presence.activityError != nil { return .orange }
        switch presence.status {
        case .connected: return .green
        case .connecting, .waitingForDiscord: return .yellow
        case .error, .notConfigured: return .red
        case .off: return .secondary
        }
    }

    private func templateRow(_ title: String, text: Binding<String>, presets: [String]) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            TextField(title, text: text, prompt: Text("Hidden"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(presets, id: \.self) { preset in Button(preset) { text.wrappedValue = preset } }
                Divider()
                Button("Hide this line") { text.wrappedValue = "" }
            } label: { Image(systemName: "text.badge.plus") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Presets")
        }
    }

    private func buttonRow(_ title: String, kind: Binding<DiscordButtonKind>, label: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: kind) {
                ForEach(DiscordButtonKind.allCases) { Text($0.menuTitle).tag($0) }
            }
            .frame(width: 230)
            TextField("Label", text: label, prompt: Text(kind.wrappedValue.defaultLabel))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .disabled(kind.wrappedValue == .none)
                .onChange(of: label.wrappedValue) { _, value in
                    if value.count > 32 { label.wrappedValue = String(value.prefix(32)) }
                }
        }
    }

    // MARK: Preview

    /// The current song when it matches the selected scope, otherwise a sample from that service.
    private var liveInfo: DiscordTrackInfo? {
        guard let info = presence.info, scope == nil || info.source == scope else { return nil }
        return info
    }

    private var previewInfo: DiscordTrackInfo {
        liveInfo ?? DiscordTrackInfo(
            track: PlayingTrack(title: "Midnight Drive", artist: "The Example Band", album: "Night Sessions", duration: 222),
            service: (scope ?? .appleMusic).name, source: scope ?? .appleMusic,
            songLinkURL: URL(string: "https://song.link/"), appleMusicURL: URL(string: "https://music.apple.com/"),
            spotifyURL: URL(string: "https://open.spotify.com/"))
    }

    private var preview: some View {
        let live = liveInfo != nil
        let playing = live ? presence.isPlaying : true
        let activity = DiscordActivity.build(info: previewInfo, settings: settings, isPlaying: playing,
                                             startedAt: live ? presence.startedAt : sampleStart)
        let appName = presence.appName ?? "scrap"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Preview").font(.headline)
            if let service = scope, !showForService {
                Text("Your activity is hidden while playing from \(service.name).")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else if let activity {
                (Text("Listening to ") + Text(activity.statusText(appName: appName)).fontWeight(.semibold))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("How your status appears in member lists")
                card(activity, appName: appName)
            } else {
                Text("Your activity is hidden while music is paused.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer(minLength: 0)
        }
    }

    private func card(_ activity: DiscordActivity, appName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Listening to \(appName)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                if let url = activity.coverURL {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { coverPlaceholder }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if showCover {
                    coverPlaceholder.frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let details = activity.details { Text(details).font(.callout.weight(.semibold)) }
                    if let state = activity.state { Text(state).font(.caption) }
                    if let album = activity.albumText { Text(album).font(.caption).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
            }
            if let start = activity.start {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timeBar(start: start, end: activity.end, now: context.date)
                }
            }
            ForEach(activity.buttons, id: \.label) { button in
                Text(button.label)
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .help(button.url.absoluteString)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
    }

    private func timeBar(start: Date, end: Date?, now: Date) -> some View {
        let elapsed = max(0, now.timeIntervalSince(start))
        let total = end.map { $0.timeIntervalSince(start) }
        let shown = total.map { min(elapsed, $0) } ?? elapsed
        return HStack(spacing: 6) {
            Text(Self.clock(shown)).font(.caption2.monospacedDigit())
            if let total {
                ProgressView(value: shown, total: max(total, 1)).progressViewStyle(.linear).controlSize(.small)
                Text(Self.clock(total)).font(.caption2.monospacedDigit())
            } else {
                Text("elapsed").font(.caption2)
                Spacer()
            }
        }
        .foregroundStyle(.secondary)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded(.down))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
