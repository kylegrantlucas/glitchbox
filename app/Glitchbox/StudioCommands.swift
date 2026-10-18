import AppKit
import SwiftUI

struct StudioCommands: Commands {
    let model: StudioModel
    @AppStorage(LogPanel.visibleKey) private var showLog = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Plugin…") { model.showNewPlugin = true }
            Button("Save Chain…") { model.showSaveChain = true }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.stack.isEmpty)
            Divider()
            Button("Export…") { model.showExport = true }
                .keyboardShortcut("e")
                .disabled(!model.canRender || model.isExporting)
            Button("Export Current Frame…") { exportCurrentFrame() }
                .disabled(model.viewedOutput == nil)
            Button("Reveal Output in Finder") { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.viewedOutput == nil && model.selectedItem?.output == nil)
        }
        CommandMenu("Render") {
            Button("Render") { model.render() }
                .keyboardShortcut("r")
                .disabled(!model.canRender)
            Button("Stop Render") { model.cancelRender() }
                .keyboardShortcut(".")
                .disabled(!model.isRendering)
            Divider()
            Toggle("Auto-render After Edits", isOn: Bindable(model).autoRender)
            Toggle("Play Final Output", isOn: Bindable(model).viewFinal)
            Toggle("Show Log", isOn: $showLog)
                .keyboardShortcut("l")
            Divider()
            Button("Reload Toolchain") { model.reloadToolchain() }
            Button("Clear Render Cache…") { model.confirmClearCache = true }
                .disabled(model.isExporting)
        }
        CommandGroup(replacing: .help) {
            Button("Third-Party Licenses") { NSWorkspace.shared.open(Self.licenses) }
                .disabled(!FileManager.default.fileExists(atPath: Self.licenses.path))
        }
    }

    /// Licence texts of every bundled tool, staged by packaging/build.sh (absent from Debug builds).
    private static let licenses = Bundle.main.bundleURL.appending(path: "Contents/Resources/licenses", directoryHint: .isDirectory)

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
