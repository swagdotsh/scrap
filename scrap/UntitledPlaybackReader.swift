import ApplicationServices
import Foundation

struct UntitledPlayback {
    private static let playbackLine = try! NSRegularExpression(pattern: #"^(\d+(?::\d{1,2}){1,2})\s*/\s*(\d+(?::\d{1,2}){1,2})\s+(.+)$"#)
    let track: PlayingTrack
    let position: TimeInterval
    let isPlaying: Bool

    var id: String { "\(track.title)\u{1F}\(track.artist)\u{1F}\(track.album)" }

    static func parse(_ value: String, isPlaying: Bool) -> UntitledPlayback? {
        let lines = value.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return nil }
        let title = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let details = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(details.startIndex..<details.endIndex, in: details)
        guard !title.isEmpty, let match = playbackLine.firstMatch(in: details, range: range),
              let positionRange = Range(match.range(at: 1), in: details),
              let durationRange = Range(match.range(at: 2), in: details),
              let metadataRange = Range(match.range(at: 3), in: details),
              let position = clock(String(details[positionRange])),
              let duration = clock(String(details[durationRange])),
              duration > 0 else { return nil }
        let metadata = String(details[metadataRange])
        guard let separator = metadata.range(of: " · ", options: .backwards) else { return nil }
        let project = metadata[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = metadata[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return nil }
        return UntitledPlayback(track: PlayingTrack(title: title, artist: artist, album: project, duration: duration), position: position, isPlaying: isPlaying)
    }

    private static func clock(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }
}

enum UntitledPlaybackReader {
    static func read(pid: pid_t) -> UntitledPlayback? {
        let application = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return nil }

        for window in windows {
            var pending = [window]
            var visited = 0
            while !pending.isEmpty && visited < 500 {
                let element = pending.removeFirst()
                visited += 1
                if let value = string(element, attribute: kAXValueAttribute), value.contains("\n"), value.contains(" · "),
                   let playback = UntitledPlayback.parse(value, isPlaying: true),
                   let parentValue = elementValue(element, attribute: kAXParentAttribute),
                   CFGetTypeID(parentValue) == AXUIElementGetTypeID(),
                   let siblings = elementValue(parentValue as! AXUIElement, attribute: kAXChildrenAttribute) as? [AXUIElement] {
                    let buttons = siblings.compactMap { string($0, attribute: kAXDescriptionAttribute) }
                    if buttons.contains("Pause") { return playback }
                    if buttons.contains("Play") { return UntitledPlayback.parse(value, isPlaying: false) }
                }
                if let children = elementValue(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
                    pending.append(contentsOf: children)
                }
            }
        }
        return nil
    }

    private static func elementValue(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        elementValue(element, attribute: attribute) as? String
    }
}
