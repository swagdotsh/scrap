import Foundation

struct PlayingTrack: Equatable, Codable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval?

    var artistURL: URL { Self.lastFMURL([artist]) }
    var trackURL: URL { Self.lastFMURL([artist, "_", title]) }
    var albumURL: URL { Self.lastFMURL([artist, album]) }

    private static func lastFMURL(_ components: [String]) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let path = components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        return URL(string: "https://www.last.fm/music/" + path)!
    }
}