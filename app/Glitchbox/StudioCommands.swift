import SwiftUI

struct StudioCommands: Commands {
    let model: StudioModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Plugin…") { model.showNewPlugin = true }
        }
        CommandMenu("Render") {
            Button("Reload Toolchain") { model.reloadToolchain() }
            Button("Clear Render Cache…") { model.confirmClearCache = true }
        }
    }
}
