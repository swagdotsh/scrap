import WidgetKit
import SwiftUI

@main
struct ScrapWidgets: WidgetBundle {
    var body: some Widget {
        TopArtistWidget()
        RecentScrobblesWidget()
    }
}
