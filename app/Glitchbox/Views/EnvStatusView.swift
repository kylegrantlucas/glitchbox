import SwiftUI

/// Toolbar status shown only when the bundled toolchain can't be loaded.
struct EnvStatusView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        switch model.envState {
        case .ready:
            EmptyView()
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Toolchain unavailable", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
                    .help(message)
                Button("Reload") { model.reloadToolchain() }
                    .help("Re-read toolchain.json")
            }
            .font(.callout)
        }
    }
}
