import SwiftUI
import AppKit

/// TextKit reserves room for the portrait, then uses the full width below it.
struct ArtistBiography: View {
    let name: String
    let text: String

    var body: some View {
        WrappedBiographyText(text: text)
            .frame(minHeight: 72)
            .overlay(alignment: .topLeading) {
                ArtistPortrait(name: name, size: 72)
            }
    }
}

private struct WrappedBiographyText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextView {
        let container = NSTextContainer(containerSize: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 8
        container.lineBreakMode = .byTruncatingTail
        container.exclusionPaths = [NSBezierPath(rect: NSRect(x: 0, y: 0, width: 84, height: 80))]
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.string != text else { return }
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .callout),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        view.setAccessibilityLabel(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = nsView.textContainer, let manager = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: max(72, ceil(manager.usedRect(for: container).height)))
    }
}
