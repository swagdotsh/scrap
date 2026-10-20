import Foundation
import MusicKit

enum AppleMusicFavorites {
    static func isFavorited(storeID: String?) async -> Bool {
        guard let storeID, !storeID.isEmpty, storeID != "0",
              let url = URL(string: "https://api.music.apple.com/v1/me/ratings/songs/\(storeID)") else { return false }
        do {
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            return try JSONDecoder().decode(Ratings.self, from: response.data).data.first?.attributes.value == 1
        } catch {
            return false
        }
    }

    static func requestAccess() async -> Bool {
        await MusicAuthorization.request() == .authorized
    }

    private struct Ratings: Decodable {
        struct Rating: Decodable {
            struct Attributes: Decodable { let value: Int }
            let attributes: Attributes
        }
        let data: [Rating]
    }
}
