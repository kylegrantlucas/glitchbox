import GlitchboxKit
import SwiftUI

/// An effect's styles (its plugin presets) as a row of chips; the one matching the layer's
/// params is tinted and checked (the tint alone vanishes in an inactive window). Nothing for a
/// plugin without presets.
struct StyleStrip: View {
    let item: LayerItem
    let plugin: PluginManifest
    @Environment(StudioModel.self) private var model

    var body: some View {
        let presets = model.pluginPresets[plugin.id, default: []]
        if !presets.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.name) { preset in
                        let active = model.isActive(preset, on: item)
                        Button {
                            model.apply(preset: preset, to: item.id)
                        } label: {
                            if active { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(active ? Color.accentColor : nil)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
