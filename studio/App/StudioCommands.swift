import SwiftUI

struct StudioCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Plugin…") { store.model?.showNewPlugin = true }
                .disabled(store.model == nil)
        }
        CommandMenu("Render") {
            Button("Reload Environment") { store.model?.resolveEnvironment(forceRefresh: true) }
                .disabled(store.model == nil)
            Button("Clear Render Cache…") { store.model?.confirmClearCache = true }
                .disabled(store.model == nil)
        }
    }
}
