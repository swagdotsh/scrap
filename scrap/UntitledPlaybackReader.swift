import AppKit
import ApplicationServices

enum UntitledPlaybackReader {
    enum Status: Equatable {
        case needsAccess, notRunning, noPlayer, reading(PlayingTrack, isPlaying: Bool)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static var isRunning: Bool { UntitledAccessibility.runningApplication != nil }

    static let accessGrantedKey = "untitledAccessGranted"

    static func openAccessSettings() {
        requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func current() -> UntitledPlayback? {
        guard isTrusted else { return nil }
        if !UserDefaults.standard.bool(forKey: accessGrantedKey) { UserDefaults.standard.set(true, forKey: accessGrantedKey) }
        guard isRunning else { return nil }
        UntitledHelperClient.shared.refresh()
        return UntitledHelperClient.shared.latest
    }

    static func status() -> Status {
        guard isTrusted else { return .needsAccess }
        guard isRunning else { return .notRunning }
        guard let playback = current() else { return .noPlayer }
        return .reading(playback.track, isPlaying: playback.isPlaying)
    }

    static func diagnostics() async -> String {
        let header = CrashReporter.headerText().trimmingCharacters(in: .newlines)
            + "\nscrap's own Accessibility access: \(isTrusted ? "yes" : "no")"
        return await UntitledHelperClient.shared.diagnostics(header: header)
            ?? header + "\nCouldn't reach scrap's [untitled] helper."
    }
}

@MainActor
final class UntitledHelperClient {
    static let shared = UntitledHelperClient()
    private var connection: NSXPCConnection?
    private var requesting = false
    private var latestAt = Date.distantPast
    private var cached: UntitledPlayback?

    var latest: UntitledPlayback? { Date().timeIntervalSince(latestAt) < 3 ? cached : nil }

    func refresh() {
        guard !requesting, let helper = proxy(onError: { [weak self] in self?.requesting = false }) else { return }
        requesting = true
        helper.currentPlayback { data in
            let playback = data.flatMap { try? JSONDecoder().decode(UntitledPlayback.self, from: $0) }
            Task { @MainActor in
                self.cached = playback
                self.latestAt = Date()
                self.requesting = false
            }
        }
    }

    func diagnostics(header: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resumed = ResumeOnce(continuation)
            guard let helper = proxy(onError: { resumed.resume(nil) }) else {
                resumed.resume(nil)
                return
            }
            helper.diagnostics(header: header) { text in resumed.resume(text) }
        }
    }

    private func proxy(onError: @escaping @MainActor () -> Void) -> UntitledHelperProtocol? {
        let connection = connection ?? makeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            Task { @MainActor in onError() }
        }
        return proxy as? UntitledHelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: untitledHelperServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: UntitledHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.requesting = false
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func resume(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
