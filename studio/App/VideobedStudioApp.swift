import SwiftUI
import VideobedKit

@main
struct VideobedStudioApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        Window("Videobed Studio", id: "main") {
            RootGate()
                .environment(store)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            StudioCommands(store: store)
        }

        WindowGroup("Plugin Editor", id: "plugin-editor", for: String.self) { $pluginID in
            PluginEditorWindow(pluginID: pluginID ?? "")
                .environment(store)
        }
        .defaultSize(width: 760, height: 820)
    }
}
