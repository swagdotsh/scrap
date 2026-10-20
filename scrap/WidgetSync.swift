import Foundation
import WidgetKit

enum WidgetSync {
    private static let defaults = UserDefaults(suiteName: "group.com.swagrelated.scrap")

    static func update(username: String?) {
        defaults?.set(username, forKey: "username")
        defaults?.set(username == nil ? nil : AppConfiguration.load().apiKey, forKey: "apiKey")
        reload()
    }

    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
