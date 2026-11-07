import SwiftUI

@main
struct GlitchboxApp: App {
    @State private var model = StudioModel(paths: .current())
    @State private var work = BackgroundWork()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StudioRootView()
                .modifier(ContinuedProcessing(work: work))
                .environment(model)
        }
        .onChange(of: scenePhase) {
            // Picks up plugins and presets added through the Files app while away.
            if scenePhase == .active { model.reloadLibrary() }
        }
        .commands {
            StudioCommands(model: model)
        }
    }
}

/// The three-column studio when the window is wide enough for the stack, the viewer, and the
/// inspector side by side (iPad landscape, the 13-inch in portrait); the compact flow
/// otherwise (iPhone, portrait iPad, narrow split screen), where the viewer sits over the
/// stack and the library and inspector open as sheets. The shared sheets hang off this view,
/// above the layout switch, so resizing across the threshold keeps them (and editor drafts) open.
struct StudioRootView: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var wide = false

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular && wide {
                MainView()
            } else {
                CompactStudioView()
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 1000 } action: { wide = $0 }
        .modifier(StudioPresentations())
        .sheet(isPresented: $model.showLicenses) { LicensesView() }
    }
}
