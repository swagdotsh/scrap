import CryptoKit
import Foundation
import UIKit

enum WidgetArtistImages {
    private static let lifetime: TimeInterval = 24 * 60 * 60
    private static let pausedUntilKey = "spotifySearchPausedUntil"

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.swagrelated.scrap")?
            .appendingPathComponent("Library/Caches/ArtistImages", isDirectory: true)
    }

    static func portrait(_ name: String, width: CGFloat) async -> UIImage? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, let directory else { return nil }
        let imageFile = directory.appendingPathComponent("\(hash(key)).image")
        let noImageFile = directory.appendingPathComponent("\(hash(key)).none")
        if isFresh(imageFile), let data = try? Data(contentsOf: imageFile), let image = UIImage(data: data) {
            return thumbnail(image, width: width)
        }
        if isFresh(noImageFile) { return nil }

        guard let data = await spotifyImage(for: name.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if data.isEmpty {
            try? FileManager.default.removeItem(at: imageFile)
            try? Data().write(to: noImageFile, options: .atomic)
            return nil
        }
        guard let image = UIImage(data: data) else { return nil }
        try? FileManager.default.removeItem(at: noImageFile)
        try? data.write(to: imageFile, options: .atomic)
        return thumbnail(image, width: width)
    }

    private static func isFresh(_ url: URL) -> Bool {
        guard let saved = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        let age = Date().timeIntervalSince(saved)
        return age >= -60 && age < lifetime
    }

    private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func thumbnail(_ image: UIImage, width: CGFloat) -> UIImage {
        guard image.size.width > 0 else { return image }
        let size = CGSize(width: width, height: width * image.size.height / image.size.width)
        return image.preparingThumbnail(of: size) ?? image
    }

    private static func spotifyImage(for name: String) async -> Data? {
        let defaults = WidgetLastFM.defaults
        guard let clientID = defaults?.string(forKey: "spotifyClientID"), !clientID.isEmpty,
              let clientSecret = defaults?.string(forKey: "spotifyClientSecret"), !clientSecret.isEmpty else { return nil }
        if let pausedUntil = defaults?.object(forKey: pausedUntilKey) as? Date, pausedUntil > Date() { return nil }

        var tokenRequest = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.timeoutInterval = 12
        tokenRequest.setValue("Basic \(Data("\(clientID):\(clientSecret)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = Data("grant_type=client_credentials".utf8)
        guard let (tokenData, tokenResponse) = try? await URLSession.shared.data(for: tokenRequest),
              (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
              let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let token = tokenJSON["access_token"] as? String else { return nil }

        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "type", value: "artist"),
                                 URLQueryItem(name: "limit", value: "10")]
        var search = URLRequest(url: components.url!)
        search.timeoutInterval = 12
        search.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: search),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 429 {
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 30
            defaults?.set(Date().addingTimeInterval(min(max(wait, 1), lifetime)), forKey: pausedUntilKey)
            return nil
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["artists"] as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        guard let artist = items.first(where: {
            ($0["name"] as? String)?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return Data() }
        let images = (artist["images"] as? [[String: Any]] ?? []).compactMap { image -> (url: URL, width: Int)? in
            guard let raw = image["url"] as? String, let url = URL(string: raw), url.scheme == "https" else { return nil }
            return (url, image["width"] as? Int ?? 0)
        }.sorted { $0.width < $1.width }
        guard let best = images.first(where: { $0.width >= 320 }) ?? images.last else { return Data() }
        guard let (imageData, imageResponse) = try? await URLSession.shared.data(from: best.url),
              (imageResponse as? HTTPURLResponse)?.statusCode == 200, !imageData.isEmpty else { return nil }
        return imageData
    }
}
