import SwiftUI
import GlitchboxKit

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
                ForEach(presets.filter { model.origin(of: $0) != .overridden }, id: \.name) { preset in
                    Button(preset.name) { deleting = preset }
                        .disabled(model.origin(of: preset) == .builtin)
                }
            }
            .disabled(!presets.contains { model.origin(of: $0) == .user })
            let overridden = presets.filter { model.origin(of: $0) == .overridden }
            if !overridden.isEmpty {
                Menu("Revert to Built-in") {
                    ForEach(overridden, id: \.name) { preset in
                        Button(preset.name) { deleting = preset }
                    }
                }
            }
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
        .confirmationDialog(deletingTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { preset in
            if model.origin(of: preset) == .overridden {
                Button("Revert “\(preset.name)”", role: .destructive) { model.deletePluginPreset(preset) }
            } else {
                Button("Delete “\(preset.name)”", role: .destructive) { model.deletePluginPreset(preset) }
            }
        }
    }

    private var deletingTitle: String {
        if let deleting, model.origin(of: deleting) == .overridden { return "Revert preset to built-in?" }
        return "Delete preset?"
    }
}
