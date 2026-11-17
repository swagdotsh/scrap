import AppKit
import SwiftUI

enum UntitledAccessNotice {
    static let lastBuildKey = "lastLaunchedBuild"
    static let pendingKey = "untitledAccessNoticePending"
    static let ignoredKey = "untitledAccessNoticeIgnored"

    struct Decision: Equatable {
        let show: Bool
        let pending: Bool
    }

    static func decide(previousBuild: String?, currentBuild: String, enabled: Bool, wasGranted: Bool?,
                       trusted: Bool, pending: Bool, ignoredForever: Bool) -> Decision {
        guard enabled, !trusted else { return Decision(show: false, pending: false) }
        let pending = pending || (previousBuild != currentBuild && (wasGranted ?? true))
        return Decision(show: pending && !ignoredForever, pending: pending)
    }

    static func checkAfterLaunch(defaults: UserDefaults = .standard) {
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let previousBuild = defaults.string(forKey: lastBuildKey)
        defaults.set(currentBuild, forKey: lastBuildKey)
        let decision = decide(previousBuild: previousBuild, currentBuild: currentBuild,
                              enabled: defaults.bool(forKey: "scrobbleUntitled"),
                              wasGranted: defaults.object(forKey: UntitledPlaybackReader.accessGrantedKey) as? Bool,
                              trusted: UntitledPlaybackReader.isTrusted,
                              pending: defaults.bool(forKey: pendingKey),
                              ignoredForever: defaults.bool(forKey: ignoredKey))
        defaults.set(decision.pending, forKey: pendingKey)
        if decision.show || forcedForTesting { UntitledAccessWindow.shared.show() }
    }

    static func ignoreForever(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: ignoredKey)
    }

    static func resolved(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: pendingKey)
    }

    private static var forcedForTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SCRAP_TEST_UNTITLED_NOTICE"] == "1"
        #else
        false
        #endif
    }
}

@MainActor
final class UntitledAccessWindow {
    static let shared = UntitledAccessWindow()
    private var window: NSWindow?

    func show() {
        let view = UntitledAccessView { [weak self] in self?.window?.close() }
        let window = window ?? NSWindow(contentViewController: NSHostingController(rootView: view))
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Turn [untitled] back on"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct UntitledAccessView: View {
    let dismiss: () -> Void
    @State private var trusted = UntitledPlaybackReader.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "hand.raised.fill")
                    .font(.system(size: 28)).foregroundStyle(trusted ? .green : .orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trusted ? "You're all set" : "scrap was updated, so [untitled] needs permission again")
                        .font(.title3.bold())
                    Text(trusted ? "scrap can read [untitled] again." : "macOS forgets scrap's Accessibility permission after each update, so [untitled] can't be scrobbled until you allow it again.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !trusted {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click Add scrap in Settings… below. System Settings and a Finder window with scrap open.")
                    step(2, "In System Settings, select the old scrap entry and remove it with −.")
                    step(3, "Drag scrap from the Finder window into the list, then switch it on.")
                }
            }
            HStack {
                if trusted {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Ignore Forever") {
                        UntitledAccessNotice.ignoreForever()
                        dismiss()
                    }
                    Spacer()
                    Button("Ignore Until Next Launch") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Add scrap in Settings…") { UntitledPlaybackReader.openAccessSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            while !Task.isCancelled && !trusted {
                try? await Task.sleep(for: .seconds(2))
                trusted = UntitledPlaybackReader.isTrusted
            }
            if trusted { UntitledAccessNotice.resolved() }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").font(.callout.monospacedDigit().bold())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
