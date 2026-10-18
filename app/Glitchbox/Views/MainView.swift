import GlitchboxKit
import SwiftUI

struct MainView: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            StackView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            ViewerView()
        }
        .inspector(isPresented: $showInspector) {
            LayerInspector()
                .inspectorColumnWidth(min: 260, ideal: 320)
        }
        .toolbar { toolbar }
        .onChange(of: model.source) { model.inputsChanged() }
        .onChange(of: model.effectiveSettings) { model.inputsChanged() }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(settings: model.exportSettings, render: exportRender)
        }
        .sheet(isPresented: $model.showSaveChain) {
            NameSheet(title: "Save Chain", actionTitle: "Save", existsMessage: "A chain with this name exists. Replace it?",
                      exists: model.chainExists(name:)) { name in
                try model.saveChain(name: name)
            }
        }
        .sheet(isPresented: $model.showNewPlugin) {
            NameSheet(title: "New Plugin", actionTitle: "Create") { name in
                let id = try model.createPlugin(name: name)
                openWindow(id: "plugin-editor", value: id)
            }
        }
        .confirmationDialog("Clear the render cache?", isPresented: $model.confirmClearCache) {
            Button("Clear Cache", role: .destructive) { model.clearCache() }
        } message: {
            Text("Removes every cached layer in \(model.workspace.layersDir.path).")
        }
        .frame(minWidth: 1100, minHeight: 640)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        if model.environment == nil {
            ToolbarItem(placement: .navigation) {
                EnvStatusView()
            }
        }
        // Four items: everything else lives in the File and Render menus.
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isRendering {
                Button("Stop", systemImage: "stop.fill") { model.cancelRender() }
                    .help("Stop the render (⌘.)")
            } else {
                Menu("Render", systemImage: "play.fill") {
                    Toggle("Auto-render After Edits", isOn: $model.autoRender)
                } primaryAction: {
                    model.render()
                }
                .disabled(!model.canRender)
                .help(model.autoRender ? "Render the chain (⌘R). Auto-render is on." : "Render the chain (⌘R)")
            }
            if model.isExporting {
                ExportProgressView()
            } else {
                Button("Export…", systemImage: "square.and.arrow.up") { model.showExport = true }
                    .disabled(!model.canRender)
                    .help("Export the chain to a movie, GIF, or image sequence (⌘E)")
            }
            Toggle("View Final", systemImage: "film.stack", isOn: $model.viewFinal)
                .help("Play the final output instead of the selected layer")
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
        }
    }

    /// The export renders the whole clip at native size by default, at the current frame rate.
    private var exportRender: RenderOptions {
        var options = model.renderOptions
        options.range = .whole
        options.height = nil
        return options
    }
}
