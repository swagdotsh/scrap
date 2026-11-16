import Foundation
import WidgetKit

enum WidgetSync {
    private static let defaults = UserDefaults(suiteName: "group.com.swagrelated.scrap")

    static func update(username: String?) {
        let configuration = AppConfiguration.load()
        defaults?.set(username, forKey: "username")
        defaults?.set(username == nil ? nil : configuration.apiKey, forKey: "apiKey")
        defaults?.set(username == nil ? nil : configuration.spotifyClientID, forKey: "spotifyClientID")
        defaults?.set(username == nil ? nil : configuration.spotifyClientSecret, forKey: "spotifyClientSecret")
        reload()
    }

    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
