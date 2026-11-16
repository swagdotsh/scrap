import Foundation

enum WidgetLastFM {
    static var appGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ScrapAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return group
    }

    static var defaults: UserDefaults? { appGroup.flatMap(UserDefaults.init(suiteName:)) }

    static var container: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

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

    static func count(_ value: Any?) -> Int {
        if let value = value as? String { return Int(value) ?? 0 }
        return value as? Int ?? 0
    }
}
