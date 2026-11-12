import SwiftUI

/// The main window's content for the current mode. The shared sheets and the window's
/// minimum size hang off this view, above the switch, so changing mode keeps them.
struct StudioRootView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        Group {
            switch model.mode {
            case .simple: SimpleWideView()
            case .advanced: MainView()
            }
        }
        .modifier(StudioPresentations())
        .frame(minWidth: 1100, minHeight: 640)
    }
}
