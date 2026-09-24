import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class DesktopControls: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var menuTrack: PlayingTrack?
    private var menuLoved: Bool?
    private var mainWindow: NSWindow?
    private let tagController = TagWindowController()

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Scrap")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(listener: model.listener, engine: model.engine, client: model.client, updateChecker: model.updateChecker, isMenuBar: true))
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            menu.autoenablesItems = false
            add("Open scrap", action: #selector(openScrap), to: menu)
            add(model.client.scrobblingPaused ? "Resume scrobbling" : "Pause scrobbling", action: #selector(toggleScrobbling), to: menu)
            menu.addItem(.separator())
            menuTrack = model.listener.track
            menuLoved = nil
            addInfo("Now playing", to: menu)
            if let track = menuTrack {
                addInfo(track.title, to: menu)
                addInfo(track.album.isEmpty ? track.artist : "\(track.artist) · \(track.album)", to: menu)
            } else {
                addInfo("Nothing playing", to: menu)
            }
            menu.addItem(.separator())
            let loveItem = NSMenuItem(title: "Checking loved status…", action: #selector(loveTrack), keyEquivalent: "")
            loveItem.target = self
            loveItem.isEnabled = false
            menu.addItem(loveItem)
            if let track = menuTrack, model.client.canScrobble {
                Task { @MainActor in
                    do {
                        let loved = try await model.client.isLoved(track)
                        guard menuTrack == track else { return }
                        menuLoved = loved
                        loveItem.title = loved ? "Unlove track" : "Love track"
                        loveItem.isEnabled = true
                    } catch { loveItem.title = "Loved status unavailable" }
                }
            } else { loveItem.title = "Love track" }
            add("Tag…", action: #selector(tagTrack), to: menu, enabled: menuTrack != nil && model.client.canScrobble)
            add("Share", action: #selector(shareTrack), to: menu, enabled: menuTrack != nil)
            add("View on last.fm", action: #selector(viewTrack), to: menu, enabled: menuTrack != nil)
            menu.addItem(.separator())
            add("Quit scrap", action: #selector(quit), to: menu)
            item.menu = menu
            button.performClick(nil)
            item.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
    }

    private func addInfo(_ title: String, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        menu.addItem(entry)
    }

    @objc private func openScrap() {
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }
    func showMainWindow() {
        popover.performClose(nil)
        if let mainWindow {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 350), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("scrap-main-window")
            window.title = "Scrap"
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ContentView(listener: model.listener, engine: model.engine, client: model.client, updateChecker: model.updateChecker))
            window.styleMask.remove(.resizable)
            window.collectionBehavior = [.fullScreenNone]
            window.tabbingMode = .disallowed
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.contentMinSize = NSSize(width: 680, height: 350)
            window.contentMaxSize = NSSize(width: 680, height: 350)
            mainWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func tagTrack() {
        guard let track = menuTrack, model.client.canScrobble else { return }
        tagController.show(track: track, client: model.client)
    }

    @objc private func toggleScrobbling() {
        model.engine.suspendTiming()
        model.client.scrobblingPaused.toggle()
        model.listener.refresh()
        if !model.client.scrobblingPaused { Task { await model.client.retryPending() } }
    }
    @objc private func loveTrack() {
        guard let track = menuTrack, let loved = menuLoved else { return }
        Task { await model.client.love(track, loved: !loved) }
    }
    @objc private func viewTrack() {
        guard let track = menuTrack else { return }
        NSWorkspace.shared.open(track.trackURL)
    }
    @objc private func shareTrack() {
        guard let track = menuTrack else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(track.trackURL.absoluteString, forType: .string)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

private enum PreferencesTab: Int {
    case general, accounts, services, updates
}

@MainActor
final class PreferencesController: NSObject, ObservableObject, NSToolbarDelegate {
    static let shared = PreferencesController()
    @Published fileprivate var selectedTab: PreferencesTab = .general
    private var window: NSWindow?
    private let tabsIdentifier = NSToolbarItem.Identifier("preferences-tabs")

    func show(client: LastFMClient, updateChecker: UpdateChecker) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Preferences"
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PreferencesView(client: client, updateChecker: updateChecker, controller: self))
            let toolbar = NSToolbar(identifier: "preferences-toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [tabsIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [tabsIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == tabsIdentifier else { return nil }
        let control = NSSegmentedControl(labels: ["General", "last.fm Accounts", "Services", "Updates"], trackingMode: .selectOne, target: self, action: #selector(selectTab(_:)))
        control.selectedSegment = selectedTab.rawValue
        control.sizeToFit()
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = control
        item.label = "Preferences sections"
        return item
    }

    @objc private func selectTab(_ sender: NSSegmentedControl) {
        guard let tab = PreferencesTab(rawValue: sender.selectedSegment) else { return }
        selectedTab = tab
    }

    static func applyDockPreference() {
        let visible = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

private struct PreferencesView: View {
    @ObservedObject var client: LastFMClient
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var controller: PreferencesController
    @StateObject private var loginItem = LoginItemSettings()
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("menuBarBackgroundOpacity") private var menuBarBackgroundOpacity = 0.95
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("removeAlbumTypeSuffix") private var removeAlbumTypeSuffix = false
    @AppStorage("usePrimaryArtist") private var usePrimaryArtist = false
    @AppStorage("scrobbleAppleMusic") private var scrobbleAppleMusic = true
    @AppStorage("scrobbleSpotify") private var scrobbleSpotify = false
    @AppStorage("scrobbleUntitled") private var scrobbleUntitled = false
    @State private var accountProfile: ListenerProfile?
    @State private var showDeleteConfirmation = false
    @State private var showUntitledAccessibilityAlert = false

    var body: some View {
        Group {
            switch controller.selectedTab {
            case .general: generalTab
            case .accounts: accountsTab
            case .services: servicesTab
            case .updates: updatesTab
            }
        }
        .frame(width: 680, height: 330)
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Show Scrap in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in PreferencesController.applyDockPreference() }
                Toggle("Open Scrap on logon", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    HStack {
                        Text("Allow Scrap in macOS Login Items to finish enabling this.").font(.caption)
                        Button("Open Login Items") { loginItem.openSettings() }
                    }
                }
                if let error = loginItem.error { Text(error).font(.caption).foregroundStyle(.red) }
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, _ in AppAppearance.applySaved() }
                HStack {
                    Text("Menu bar background")
                    Slider(value: $menuBarBackgroundOpacity, in: 0.5...1)
                    Text(menuBarBackgroundOpacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 40)
                }
                .help("Higher opacity improves text readability. 100% gives a solid background.")
                Divider()
                Toggle("Remove “- Single” and “- EP” from album names", isOn: $removeAlbumTypeSuffix)
                Toggle("Use only the first artist before “&”", isOn: $usePrimaryArtist)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
    }

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AsyncImage(url: accountProfile?.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable().foregroundStyle(.secondary)
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(client.username ?? "No Last.fm account connected")
                        .font(.headline)
                    Text(client.connectionHelp)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack {
                Button(client.sessionKey == nil ? "Connect Last.fm" : "Reconnect Last.fm") {
                    Task { await client.beginAuth() }
                }
                .disabled(!client.isConfigured || client.isBusy || client.isSending)
                if client.pendingToken != nil {
                    Button("I've approved it") { Task { await client.completeAuth() } }
                        .disabled(client.isBusy)
                }
                Button("Refresh Profile") { Task { await refreshProfile() } }
                    .disabled(client.username == nil || client.isBusy)
            }
            Divider()
            HStack {
                Button("Sign Out") { client.signOut() }
                    .disabled(client.sessionKey == nil || client.isBusy || client.isSending)
                Button("Remove Last.fm Keychain Data") { showDeleteConfirmation = true }
                    .disabled((client.sessionKey == nil && client.username == nil) || client.isBusy || client.isSending)
            }
            Text(client.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .task(id: client.username) { await refreshProfile() }
        .confirmationDialog("Remove saved Last.fm account?", isPresented: $showDeleteConfirmation) {
            Button("Remove from Keychain", role: .destructive) { client.signOut() }
        } message: {
            Text("This removes the saved session key and username from your Mac's Keychain and signs you out of Scrap.")
        }
    }

    private var servicesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scrobble music from...")
                .font(.headline)
            Toggle("Apple Music", isOn: $scrobbleAppleMusic)
            Toggle("Spotify", isOn: $scrobbleSpotify)
            HStack(spacing: 8) {
                Toggle("[untitled]", isOn: $scrobbleUntitled)
                    .fixedSize(horizontal: true, vertical: false)
                    .onChange(of: scrobbleUntitled) { _, enabled in
                        if enabled && !AXIsProcessTrusted() { showUntitledAccessibilityAlert = true }
                    }
                Text("Experimental")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Text("[untitled] needs Accessibility access. Project names are used as album names.")
                .font(.caption).foregroundStyle(.secondary)
            Text("If Spotify is already connected to Last.fm, enabling it here may create duplicate scrobbles.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .alert("Allow Accessibility for [untitled]", isPresented: $showUntitledAccessibilityAlert) {
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Scrap needs Accessibility access to read [untitled] playback. In System Settings, add & turn on Scrap under Privacy & Security -> Device Control and Data Access.")
        }
    }

    private var updatesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Version \(updateChecker.currentVersion)")
                Spacer()
                Button("Check for Updates…") { updateChecker.checkForUpdates() }
                    .disabled(!updateChecker.canCheckForUpdates)
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updateChecker.automaticallyChecksForUpdates },
                set: { updateChecker.setAutomaticChecks($0) }
            ))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { updateChecker.automaticallyDownloadsUpdates },
                set: { updateChecker.setAutomaticDownloads($0) }
            ))
            .disabled(!updateChecker.automaticallyChecksForUpdates)
            Text("Scrap checks daily. Updates can be downloaded and installed here without visiting GitHub. With automatic installation enabled, updates install when you quit; Scrap may also offer to restart to finish an update.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let date = updateChecker.lastCheckDate {
                Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !updateChecker.status.isEmpty {
                Text(updateChecker.status).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(16)
    }

    private func refreshProfile() async {
        guard let username = client.username else { accountProfile = nil; return }
        let profile = try? await client.profile()
        guard !Task.isCancelled, client.username == username else { return }
        accountProfile = profile
    }
}
