import AppKit
import SwiftUI
import ImageIO

enum ArtworkCandidates {
    static func urls(_ value: Any?) -> [URL] {
        let images = value as? [[String: Any]] ?? []
        var seen = Set<URL>()
        return images.reversed().compactMap { row in
            guard let raw = row["#text"] as? String, let url = URL(string: raw),
                  url.scheme == "https", !raw.contains("2a96cbd8b46e442fc41c2b86b821562f"),
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }

    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    static func stillImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: frame, size: .zero)
    }

    static func loadStill(urls: [URL], fetch: (URL) async -> Data?) async -> NSImage? {
        var fallback: NSImage?
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard !Task.isCancelled else { return nil }
            guard let data = await fetch(url), !Task.isCancelled,
                  let still = stillImage(data) else { continue }
            if !isAnimated(data) { return still }
            if fallback == nil { fallback = still }
        }
        return Task.isCancelled ? nil : fallback
    }

    static func loadNowPlaying(urls: [URL], preferAnimated: Bool, fetch: (URL) async -> Data?) async -> NSImage? {
        var fallback: NSImage?
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard !Task.isCancelled else { return nil }
            guard let data = await fetch(url), !Task.isCancelled,
                  let image = AlbumArtwork.decode(data) else { continue }
            if !preferAnimated || isAnimated(data) { return image }
            if fallback == nil { fallback = image }
        }
        return Task.isCancelled ? nil : fallback
    }
}

/// NSImageView preserves GIF frames and their timing, unlike SwiftUI.Image.
struct AlbumArtwork: NSViewRepresentable {
    let image: NSImage

    static func decode(_ data: Data) -> NSImage? {
        // Explicitly retain the bitmap representation so AppKit can access GIF frames.
        guard let bitmap = NSBitmapImageRep(data: data),
              (bitmap.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 0 > 1 else {
            return NSImage(data: data)
        }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    func makeNSView(context: Context) -> ArtworkContainer {
        ArtworkContainer()
    }

    func updateNSView(_ view: ArtworkContainer, context: Context) {
        if view.imageView.image !== image {
            view.imageView.image = image
            view.needsLayout = true
        }
    }

    final class ArtworkContainer: NSView {
        let imageView = NSImageView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            imageView.animates = true
            imageView.imageScaling = .scaleAxesIndependently
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
                imageView.frame = bounds
                return
            }
            let scale = max(bounds.width / size.width, bounds.height / size.height)
            let width = size.width * scale
            let height = size.height * scale
            imageView.frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                     width: width, height: height)
        }

        // Artwork inside a SwiftUI Link must not intercept its clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct RemoteAlbumArtwork<Placeholder: View>: View {
    let url: URL?
    var alternatives: [URL] = []
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?
    @State private var loadedURLs: [URL] = []

    private var urls: [URL] { (url.map { [$0] } ?? []) + alternatives }

    var body: some View {
        Group {
            if let image, loadedURLs == urls {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            image = nil
            loadedURLs = []
            let candidates = urls
            let downloaded = await ArtworkCandidates.loadStill(urls: candidates) { url in
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
                request.timeoutInterval = 10
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return data
            }
            guard !Task.isCancelled else { return }
            image = downloaded
            loadedURLs = candidates
        }
    }
}
