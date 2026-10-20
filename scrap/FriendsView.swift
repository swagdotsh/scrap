import SwiftUI

struct FriendsView: View {
    @EnvironmentObject private var lastFM: LastFMClient
    @State private var friends: [FriendActivity] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            ForEach(friends) { friend in
                Link(destination: friend.profileURL) {
                    HStack(spacing: 12) {
                        Avatar(url: friend.avatarURL, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.name).font(.headline).foregroundStyle(.primary)
                            if let track = friend.track {
                                Text([track, friend.artist].compactMap { $0 }.joined(separator: " — "))
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text("No recent scrobbles").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .tint(.primary)
        .overlay {
            if !loaded {
                ProgressView()
            } else if friends.isEmpty, error == nil {
                ContentUnavailableView("No friends yet", systemImage: "person.2",
                                       description: Text("People you follow on last.fm show up here."))
            }
        }
        .refreshable { await load() }
        .task(id: lastFM.username) { await load() }
    }

    private func load() async {
        do {
            let result = try await lastFM.friends()
            guard !Task.isCancelled else { return }
            friends = result
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't refresh friends. \(error.localizedDescription)"
        }
        loaded = true
    }
}
