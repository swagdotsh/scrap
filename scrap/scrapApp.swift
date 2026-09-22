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
    private var updateTimer: Timer?
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
        Task { await updateChecker.checkAutomatically() }
        friendsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.client.checkConnection(); await self?.client.refreshFriends() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.updateChecker.checkAutomatically() }
        }
    }
}

@main
struct scrapApp: App {
    @NSApplicationDelegateAdaptor(ScrapAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Scrap", id: "scrap-main-window") {
            MainWindowContent(model: model)
        }
        .defaultSize(width: 680, height: 350)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") { PreferencesController.shared.show(client: model.client, updateChecker: model.updateChecker) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    var body: some View {
        ContentView(listener: model.listener, engine: model.engine, client: model.client, updateChecker: model.updateChecker)
            .background(HiddenWindowTitle())
            .onAppear {
                model.desktop.openMainWindow = { openWindow(id: "scrap-main-window") }
                PreferencesController.applyDockPreference()
            }
    }
}

private struct HiddenWindowTitle: NSViewRepresentable {
    final class TitleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ nsView: TitleView, context: Context) {
        nsView.window?.titleVisibility = .hidden
    }
}

@MainActor
final class ScrapAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let menu = NSApplication.shared.mainMenu else { return }
            for title in ["File", "Edit", "View"] {
                if let item = menu.items.first(where: { $0.title == title }) {
                    menu.removeItem(item)
                }
            }
            if let appMenu = menu.items.first?.submenu,
               let servicesItem = appMenu.items.first(where: { $0.title == "Services" }) {
                appMenu.removeItem(servicesItem)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
