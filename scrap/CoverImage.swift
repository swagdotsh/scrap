import SwiftUI
import UIKit
import ImageIO

enum CoverLoader {
    static let maxAnimatedFrames = 240

    static func load(_ url: URL, animated: Bool, maxPixelSize: CGFloat = 600) async -> UIImage? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
        if animated, count > 1, count <= maxAnimatedFrames {
            var frames: [UIImage] = []
            var duration: TimeInterval = 0
            for index in 0..<count {
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
                frames.append(UIImage(cgImage: frame))
                duration += frameDuration(source, at: index)
            }
            if frames.count > 1 { return UIImage.animatedImage(with: frames, duration: duration) }
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }

    static func isAnimated(_ image: UIImage?) -> Bool {
        (image?.images?.count ?? 0) > 1
    }

    private static func frameDuration(_ source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let containers = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary]
        for container in containers {
            guard let values = properties[container] as? [CFString: Any] else { continue }
            let delay = (values[kCGImagePropertyGIFUnclampedDelayTime] ?? values[kCGImagePropertyAPNGUnclampedDelayTime]
                ?? values[kCGImagePropertyWebPUnclampedDelayTime] ?? values[kCGImagePropertyGIFDelayTime]) as? Double
            if let delay, delay > 0.01 { return delay }
        }
        return 0.1
    }
}

struct CoverImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @AppStorage("animatedAlbumCovers") private var animatedSetting = false
    @ObservedObject private var conditions = DeviceConditions.shared
    @State private var image: UIImage?

    private var animatedCovers: Bool { animatedSetting && !conditions.limitsAnimation }

    var body: some View {
        Group {
            if let image, CoverLoader.isAnimated(image) {
                AnimatedImageView(image: image)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: "\(url?.absoluteString ?? "")|\(animatedCovers)") {
            image = nil
            guard let url else { return }
            let loaded = await CoverLoader.load(url, animated: animatedCovers)
            if !Task.isCancelled { image = loaded }
        }
    }
}

struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image { view.image = image }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 44, height: proposal.height ?? 44)
    }
}
