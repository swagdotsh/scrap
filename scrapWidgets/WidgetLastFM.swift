import Foundation
import UIKit

enum WidgetLastFM {
    static let defaults = UserDefaults(suiteName: "group.com.swagrelated.scrap")

    struct Credentials {
        let username: String
        let apiKey: String
    }

    static var credentials: Credentials? {
        guard let username = defaults?.string(forKey: "username"), !username.isEmpty,
              let apiKey = defaults?.string(forKey: "apiKey"), !apiKey.isEmpty else { return nil }
        return Credentials(username: username, apiKey: apiKey)
    }

    static func request(_ params: [String: String], credentials: Credentials) async throws -> [String: Any] {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        let query = params.merging(["api_key": credentials.apiKey, "format": "json"]) { $1 }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if json["error"] != nil {
            throw NSError(domain: "LastFM", code: 0, userInfo: [NSLocalizedDescriptionKey: json["message"] as? String ?? "last.fm error"])
        }
        return json
    }

    static func imageURL(_ value: Any?, size: String = "large") -> URL? {
        let images = value as? [[String: Any]] ?? []
        guard let raw = images.first(where: { $0["size"] as? String == size })?["#text"] as? String,
              !raw.isEmpty, !raw.contains("2a96cbd8b46e442fc41c2b86b821562f") else { return nil }
        return URL(string: raw)
    }

    static func image(_ url: URL?, width: CGFloat) async -> UIImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data), image.size.width > 0 else { return nil }
        let size = CGSize(width: width, height: width * image.size.height / image.size.width)
        return image.preparingThumbnail(of: size) ?? image
    }

    static func artistPortraitURL(_ name: String) async -> URL? {
        var components = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/123/search.php")!
        components.queryItems = [URLQueryItem(name: "s", value: name)]
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artists = json["artists"] as? [[String: Any]],
              let artist = artists.first(where: { ($0["strArtist"] as? String)?.lowercased() == name.lowercased() }),
              let raw = artist["strArtistThumb"] as? String, let portrait = URL(string: raw), portrait.scheme == "https" else { return nil }
        return portrait
    }

    static func count(_ value: Any?) -> Int {
        if let value = value as? String { return Int(value) ?? 0 }
        return value as? Int ?? 0
    }
}
