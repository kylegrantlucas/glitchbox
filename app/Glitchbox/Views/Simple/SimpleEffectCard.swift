import GlitchboxKit
import SwiftUI

/// One effect in Simple mode: on/off, its styles (plugin presets), and the plugin's few
/// plain-language controls. The same params Advanced edits, so values carry over.
struct SimpleEffectCard: View {
    let item: LayerItem
    @Environment(StudioModel.self) private var model

    var body: some View {
        let plugin = model.plugin(item.spec.plugin)
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    LayerEnabledToggle(isOn: Binding(get: { item.spec.enabled }, set: { model.setEnabled(item.id, $0) }))
                    Text(plugin.map(model.title(of:)) ?? item.spec.plugin)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(item.spec.enabled ? .primary : .secondary)
                    Spacer()
                    switch item.status {
                    case .running, .failed, .unavailable: LayerStatusText(status: item.status)
                    case .idle, .done, .disabled: EmptyView()
                    }
                    Menu("\(plugin.map(model.title(of:)) ?? item.spec.plugin) Options", systemImage: "ellipsis.circle") {
                        Button("Reset") { model.resetToDefaults(item.id) }
                            .disabled(plugin == nil)
                        Button("Remove", role: .destructive) { model.removeLayer(item.id) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if let plugin {
                    StyleStrip(item: item, plugin: plugin)
                    ForEach(plugin.simpleControls(values: item.spec.params), id: \.key) { spec in
                        let control = ParamControl(spec: spec, value: item.spec.params[spec.key] ?? spec.default, showsValue: false) {
                            model.setParam(item.id, key: spec.key, value: $0)
                        }
                        if spec.type == .enumeration {
                            // Outside a Form, iOS draws a menu picker without its label.
                            LabeledContent(spec.label) { control.labelsHidden().fixedSize() }
                        } else {
                            control
                        }
                    }
                    Button("All Controls…") { model.openAdvanced(layer: item.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("Open this effect in Advanced, with every parameter")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
