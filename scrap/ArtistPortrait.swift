import SwiftUI

@MainActor
final class ArtistPortraitStore {
    static let shared = ArtistPortraitStore()
    private struct Entry { let url: URL?; let expires: Date }
    private var cache: [String: Entry] = [:]
    private var pending: [String: Task<URL?, Never>] = [:]
    private var nextRequest = Date.distantPast

    func portrait(for name: String) async -> URL? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let entry = cache[key], entry.expires > Date() { return entry.url }
        if let task = pending[key] { return await task.value }
        // The shared free API allows 30 requests/minute. Both app surfaces share this queue.
        let delay = max(0, nextRequest.timeIntervalSinceNow)
        nextRequest = Date().addingTimeInterval(delay + 2.1)
        let task = Task<URL?, Never> {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            var components = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/123/search.php")!
            components.queryItems = [URLQueryItem(name: "s", value: name)]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 12
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let artists = json["artists"] as? [[String: Any]],
                      let artist = artists.first(where: { ($0["strArtist"] as? String)?.lowercased() == key }),
                      let raw = artist["strArtistThumb"] as? String,
                      let url = URL(string: raw), url.scheme == "https" else { return nil }
                return url
            } catch { return nil }
        }
        pending[key] = task
        let url = await task.value
        pending[key] = nil
        cache[key] = Entry(url: url, expires: Date().addingTimeInterval(url == nil ? 300 : 86400))
        return url
    }
}

struct ArtistPortrait: View {
    let name: String
    var size: CGFloat = 64
    @State private var url: URL?

    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay(Image(systemName: "person.crop.circle").font(.system(size: size * 0.4)).foregroundStyle(.secondary))
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Portrait of \(name)")
        .task(id: name) {
            url = nil
            let result = await ArtistPortraitStore.shared.portrait(for: name)
            guard !Task.isCancelled else { return }
            url = result
        }
    }
}
