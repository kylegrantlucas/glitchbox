import SwiftUI

/// The Mac menu bar, and the iPadOS menu bar on iPad.
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
            Button("Export Current Frame…") { PlatformActions.exportCurrentFrame(model) }
                .disabled(model.viewedOutput == nil)
            #if os(macOS)
            Button("Reveal Output in Finder") { PlatformActions.revealInFinder(model) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.viewedOutput == nil && model.selectedItem?.output == nil)
            #endif
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
                .disabled(model.mode == .simple)
            Toggle("Play Final Output", isOn: Bindable(model).viewFinal)
                .disabled(model.mode == .simple)
            Toggle("Show Log", isOn: $showLog)
                .keyboardShortcut("l")
            Divider()
            Button("Reload Toolchain") { model.reloadToolchain() }
            Button("Clear Render Cache…") { model.confirmClearCache = true }
                .disabled(model.isExporting)
        }
        CommandGroup(before: .toolbar) {
            Toggle("Simple Mode", isOn: Binding(get: { model.mode == .simple }, set: { if $0 { model.mode = .simple } }))
                .keyboardShortcut("1")
            Toggle("Advanced Mode", isOn: Binding(get: { model.mode == .advanced }, set: { if $0 { model.mode = .advanced } }))
                .keyboardShortcut("2")
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Third-Party Licenses") { PlatformActions.showLicenses(model) }
                .disabled(!PlatformActions.licensesAvailable)
        }
    }
}
