import SwiftUI
import CryptoKit

@MainActor
final class ArtistPortraitStore {
    static let shared = ArtistPortraitStore()
    private struct Entry { let image: NSImage?; let expires: Date }
    private var memory: [String: Entry] = [:]
    private var pending: [String: Task<NSImage?, Never>] = [:]
    private let disk: ArtistImageDiskCache
    private let spotify: SpotifyArtistImages

    init(disk: ArtistImageDiskCache = ArtistImageDiskCache(), spotify: SpotifyArtistImages? = nil) {
        self.disk = disk
        if let spotify {
            self.spotify = spotify
        } else {
            let configuration = AppConfiguration.load()
            self.spotify = SpotifyArtistImages(clientID: configuration.spotifyClientID,
                                               clientSecret: configuration.spotifyClientSecret)
        }
    }

    func portrait(for name: String) async -> NSImage? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = name.lowercased()
        guard !key.isEmpty else { return nil }
        if let entry = memory[key], entry.expires > Date() { return entry.image }
        if let task = pending[key] { return await task.value }
        let task = Task<NSImage?, Never> { await self.load(name: name, key: key) }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        return image
    }

    private func load(name: String, key: String) async -> NSImage? {
        switch await disk.read(key) {
        case .image(let data, let expires):
            if let image = NSImage(data: data) {
                memory[key] = Entry(image: image, expires: expires)
                return image
            }
        case .noImage(let expires):
            memory[key] = Entry(image: nil, expires: expires)
            return nil
        case nil:
            break
        }

        switch await spotify.imageData(for: name) {
        case .found(let data):
            guard let image = NSImage(data: data) else { break }
            await disk.store(data, for: key)
            memory[key] = Entry(image: image, expires: Date().addingTimeInterval(ArtistImageDiskCache.lifetime))
            return image
        case .noImage:
            await disk.store(nil, for: key)
            memory[key] = Entry(image: nil, expires: Date().addingTimeInterval(ArtistImageDiskCache.lifetime))
            return nil
        case .unavailable:
            break
        }
        memory[key] = Entry(image: nil, expires: Date().addingTimeInterval(300))
        return nil
    }
}

actor ArtistImageDiskCache {
    nonisolated static let lifetime: TimeInterval = 24 * 60 * 60

    nonisolated enum Lookup: Sendable {
        case image(Data, expires: Date)
        case noImage(expires: Date)
    }

    private let directory: URL
    private var pruned = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtistImages", isDirectory: true)
    }

    func read(_ key: String, now: Date = Date()) -> Lookup? {
        pruneExpired(now: now)
        if let saved = savedDate(file(key, "image"), now: now),
           let data = try? Data(contentsOf: file(key, "image")), !data.isEmpty {
            return .image(data, expires: saved.addingTimeInterval(Self.lifetime))
        }
        if let saved = savedDate(file(key, "none"), now: now) {
            return .noImage(expires: saved.addingTimeInterval(Self.lifetime))
        }
        return nil
    }

    func store(_ data: Data?, for key: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let (kept, replaced) = data == nil ? ("none", "image") : ("image", "none")
        try? fileManager.removeItem(at: file(key, replaced))
        try? (data ?? Data()).write(to: file(key, kept), options: .atomic)
    }

    private func savedDate(_ url: URL, now: Date) -> Date? {
        guard let saved = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        let age = now.timeIntervalSince(saved)
        guard age >= -60, age < Self.lifetime else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return saved
    }

    private func pruneExpired(now: Date) {
        guard !pruned else { return }
        pruned = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files { _ = savedDate(url, now: now) }
    }

    private func file(_ key: String, _ kind: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).\(kind)")
    }
}

actor SpotifyArtistImages {
    nonisolated enum Result: Sendable { case found(Data), noImage, unavailable }

    private let clientID: String
    private let clientSecret: String
    private let session: URLSession
    private var token: (value: String, expires: Date)?
    private var tokenTask: Task<String?, Never>?
    private var nextRequest: Date
    nonisolated static let pausedUntilKey = "spotifySearchPausedUntil"

    init(clientID: String, clientSecret: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
        nextRequest = UserDefaults.standard.object(forKey: Self.pausedUntilKey) as? Date ?? .distantPast
    }

    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    func imageData(for name: String) async -> Result {
        guard isConfigured, !isPaused else { return .unavailable }
        var lookup = await imageURL(for: name)
        if case .expiredToken = lookup {
            token = nil
            lookup = await imageURL(for: name)
        }
        switch lookup {
        case .noImage: return .noImage
        case .expiredToken, .failed: return .unavailable
        case .found(let url):
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return .unavailable }
            return .found(data)
        }
    }

    nonisolated private enum Lookup { case found(URL), noImage, expiredToken, failed }

    private func imageURL(for name: String) async -> Lookup {
        guard let accessToken = await accessToken() else { return .failed }
        guard await waitForTurn() else { return .failed }
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "type", value: "artist"),
                                 URLQueryItem(name: "limit", value: "10")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200: break
        case 401: return .expiredToken
        case 429:
            let wait = (http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)) ?? 30
            let until = Date().addingTimeInterval(min(max(wait, 1), ArtistImageDiskCache.lifetime))
            nextRequest = max(nextRequest, until)
            UserDefaults.standard.set(nextRequest, forKey: Self.pausedUntilKey)
            return .failed
        default: return .failed
        }
        guard let results = try? JSONDecoder().decode(SpotifyArtistSearchResponse.self, from: data) else { return .failed }
        guard let url = results.imageURL(for: name) else { return .noImage }
        return .found(url)
    }

    private func waitForTurn() async -> Bool {
        guard !isPaused else { return false }
        let delay = max(0, nextRequest.timeIntervalSinceNow)
        nextRequest = Date().addingTimeInterval(delay + 1)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return !isPaused
    }

    private var isPaused: Bool { nextRequest.timeIntervalSinceNow > 60 }

    private func accessToken() async -> String? {
        if let token, token.expires > Date() { return token.value }
        if let tokenTask { return await tokenTask.value }
        let task = Task { await self.requestToken() }
        tokenTask = task
        let value = await task.value
        tokenTask = nil
        return value
    }

    private func requestToken() async -> String? {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(SpotifyToken.self, from: data),
              !result.access_token.isEmpty else { return nil }
        token = (result.access_token, Date().addingTimeInterval(TimeInterval(max(result.expires_in - 60, 60))))
        return result.access_token
    }
}

nonisolated struct SpotifyToken: Decodable {
    let access_token: String
    let expires_in: Int
}

nonisolated struct SpotifyArtistSearchResponse: Decodable {
    nonisolated struct Page: Decodable { let items: [Artist] }
    nonisolated struct Artist: Decodable { let name: String; let images: [Image]? }
    nonisolated struct Image: Decodable { let url: String; let width: Int?; let height: Int? }
    let artists: Page

    func imageURL(for name: String) -> URL? {
        guard let artist = artists.items.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return nil }
        let images = (artist.images ?? []).filter { URL(string: $0.url)?.scheme == "https" }
        let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        guard let image = sorted.first(where: { ($0.width ?? 0) >= 320 }) ?? sorted.last else { return nil }
        return URL(string: image.url)
    }
}

struct ArtistPortrait: View {
    let name: String
    var size: CGFloat = 64
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay(Image(systemName: "person.crop.circle").font(.system(size: size * 0.4)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Portrait of \(name)")
        .task(id: name) {
            image = nil
            let result = await ArtistPortraitStore.shared.portrait(for: name)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
