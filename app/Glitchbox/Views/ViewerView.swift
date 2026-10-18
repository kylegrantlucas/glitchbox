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

    private var placeholder: String {
        if model.source == nil { return "Choose a source, add layers, then Render (⌘R)." }
        if model.viewFinal { return "Render (⌘R) to see the final output." }
        return "Select a rendered layer to preview it."
    }
}
