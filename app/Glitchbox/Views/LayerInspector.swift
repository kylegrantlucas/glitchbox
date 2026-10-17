import SwiftUI
import GlitchboxKit

struct LayerInspector: View {
    @Environment(StudioModel.self) private var model
    /// Explicit expand/collapse choices, keyed by plugin id + group name.
    @State private var expansion: [String: Bool] = [:]

    var body: some View {
        if let item = model.selectedItem {
            if let plugin = model.plugin(item.spec.plugin) {
                let groups = ParamGroup.groups(of: plugin)
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.name).font(.title3.bold())
                            if !plugin.summary.isEmpty {
                                Text(plugin.summary).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        PluginPresetMenu(item: item, plugin: plugin)
                    }
                    if case .unavailable(let why) = item.status {
                        Section { Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                    if groups.isEmpty {
                        Section { Text("No parameters").foregroundStyle(.secondary) }
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        ParamSection(group: group, item: item,
                                     isExpanded: expandedBinding(plugin.id, group.name, defaultValue: groups.count <= 3 || index == 0))
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Missing Plugin", systemImage: "puzzlepiece.extension",
                                       description: Text("No valid plugin '\(item.spec.plugin)' in plugins/."))
            }
        } else {
            ContentUnavailableView("No Layer Selected", systemImage: "slider.horizontal.3")
        }
    }

    /// Plugins with many sections start with only the first one open.
    private func expandedBinding(_ plugin: String, _ group: String, defaultValue: Bool) -> Binding<Bool> {
        let key = "\(plugin)\u{1F}\(group)"
        return Binding(get: { expansion[key] ?? defaultValue }, set: { expansion[key] = $0 })
    }
}
