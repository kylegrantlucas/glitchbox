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
                // The Form stays the inspector's root: wrapped in a stack, macOS 27's split view
                // takes its full content height and shifts every column off-screen.
                .safeAreaInset(edge: .top, spacing: 0) { header(plugin: plugin, item: item) }
            } else {
                ContentUnavailableView("Missing Plugin", systemImage: "puzzlepiece.extension",
                                       description: Text("No valid plugin '\(item.spec.plugin)' in plugins/."))
            }
        } else {
            ContentUnavailableView("No Layer Selected", systemImage: "slider.horizontal.3")
        }
    }

    /// Plugin name and Presets menu, with the summary underneath.
    private func header(plugin: PluginManifest, item: LayerItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(plugin.name).font(.title3.bold())
                Spacer()
                PluginPresetMenu(item: item, plugin: plugin)
            }
            if !plugin.summary.isEmpty {
                Text(plugin.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .background(.background)
    }

    /// Plugins with many sections start with only the first one open.
    private func expandedBinding(_ plugin: String, _ group: String, defaultValue: Bool) -> Binding<Bool> {
        let key = "\(plugin)\u{1F}\(group)"
        return Binding(get: { expansion[key] ?? defaultValue }, set: { expansion[key] = $0 })
    }
}
