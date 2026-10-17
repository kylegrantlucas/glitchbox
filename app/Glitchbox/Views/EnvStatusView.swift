import SwiftUI

struct EnvStatusView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        switch model.envState {
        case .ready(let env):
            Label("Tools ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .help("Toolchain \(env.digest.prefix(12)) at \(model.toolchainContents.path)")
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
