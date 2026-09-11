import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    let listener = NowPlayingListener()
    let engine = ScrobbleEngine()
    let client = LastFMClient()
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
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Scrap", id: "scrap-main-window") {
            MainWindowContent(model: model)
        }
        .defaultSize(width: 680, height: 350)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") { PreferencesController.shared.show(client: model.client) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    var body: some View {
        ContentView(listener: model.listener, engine: model.engine, client: model.client)
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
