import AppKit
import SwiftUI

struct StudioCommands: Commands {
    let model: StudioModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Plugin…") { model.showNewPlugin = true }
            Divider()
            Button("Export…") { model.showExport = true }
                .keyboardShortcut("e")
                .disabled(!model.canRender || model.isExporting)
            Button("Export Current Frame…") { exportCurrentFrame() }
                .disabled(model.viewedOutput == nil)
        }
        CommandMenu("Render") {
            Button("Reload Toolchain") { model.reloadToolchain() }
            Button("Clear Render Cache…") { model.confirmClearCache = true }
        }
    }

    private func exportCurrentFrame() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let stem = model.source?.deletingPathExtension().lastPathComponent ?? "frame"
        panel.nameFieldStringValue = "\(stem)-glitchbox.png"
        panel.directoryURL = model.exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportCurrentFrame(to: url)
    }
}
