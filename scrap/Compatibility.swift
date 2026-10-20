import SwiftUI

extension View {
    @ViewBuilder func prominentButtonStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func badgeBackground() -> some View {
        if #available(iOS 26, *) {
            glassEffect()
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder func minimizesTabBarOnScroll() -> some View {
        if #available(iOS 26, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    @ViewBuilder func navigationTitle(_ title: String, subtitle: String) -> some View {
        if #available(iOS 26, *) {
            navigationTitle(title).navigationSubtitle(subtitle)
        } else {
            navigationTitle("\(title) · \(subtitle)")
        }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder func withoutSharedBackground() -> some ToolbarContent {
        if #available(iOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
