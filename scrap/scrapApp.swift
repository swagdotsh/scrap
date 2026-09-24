import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    let listener = NowPlayingListener()
    let engine = ScrobbleEngine()
    let client = LastFMClient()
    let updateChecker = UpdateChecker()
    lazy var desktop = DesktopControls(model: self)
    private var friendsTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        engine.onNowPlaying = { [weak self] in self?.client.updateNowPlaying($0) }
        engine.onScrobble = { [weak self] in self?.client.scrobble($0, startedAt: $1) }
        listener.onUpdate = { [weak self] track, playing, restarted in
            guard let self else { return }
            self.engine.update(track: self.client.canScrobble ? track : nil, isPlaying: playing && !self.client.scrobblingPaused, restarted: restarted)
        }
        client.$sessionKey.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.listener.refresh()
                await self?.client.checkConnection()
            }
        }.store(in: &subscriptions)
        listener.start()
        Task { await client.checkConnection(); await client.retryPending(); await client.refreshFriends() }
        friendsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.client.checkConnection(); await self?.client.refreshFriends() }
        }
    }
}

@main
struct scrapApp: App {
    @NSApplicationDelegateAdaptor(ScrapAppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") { PreferencesController.shared.show(client: model.client, updateChecker: model.updateChecker) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("scrap website", destination: URL(string: "https://scrap.swagrelated.com")!)
                Link("GitHub repository", destination: URL(string: "https://github.com/swagdotsh/scrap")!)
                Link("Report an issue", destination: URL(string: "https://github.com/swagdotsh/scrap/issues/new/choose")!)
            }
        }

    }
}

@MainActor
final class ScrapAppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = model.desktop
        PreferencesController.applyDockPreference()
        AppAppearance.applySaved()
        model.updateChecker.start()
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        if !loginLaunch { model.desktop.showMainWindow() }
        DispatchQueue.main.async {
            guard let menu = NSApplication.shared.mainMenu else { return }
            NSApp.windowsMenu = nil
            for title in ["File", "Edit", "View", "Window"] {
                if let item = menu.items.first(where: { $0.title == title }) {
                    menu.removeItem(item)
                }
            }
            let windowMenu = NSMenu(title: "Window")
            windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
            windowItem.submenu = windowMenu
            let helpIndex = menu.items.firstIndex(where: { $0.submenu === NSApp.helpMenu }) ?? menu.items.count
            menu.insertItem(windowItem, at: helpIndex)
            if let appMenu = menu.items.first?.submenu,
               let servicesItem = appMenu.items.first(where: { $0.title == "Services" }) {
                appMenu.removeItem(servicesItem)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.desktop.showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
