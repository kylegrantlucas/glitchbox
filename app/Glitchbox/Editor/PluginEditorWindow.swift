import SwiftUI
import GlitchboxKit

/// Loads a plugin manifest (the user copy, else the built-in) for editing.
struct PluginEditorWindow: View {
    let pluginID: String
    @Environment(StudioModel.self) private var model

    var body: some View {
        switch load(model.workspace) {
        case .success(let manifest):
            PluginEditorView(initial: manifest)
                .navigationTitle("Plugin: \(manifest.name)")
        case .failure(let error):
            ContentUnavailableView("Cannot Open Plugin", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
                .frame(minWidth: 500, minHeight: 300)
        }
    }

    private func load(_ ws: Workspace) -> Result<PluginManifest, any Error> {
        Result {
            guard let url = ws.pluginFile(id: pluginID) else { throw StudioError("no plugin '\(pluginID)' in the library") }
            return try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
        }
    }
}
