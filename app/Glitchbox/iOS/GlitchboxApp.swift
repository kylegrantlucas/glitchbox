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

/// Picks the layout for the mode and the window width. Wide (iPad landscape, the 13-inch in
/// portrait) fits columns side by side: Advanced's three-column studio, or Simple's looks,
/// effects, and viewer. Otherwise (iPhone, portrait iPad, narrow split screen) the viewer sits
/// over the rest: Advanced's stack with the library and inspector as sheets, or Simple's
/// Looks/Adjust switch. The shared sheets hang off this view, above the layout switch, so
/// resizing across the threshold or changing mode keeps them (and editor drafts) open.
struct StudioRootView: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var wide = false

    var body: some View {
        @Bindable var model = model
        Group {
            switch (model.mode, sizeClass == .regular && wide) {
            case (.advanced, true): MainView()
            case (.advanced, false): CompactStudioView()
            case (.simple, true): SimpleWideView()
            case (.simple, false): SimpleCompactView()
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 1000 } action: { wide = $0 }
        .modifier(StudioPresentations())
        .sheet(isPresented: $model.showLicenses) { LicensesView() }
    }
}
