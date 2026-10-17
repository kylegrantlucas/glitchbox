import SwiftUI
import VideobedKit

struct PluginPresetMenu: View {
    let item: LayerItem
    let plugin: PluginManifest
    @Environment(StudioModel.self) private var model
    @State private var saving = false
    @State private var deleting: PluginPreset?

    var body: some View {
        let presets = model.pluginPresets[plugin.id, default: []]
        Menu("Presets") {
            ForEach(presets, id: \.name) { preset in
                Button(preset.name) { model.apply(preset: preset, to: item.id) }
            }
            if !presets.isEmpty { Divider() }
            Button("Save as Preset…") { saving = true }
            Menu("Delete Preset") {
                ForEach(presets, id: \.name) { preset in
                    Button(preset.name) { deleting = preset }
                }
            }
            .disabled(presets.isEmpty)
            Divider()
            Button("Reset to Defaults") { model.resetToDefaults(item.id) }
        }
        .sheet(isPresented: $saving) {
            NameSheet(title: "Save \(plugin.name) Preset", actionTitle: "Save",
                      existsMessage: "A preset with this name exists. Replace it?",
                      exists: { model.pluginPresetExists(plugin: plugin.id, name: $0) }) { name in
                try model.savePluginPreset(name: name, from: item.id)
            }
        }
        .confirmationDialog("Delete preset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { preset in
            Button("Delete “\(preset.name)”", role: .destructive) { model.deletePluginPreset(preset) }
        }
    }
}
