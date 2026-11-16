import Foundation
import Testing
@testable import scrap

@MainActor
struct scrapTests {
    @Test func savedAccountsAreLimitedAndMatchedWithoutCase() throws {
        let first = LastFMAccount(username: "Listener", sessionKey: "one")
        var accounts = try #require(LastFMClient.adding(first, to: []))
        accounts = try #require(LastFMClient.adding(LastFMAccount(username: "listener", sessionKey: "two"), to: accounts))
        #expect(accounts.count == 1)
        #expect(accounts.first?.sessionKey == "two")
        for number in 2...LastFMClient.maxAccounts {
            accounts = try #require(LastFMClient.adding(LastFMAccount(username: "user\(number)", sessionKey: "\(number)"), to: accounts))
        }
        #expect(accounts.count == 5)
        #expect(LastFMClient.adding(LastFMAccount(username: "sixth", sessionKey: "6"), to: accounts) == nil)
        #expect(LastFMClient.adding(LastFMAccount(username: "USER3", sessionKey: "new"), to: accounts)?[2].sessionKey == "new")
        #expect(accounts.map(\.username) == ["listener", "user2", "user3", "user4", "user5"])
    }

    @Test func spotifyArtistImagePicksExactMatchAtUsableSize() throws {
        let json = """
        {"artists":{"items":[
          {"name":"Bjork Tribute","images":[{"url":"https://i.scdn.co/image/wrong","width":640,"height":640}]},
          {"name":"Björk","images":[
            {"url":"https://i.scdn.co/image/large","width":640,"height":640},
            {"url":"https://i.scdn.co/image/medium","width":320,"height":320},
            {"url":"https://i.scdn.co/image/small","width":160,"height":160}]}
        ]}}
        """
        let results = try JSONDecoder().decode(SpotifyArtistSearchResponse.self, from: Data(json.utf8))
        #expect(results.imageURL(for: "bjork")?.absoluteString == "https://i.scdn.co/image/medium")
        #expect(results.imageURL(for: "Unknown Artist") == nil)
    }

    @Test func artistImageCacheExpiresAfter24Hours() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtistImageDiskCache(directory: directory)
        await cache.store(Data([1, 2, 3]), for: "artist")
        await cache.store(nil, for: "nobody")
        guard case .image(let data, _) = await cache.read("artist") else { Issue.record("image not cached"); return }
        #expect(data == Data([1, 2, 3]))
        guard case .noImage = await cache.read("nobody") else { Issue.record("missing image not remembered"); return }
        #expect(await cache.read("artist", now: Date().addingTimeInterval(24 * 60 * 60 + 1)) == nil)
        #expect(await cache.read("artist") == nil)
    }
}
