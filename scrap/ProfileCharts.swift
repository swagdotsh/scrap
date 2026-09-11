import Foundation

struct ProfileChartEntry: Identifiable {
    let link: MusicLink
    let artist: String
    let count: Int
    var id: String { link.id }
}

extension LastFMClient {
    func profileChart(kind: String) async throws -> [ProfileChartEntry] {
        guard let username else { return [] }
        let singular = kind == "artists" ? "artist" : kind == "albums" ? "album" : "track"
        let method = kind == "artists" ? "user.getTopArtists" : kind == "albums" ? "user.getTopAlbums" : "user.getTopTracks"
        let json = try await request(["method": method, "user": username, "period": "overall", "limit": "5"])
        guard let root = json["top" + kind] as? [String: Any] else { return [] }
        let rows = root[singular] as? [[String: Any]] ?? (root[singular] as? [String: Any]).map { [$0] } ?? []
        var entries: [ProfileChartEntry] = []
        for row in rows.prefix(5) {
            guard var link = MusicLink.parse(row).first else { continue }
            let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            
            if kind == "tracks", link.imageURL == nil, !Task.isCancelled,
               let data = try? await request(["method": "track.getInfo", "artist": artist, "track": link.name]),
               let track = data["track"] as? [String: Any], let album = track["album"] as? [String: Any] {
                let images = album["image"] as? [[String: Any]] ?? []
                link.imageURL = images.reversed().compactMap { ($0["#text"] as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
            }
            let count = (row["playcount"] as? String).flatMap(Int.init) ?? row["playcount"] as? Int ?? 0
            if !entries.contains(where: { $0.id == link.id }) { entries.append(ProfileChartEntry(link: link, artist: artist, count: count)) }
        }
        return entries
    }
}
