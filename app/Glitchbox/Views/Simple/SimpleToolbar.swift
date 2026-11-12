import SwiftUI

/// Advanced's way back to Simple, at the leading edge of its toolbar.
struct SimpleModeButton: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        Button("Simple", systemImage: "chevron.backward") { model.mode = .simple }
            .labelStyle(.titleAndIcon)
            .help("Back to Simple: looks and a few sliders (⌘1)")
    }
}

/// Simple mode's toolbar: Stop while rendering, Render only to retry after a stop or a
/// failure (renders start by themselves), and Export.
struct SimpleToolbar: ToolbarContent {
    @Environment(StudioModel.self) private var model
    @Environment(\.studioSheetRequest) private var request

    var body: some ToolbarContent {
        if model.environment == nil {
            ToolbarItem(placement: .navigation) {
                EnvStatusView()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isRendering {
                Button("Stop", systemImage: "stop.fill") { model.cancelRender() }
                    .help("Stop the render (⌘.)")
            } else if model.canRender, model.playerItemURL == nil, !model.isRenderPending, !model.isMakingProxy {
                Button("Render", systemImage: "play.fill") { model.render() }
                    .help("Render again (⌘R)")
            }
            if model.isExporting {
                ExportProgressView()
            } else {
                Button("Export…", systemImage: "square.and.arrow.up") { request { model.showExport = true } }
                    .disabled(!model.canRender)
                    .help("Export to a movie, GIF, or image sequence (⌘E)")
            }
        }
    }
}
