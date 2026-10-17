import SwiftUI
import VideobedKit

/// Loads a plugin manifest from disk for editing.
struct PluginEditorWindow: View {
    let pluginID: String
    @Environment(AppStore.self) private var store

    var body: some View {
        if let model = store.model {
            switch load(model.workspace) {
            case .success(let manifest):
                PluginEditorView(initial: manifest)
                    .environment(model)
                    .navigationTitle("Plugin: \(manifest.name)")
            case .failure(let error):
                ContentUnavailableView("Cannot Open Plugin", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
                    .frame(minWidth: 500, minHeight: 300)
            }
        } else {
            ContentUnavailableView("No Checkout", systemImage: "folder.badge.questionmark")
        }
    }

    private func load(_ ws: Workspace) -> Result<PluginManifest, any Error> {
        Result {
            let url = ws.pluginsDir.appending(path: "\(pluginID).json")
            return try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
        }
    }
}
