import AppKit
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
        popover.contentViewController = NSHostingController(rootView: ContentView(listener: model.listener, engine: model.engine, client: model.client, isMenuBar: true))
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
            add("View on last.fm", action: #selector(viewTrack), to: menu, enabled: model.listener.track != nil)
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
        guard let track = model.listener.track else { return }
        NSWorkspace.shared.open(track.trackURL)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@MainActor
final class PreferencesController {
    static let shared = PreferencesController()
    private var window: NSWindow?

    func show(client: LastFMClient) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Preferences"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PreferencesView(client: client))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func applyDockPreference() {
        let visible = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

private struct PreferencesView: View {
    @ObservedObject var client: LastFMClient
    @AppStorage("showInDock") private var showInDock = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show Scrap in the Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, _ in PreferencesController.applyDockPreference() }
            Button("Sign out") { client.signOut() }
                .disabled(client.sessionKey == nil || client.isBusy || client.isSending)
            Text(client.status).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 330)

    }
}
