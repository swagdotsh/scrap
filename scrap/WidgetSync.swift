import Foundation
import WidgetKit

enum WidgetSync {
    static var appGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ScrapAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return group
    }

    static func update(username: String?) {
        guard let appGroup, let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(username, forKey: "username")
        defaults.set(username == nil ? nil : AppConfiguration.load().apiKey, forKey: "apiKey")
        reload()
    }

    static func reload() {
        guard appGroup != nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
