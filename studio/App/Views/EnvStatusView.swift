import SwiftUI

struct EnvStatusView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        switch model.envState {
        case .resolving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Resolving nix devshell (first run may build tools)…")
            }
            .font(.callout)
        case .ready:
            Label("Tools ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Environment failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
                    .help(message)
                Button("Retry") { model.resolveEnvironment(forceRefresh: true) }
            }
            .font(.callout)
        }
    }
}
