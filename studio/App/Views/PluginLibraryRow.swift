import SwiftUI
import VideobedKit

struct PluginLibraryRow: View {
    let plugin: PluginManifest
    @Environment(StudioModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                availability
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

    @ViewBuilder private var availability: some View {
        if let missing = model.missingTools(plugin) {
            if missing.isEmpty {
                Text("available").font(.caption).foregroundStyle(.green)
            } else {
                Text("missing: \(missing.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("checking…").font(.caption).foregroundStyle(.secondary)
        }
    }
}
