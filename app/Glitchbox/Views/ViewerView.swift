import SwiftUI

struct ViewerView: View {
    @Environment(StudioModel.self) private var model
    @AppStorage(LogPanel.visibleKey) private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.playerItemURL != nil {
                    PlayerView(player: model.player.player)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else if case .failed(let message) = model.envState {
                    ContentUnavailableView {
                        Label("Toolchain Unavailable", systemImage: "wrench.and.screwdriver")
                    } description: {
                        Text(message)
                            .textSelection(.enabled)
                    } actions: {
                        Button("Reload Toolchain") { model.reloadToolchain() }
                    }
                } else if model.mode == .simple {
                    if model.source == nil {
                        ContentUnavailableView("Choose a Photo or Video", systemImage: "photo.on.rectangle",
                                               description: Text("Then pick a look."))
                    } else if simpleIsRendering {
                        ProgressView("Rendering…")
                    } else if model.stack.isEmpty {
                        ContentUnavailableView("Pick a Look", systemImage: "sparkles",
                                               description: Text("Looks apply a finished style in one tap."))
                    } else {
                        // Stopped, failed (the effect's card says why), or the cache was cleared.
                        ContentUnavailableView("Not Rendered", systemImage: "play.rectangle",
                                               description: Text("Render to try again."))
                    }
                } else {
                    ContentUnavailableView("Nothing to Play", systemImage: "play.rectangle",
                                           description: Text(placeholder))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            if showLog {
                Divider()
                LogPanel()
                    .frame(height: 200)
            }
        }
        .onChange(of: model.playerItemURL, initial: true) { model.player.load(model.playerItemURL) }
    }

    /// Simple mode renders by itself: an edit waiting for its render, the render, and the
    /// finished render's player proxy all read as rendering.
    private var simpleIsRendering: Bool {
        model.isRendering || model.isRenderPending || model.isMakingProxy
    }

    private var placeholder: String {
        if model.source == nil { return "Choose a source, add layers, then Render (⌘R)." }
        if model.viewFinal { return "Render (⌘R) to see the final output." }
        return "Select a rendered layer to preview it."
    }
}
