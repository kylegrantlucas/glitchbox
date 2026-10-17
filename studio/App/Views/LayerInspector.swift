import SwiftUI
import VideobedKit

struct LayerInspector: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        if let item = model.selectedItem {
            if let plugin = model.plugin(item.spec.plugin) {
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
                    Section("Parameters") {
                        if plugin.params.isEmpty {
                            Text("No parameters").foregroundStyle(.secondary)
                        }
                        ForEach(plugin.params, id: \.key) { spec in
                            ParamControl(spec: spec, value: item.spec.params[spec.key] ?? spec.default) {
                                model.setParam(item.id, key: spec.key, value: $0)
                            }
                        }
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
}
