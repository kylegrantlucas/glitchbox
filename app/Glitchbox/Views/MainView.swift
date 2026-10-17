import SwiftUI

struct MainView: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showInspector = true
    @State private var savingChain = false

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
        .onChange(of: model.mode) { model.saveSession() }
        .sheet(isPresented: $savingChain) {
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
        ToolbarItemGroup(placement: .navigation) {
            EnvStatusView()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Render", systemImage: "play.fill") { model.render() }
                .keyboardShortcut("r")
                .disabled(!model.canRender)
                .help("Render the chain (⌘R)")
            Button("Cancel", systemImage: "stop.fill") { model.cancelRender() }
                .keyboardShortcut(".")
                .disabled(!model.isRendering)
                .help("Cancel the render (⌘.)")
            Picker("Mode", selection: $model.mode) {
                ForEach(RenderMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Preview renders a short low-resolution clip; Full renders the whole source natively")
            Toggle("View Final", systemImage: "film.stack", isOn: $model.viewFinal)
                .help("Play the final output instead of the selected layer")
            Toggle("Auto-render", systemImage: "bolt", isOn: $model.autoRender)
                .help("Re-render automatically after edits")
            Button("Save Chain", systemImage: "square.and.arrow.down") { savingChain = true }
                .keyboardShortcut("s")
                .disabled(model.stack.isEmpty)
            Button("Reveal in Finder", systemImage: "folder") { model.revealInFinder() }
                .disabled(model.viewedOutput == nil && model.selectedItem?.output == nil)
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
        }
    }
}
