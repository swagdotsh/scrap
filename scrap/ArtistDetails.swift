import Foundation

struct MusicLink: Identifiable {
    let name: String
    let url: URL
    var imageURL: URL? = nil
    var id: String { url.absoluteString }

    static func parse(_ value: Any?, limit: Int = 20) -> [MusicLink] {
        let rows = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
        var seen = Set<URL>()
        return Array(rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty,
                  let raw = row["url"] as? String, var url = URLComponents(string: raw),
                  ["http", "https"].contains(url.scheme ?? ""),
                  let host = url.host, host == "last.fm" || host.hasSuffix(".last.fm") else { return nil as MusicLink? }
            url.scheme = "https"
            guard let destination = url.url, seen.insert(destination).inserted else { return nil }
            let images = row["image"] as? [[String: Any]] ?? []
            let imageURL = images.reversed().compactMap { ($0["#text"] as? String).flatMap(URL.init(string:)) }
                .first { $0.scheme == "https" && !$0.absoluteString.contains("2a96cbd8b46e442fc41c2b86b821562f") }
            return MusicLink(name: name, url: destination, imageURL: imageURL)
        }.prefix(limit))
    }
}

struct ArtistDetails {
    var url: URL?
    var biography = ""
    var totalPlays: Int?
    var tags: [MusicLink] = []
    var similar: [MusicLink] = []
    var topTracks: [MusicLink] = []
    var topAlbums: [MusicLink] = []

    static func plainBiography(_ html: String) -> String {
        // Remove Last.fm's trailing attribution link; the view provides its own source link.
        let stripped = html.replacingOccurrences(of: "<a\\b[^>]*>.*?</a>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        var text = stripped
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
