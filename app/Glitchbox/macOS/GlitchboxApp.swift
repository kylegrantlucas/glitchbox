import SwiftUI

@main
struct GlitchboxApp: App {
    @State private var model = StudioModel(paths: .current())

    var body: some Scene {
        Window("Glitchbox", id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            StudioCommands(model: model)
        }

        WindowGroup("Plugin Editor", id: "plugin-editor", for: String.self) { $pluginID in
            PluginEditorWindow(pluginID: pluginID ?? "")
                .environment(model)
        }
        .defaultSize(width: 760, height: 820)
    }
}
