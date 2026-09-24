import AppKit
import SwiftUI

enum TagTarget: String, CaseIterable {
    case track = "Song", artist = "Artist"
    var methodPrefix: String { self == .track ? "track" : "artist" }

    func parameters(for track: PlayingTrack) -> [String: String] {
        var parameters = ["artist": track.artist]
        if self == .track { parameters["track"] = track.title }
        return parameters
    }
}

extension LastFMClient {
    static func parseTags(_ input: String) throws -> [String] {
        var seen = Set<String>()
        let tags = input.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !tags.isEmpty, tags.count <= 10 else {
            throw NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: "Enter between 1 and 10 tags, separated by commas."])
        }
        return tags
    }

    func tags(for track: PlayingTrack, target: TagTarget, personal: Bool) async throws -> [String] {
        var parameters = target.parameters(for: track)
        parameters["method"] = "\(target.methodPrefix).\(personal ? "getTags" : "getTopTags")"
        if personal {
            guard let username else { throw NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: "Connect Last.fm to view your tags."]) }
            parameters["user"] = username
        }
        let json = try await request(parameters)
        guard let container = json[personal ? "tags" : "toptags"] as? [String: Any] else {
            throw NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: "Last.fm returned an unexpected tags response."])
        }
        let entries = container["tag"] as? [[String: Any]] ?? (container["tag"] as? [String: Any]).map { [$0] } ?? []
        return entries.compactMap { $0["name"] as? String }
    }

    func addTags(_ input: String, to track: PlayingTrack, target: TagTarget) async throws {
        let tags = try Self.parseTags(input)
        guard canScrobble, let sessionKey else {
            throw NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: "Connect Last.fm before applying tags."])
        }
        var parameters = target.parameters(for: track)
        parameters["method"] = "\(target.methodPrefix).addTags"
        parameters["tags"] = tags.joined(separator: ",")
        parameters["sk"] = sessionKey
        _ = try await request(parameters, post: true)
    }
}

@MainActor
final class TagWindowController {
    private var window: NSWindow?

    func show(track: PlayingTrack, client: LastFMClient) {
        // Keep an existing editor (and any in-flight submission) intact.
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tag on Last.fm"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: TagEditor(track: track, client: client, close: { [weak window] in window?.close() }))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TagEditor: View {
    let track: PlayingTrack
    @ObservedObject var client: LastFMClient
    let close: () -> Void
    @State private var target: TagTarget = .track
    @State private var input = ""
    @State private var personalTags: [String] = []
    @State private var communityTags: [String] = []
    @State private var loading = true
    @State private var saving = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var refreshID = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            (Text("Tagging ") + Text(target == .track ? "\(track.title) by \(track.artist)" : track.artist).bold())
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            Picker("Tag", selection: $target) {
                ForEach(TagTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(saving)
            if loading { ProgressView("Loading current tags…").controlSize(.small) }
            else if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
                Button("Retry loading tags") { refreshID += 1 }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your tags: \(personalTags.isEmpty ? "None yet" : personalTags.joined(separator: ", "))")
                        Text("Community tags: \(communityTags.isEmpty ? "None yet" : communityTags.joined(separator: ", "))")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 80, maxHeight: 110)
            }
            TextField("Add tags, separated by commas", text: $input)
                .textFieldStyle(.roundedBorder).focused($inputFocused).disabled(saving)
            Text("Add up to 10 tags. Existing tags are kept.").font(.caption).foregroundStyle(.secondary)
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (try? LastFMClient.parseTags(input)) == nil {
                Text("Enter between 1 and 10 tags, separated by commas.").font(.caption).foregroundStyle(.red)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Applying…" : "Apply tags") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !client.canScrobble || (try? LastFMClient.parseTags(input)) == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
        .frame(minHeight: 360)
        .onAppear { inputFocused = true }
        .task(id: "\(target.rawValue)-\(client.username ?? "")-\(refreshID)") { await loadTags() }
    }

    private func loadTags() async {
        loading = true
        loadError = nil
        do {
            async let personal = client.tags(for: track, target: target, personal: true)
            async let community = client.tags(for: track, target: target, personal: false)
            let result = try await (personal, community)
            guard !Task.isCancelled else { return }
            personalTags = result.0
            communityTags = Array(result.1.prefix(10))
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func apply() {
        saving = true
        saveError = nil
        Task {
            do {
                try await client.addTags(input, to: track, target: target)
                close()
            } catch { saveError = error.localizedDescription }
            saving = false
        }
    }
}
