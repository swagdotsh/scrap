import AppKit
import Combine
import SwiftUI

@MainActor
final class DesktopControls: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var menuTrack: PlayingTrack?
    private var menuLoved: Bool?
    var openMainWindow: (() -> Void)?

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
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
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
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("removeAlbumTypeSuffix") private var removeAlbumTypeSuffix = false
    @AppStorage("usePrimaryArtist") private var usePrimaryArtist = false
    @State private var accountProfile: ListenerProfile?
    @State private var showDeleteConfirmation = false

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
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show Scrap in the Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, _ in PreferencesController.applyDockPreference() }
            Divider()
            Toggle("Remove “- Single” and “- EP” from album names", isOn: $removeAlbumTypeSuffix)
            Toggle("Use only the first artist before “&”", isOn: $usePrimaryArtist)
            Spacer()
        }
        .padding(16)
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
        VStack {
            Spacer()
            Text("Coming soon ;)").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var updatesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Version \(updateChecker.currentVersion)")
                Spacer()
                Button(updateChecker.isChecking ? "Checking…" : "Check for Updates") {
                    Task { await updateChecker.checkForUpdates() }
                }
                .disabled(updateChecker.isChecking)
            }
            if !updateChecker.status.isEmpty {
                HStack {
                    Text(updateChecker.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let release = updateChecker.availableRelease {
                        Link("View Release", destination: release.htmlURL)
                    }
                }
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
