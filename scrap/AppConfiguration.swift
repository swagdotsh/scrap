import Foundation

struct AppConfiguration {
    let apiKey: String
    let sharedSecret: String

    static func load() -> AppConfiguration {
        let url = Bundle.main.url(forResource: "LastFM", withExtension: "env")
        let contents = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let values = parse(contents)
        return AppConfiguration(apiKey: values["LASTFM_API_KEY"] ?? "", sharedSecret: values["LASTFM_SHARED_SECRET"] ?? "")
    }

    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value.removeFirst(); value.removeLast()
            }
            values[key] = value
        }
        return values
    }
}
