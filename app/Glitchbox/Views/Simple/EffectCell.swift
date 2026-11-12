import GlitchboxKit
import SwiftUI

/// One effect in the picker: thumbnail, plain-language name, and blurb.
struct EffectCell: View {
    let plugin: PluginManifest
    let action: () -> Void
    @Environment(StudioModel.self) private var model

    var body: some View {
        // nil while the toolchain is unavailable.
        let unavailable = model.missingTools(plugin).map { !$0.isEmpty } ?? true
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                ThumbnailView(url: model.workspace.effectThumbnail(plugin: plugin.id))
                Text(plugin.simpleName)
                    .font(.headline)
                    .lineLimit(1)
                Text(plugin.simple?.blurb ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                if unavailable {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
    }
}
