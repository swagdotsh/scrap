import AppKit
import ApplicationServices
import Foundation

nonisolated struct UntitledPlayback: Codable, Equatable {
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

    static func parse(barTexts texts: [String], transportButton: String?) -> UntitledPlayback? {
        let texts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for index in texts.indices {
            guard let position = clock(texts[index]) else { continue }
            var next = index + 1
            if next < texts.count, texts[next] == "/" { next += 1 }
            guard next < texts.count, let duration = clock(texts[next]), duration > 0,
                  next + 1 < texts.count, index > 0 else { continue }
            let title = texts[index - 1]
            let metadata = texts[next + 1]
            guard !title.isEmpty, clock(title) == nil,
                  let separator = metadata.range(of: " · ", options: .backwards) else { continue }
            let project = metadata[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = metadata[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty else { continue }
            return UntitledPlayback(track: PlayingTrack(title: title, artist: artist, album: project, duration: duration),
                                    position: position, isPlaying: transportButton != "Play")
        }
        return nil
    }

    private static func clock(_ value: String) -> TimeInterval? {
        guard value.range(of: #"^\d+(:\d{1,2}){1,2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }
}

nonisolated enum UntitledAccessibility {
    static let bundleID = "com.untitledinbrackets.untitled-macos"

    static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func diagnostics(header: String) -> String {
        let trusted = AXIsProcessTrusted()
        var lines = [header, "Accessibility access: \(trusted ? "yes" : "no")"]
        guard let application = runningApplication else {
            lines.append("[untitled]: not running")
            return lines.joined(separator: "\n")
        }
        let version = application.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
        lines.append("[untitled]: running, version \(version)")
        guard trusted else { return lines.joined(separator: "\n") }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        var windowsValue: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue)
        let windows = windowsValue as? [AXUIElement] ?? []
        var roleValue: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &roleValue)
        lines.append("Windows: \(windows.count) (AX result \(windowsError.rawValue); app role result \(roleError.rawValue))")
        var visited = 0
        var texts: [String] = []
        var buttons = Set<String>()
        for window in windows {
            var pending = [window]
            while !pending.isEmpty && visited < 1500 {
                let element = pending.removeFirst()
                visited += 1
                if let role = string(element, attribute: kAXRoleAttribute), role == kAXButtonRole,
                   let description = string(element, attribute: kAXDescriptionAttribute), !description.isEmpty {
                    buttons.insert(description)
                }
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = string(element, attribute: attribute), looksLikePlayback(text), texts.count < 12 {
                        texts.append("\(attribute): \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
                    }
                }
                if let children = elementValue(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
                    pending.append(contentsOf: children)
                }
            }
        }
        lines.append("Elements checked: \(visited)")
        lines.append("Buttons: " + (buttons.isEmpty ? "none" : buttons.sorted().prefix(30).joined(separator: ", ")))
        lines.append("Text that looks like playback:" + (texts.isEmpty ? " none" : ""))
        lines += texts.map { "  " + $0 }
        let playback = read(pid: application.processIdentifier)
        lines.append("scrap reads: " + (playback.map { "\($0.track.title) – \($0.track.artist) (\($0.track.album)), \($0.isPlaying ? "playing" : "paused")" } ?? "nothing"))
        return lines.joined(separator: "\n")
    }

    private static func looksLikePlayback(_ text: String) -> Bool {
        text.contains(" · ") || text.range(of: #"\d:\d{2}"#, options: .regularExpression) != nil
    }

    static func read(pid: pid_t) -> UntitledPlayback? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return nil }
        if let playback = readPlayerBar(windows) { return playback }
        return readCombinedText(windows)
    }

    private static func readPlayerBar(_ windows: [AXUIElement]) -> UntitledPlayback? {
        for window in windows {
            var pending = [window]
            var visited = 0
            while !pending.isEmpty && visited < 500 {
                let element = pending.removeFirst()
                visited += 1
                if string(element, attribute: kAXRoleAttribute) == kAXButtonRole,
                   string(element, attribute: kAXDescriptionAttribute) == "Previous",
                   let parentValue = elementValue(element, attribute: kAXParentAttribute),
                   CFGetTypeID(parentValue) == AXUIElementGetTypeID(),
                   let siblings = elementValue(parentValue as! AXUIElement, attribute: kAXChildrenAttribute) as? [AXUIElement] {
                    let texts = siblings.filter { string($0, attribute: kAXRoleAttribute) == kAXStaticTextRole }
                        .compactMap { string($0, attribute: kAXValueAttribute) }
                    let buttons = siblings.filter { string($0, attribute: kAXRoleAttribute) == kAXButtonRole }
                        .map { string($0, attribute: kAXDescriptionAttribute) ?? "" }
                    let transport = buttons.firstIndex(of: "Previous").flatMap { $0 + 1 < buttons.count ? buttons[$0 + 1] : nil }
                    if let playback = UntitledPlayback.parse(barTexts: texts, transportButton: transport) { return playback }
                }
                if let children = elementValue(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
                    pending.append(contentsOf: children)
                }
            }
        }
        return nil
    }

    private static func readCombinedText(_ windows: [AXUIElement]) -> UntitledPlayback? {
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
