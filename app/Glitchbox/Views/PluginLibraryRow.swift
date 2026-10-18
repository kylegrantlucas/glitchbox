import SwiftUI
import GlitchboxKit

struct PluginLibraryRow: View {
    let plugin: PluginManifest
    @Environment(StudioModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                unavailability
            }
            Spacer()
            Button("Add Layer", systemImage: "plus.circle") { model.addLayer(plugin: plugin.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Add \(plugin.name) to the end of the stack")
        }
        .help(plugin.summary)
        .contextMenu {
            Button("Add Layer") { model.addLayer(plugin: plugin.id) }
            Button("Edit") { openWindow(id: "plugin-editor", value: plugin.id) }
        }
    }

    /// Shown only when the plugin can't run.
    @ViewBuilder private var unavailability: some View {
        if let missing = model.missingTools(plugin) {
            if !missing.isEmpty {
                Text("missing: \(missing.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("toolchain unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }
}
