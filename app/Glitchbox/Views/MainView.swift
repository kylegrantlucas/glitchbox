import GlitchboxKit
import SwiftUI

/// The three-column studio: library, layer stack, viewer, with the layer inspector beside
/// them. The Mac window and wide iPad windows use it (see `StudioRootView`).
struct MainView: View {
    @Environment(StudioModel.self) private var model
    @State private var showInspector = true

    #if os(iOS)
    /// iPad: the stack and the viewer side by side (`.balanced` tiles them instead of
    /// overlaying the viewer); the library opens from the sidebar button.
    @State private var columns = NavigationSplitViewVisibility.doubleColumn
    #else
    @State private var columns = NavigationSplitViewVisibility.all
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            StackView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            ViewerView()
                #if os(iOS)
                // On iPadOS the inspector belongs to the detail column, so it shares that
                // column's navigation bar; attached to the whole split view it floats over
                // the detail and hides its toolbar.
                .inspector(isPresented: $showInspector) { inspector }
                .toolbar {
                    toolbar
                    ToolbarItem(placement: .secondaryAction) { StudioMoreMenu() }
                }
                #endif
        }
        #if os(iOS)
        .navigationSplitViewStyle(.balanced)
        #else
        .inspector(isPresented: $showInspector) { inspector }
        .toolbar { toolbar }
        // iOS applies these above the layout switch, in `StudioRootView`.
        .modifier(StudioPresentations())
        .frame(minWidth: 1100, minHeight: 640)
        #endif
    }
}

extension MainView {
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        StudioToolbar()
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
        }
    }

    private var inspector: some View {
        LayerInspector()
            .inspectorColumnWidth(min: 260, ideal: 320)
    }
}

/// Raises a request for one of the shared sheets. Views inside a sheet of their own (the
/// compact library and inspector) get one that dismisses that sheet first, since a presenter
/// shows one sheet at a time; elsewhere it raises the request at once.
struct StudioSheetRequest {
    let handler: @MainActor (@escaping @MainActor () -> Void) -> Void

    @MainActor func callAsFunction(_ raise: @escaping @MainActor () -> Void) { handler(raise) }
}

extension EnvironmentValues {
    @Entry var studioSheetRequest = StudioSheetRequest { $0() }
}

/// Sheets, dialogs, and change hooks every studio layout shares.
struct StudioPresentations: ViewModifier {
    @Environment(StudioModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
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
                    model.editPlugin(id)
                }
            }
            .confirmationDialog("Clear the render cache?", isPresented: $model.confirmClearCache) {
                Button("Clear Cache", role: .destructive) { model.clearCache() }
            } message: {
                Text("Removes every cached layer in \(model.workspace.layersDir.path).")
            }
            .modifier(PluginEditorPresentation())
    }

    /// The export renders the whole clip at native size by default, at the current frame rate.
    private var exportRender: RenderOptions {
        var options = model.renderOptions
        options.range = .whole
        options.height = nil
        return options
    }
}

/// Render, Export, and View Final; everything else lives in the menus.
struct StudioToolbar: ToolbarContent {
    @Environment(StudioModel.self) private var model
    @Environment(\.studioSheetRequest) private var request

    var body: some ToolbarContent {
        @Bindable var model = model
        if model.environment == nil {
            ToolbarItem(placement: .navigation) {
                EnvStatusView()
            }
        }
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
                Button("Export…", systemImage: "square.and.arrow.up") { request { model.showExport = true } }
                    .disabled(!model.canRender)
                    .help("Export the chain to a movie, GIF, or image sequence (⌘E)")
            }
            Toggle("View Final", systemImage: "film.stack", isOn: $model.viewFinal)
                .help("Play the final output instead of the selected layer")
        }
    }
}
