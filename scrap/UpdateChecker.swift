import AppKit
import Combine
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    @Published private(set) var availableRelease: Release?
    @Published private(set) var status = ""
    @Published private(set) var isChecking = false

    private let lastCheckKey = "lastUpdateCheck"
    private let lastAttemptKey = "lastUpdateCheckAttempt"
    private let lastPromptedKey = "lastPromptedUpdate"
    private let endpoint = URL(string: "https://api.github.com/repos/swagdotsh/scrap/releases/latest")!
    private var hasPromptedThisRun = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func checkAutomatically() async {
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= 24 * 60 * 60 else { return }
        let lastAttempt = UserDefaults.standard.object(forKey: lastAttemptKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastAttempt) >= 60 * 60 else { return }
        await checkForUpdates(showPrompt: true)
    }

    func checkForUpdates(showPrompt: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        UserDefaults.standard.set(Date(), forKey: lastAttemptKey)

        do {
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("scrap-update-checker", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let remoteVersion = Self.versionComponents(release.tagName),
                  let installedVersion = Self.versionComponents(currentVersion) else {
                throw UpdateError.invalidVersion
            }

            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            if Self.isNewer(remoteVersion, than: installedVersion) {
                availableRelease = release
                status = "Version \(release.tagName) is available."
                if showPrompt { promptForUpdate(release) }
            } else {
                availableRelease = nil
                status = "You're up to date (version \(currentVersion))."
            }
        } catch {
            status = "Couldn't check for updates. Try again later."
        }
    }

    static func versionComponents(_ version: String) -> [Int]? {
        let value = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    static func isNewer(_ candidate: [Int], than installed: [Int]) -> Bool {
        for index in 0..<max(candidate.count, installed.count) {
            let next = index < candidate.count ? candidate[index] : 0
            let current = index < installed.count ? installed[index] : 0
            if next != current { return next > current }
        }
        return false
    }

    private func promptForUpdate(_ release: Release) {
        guard !hasPromptedThisRun,
              UserDefaults.standard.string(forKey: lastPromptedKey) != release.tagName else { return }
        hasPromptedThisRun = true
        UserDefaults.standard.set(release.tagName, forKey: lastPromptedKey)

        let alert = NSAlert()
        alert.messageText = "A new version of scrap is available"
        alert.informativeText = "Version \(release.tagName) is available. You're using \(currentVersion)."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private enum UpdateError: Error {
        case invalidVersion
    }
}
