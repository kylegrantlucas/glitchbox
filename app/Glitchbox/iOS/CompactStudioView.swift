import SwiftUI

/// iPhone layout: the viewer over the source and layer stack; the library and the layer
/// inspector open as sheets.
struct CompactStudioView: View {
    @Environment(StudioModel.self) private var model
    @State private var showLibrary = false
    @State private var showInspector = false
    /// A shared-sheet request made while the library or inspector sheet was up, raised once
    /// that sheet has gone.
    @State private var pendingRequest: (@MainActor () -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ViewerView()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                Divider()
                StackView { id in
                    model.selection = id
                    showInspector = true
                }
            }
            .navigationTitle("Glitchbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Library", systemImage: "books.vertical") { showLibrary = true }
                }
                StudioToolbar()
                ToolbarItemGroup(placement: .bottomBar) {
                    EditButton()
                        .disabled(model.stack.isEmpty)
                    Spacer()
                    Button("Add Layer", systemImage: "plus") { showLibrary = true }
                    Spacer()
                    StudioMoreMenu()
                }
            }
        }
        .sheet(isPresented: $showLibrary, onDismiss: raisePending) {
            NavigationStack {
                LibrarySidebar()
                    .navigationTitle("Library")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", role: .confirm) { showLibrary = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showInspector, onDismiss: raisePending) {
            NavigationStack {
                LayerInspector()
                    .navigationTitle("Layer")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", role: .confirm) { showInspector = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .environment(\.studioSheetRequest, StudioSheetRequest { raise in
            guard showLibrary || showInspector else { raise(); return }
            pendingRequest = raise
            showLibrary = false
            showInspector = false
        })
    }

    private func raisePending() {
        guard !showLibrary, !showInspector, let raise = pendingRequest else { return }
        pendingRequest = nil
        raise()
    }
}

/// Commands that live in the Mac menu bar, for touch: chains, plugins, frames, log, cache.
struct StudioMoreMenu: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.studioSheetRequest) private var request
    @AppStorage(LogPanel.visibleKey) private var showLog = false

    var body: some View {
        @Bindable var model = model
        Menu("More", systemImage: "ellipsis.circle") {
            Section {
                Button("Save Chain…", systemImage: "square.and.arrow.down.on.square") { request { model.showSaveChain = true } }
                    .disabled(model.stack.isEmpty)
                Button("New Plugin…", systemImage: "puzzlepiece.extension") { request { model.showNewPlugin = true } }
                Button("Export Current Frame", systemImage: "photo") { PlatformActions.exportCurrentFrame(model) }
                    .disabled(model.viewedOutput == nil)
            }
            Section {
                Toggle("Auto-render After Edits", systemImage: "arrow.trianglehead.2.clockwise", isOn: $model.autoRender)
                Toggle("Show Log", systemImage: "text.alignleft", isOn: $showLog)
            }
            Section {
                Button("Reload Toolchain", systemImage: "arrow.clockwise") { model.reloadToolchain() }
                Button("Clear Render Cache…", systemImage: "trash", role: .destructive) { request { model.confirmClearCache = true } }
                    .disabled(model.isExporting)
                Button("Third-Party Licenses", systemImage: "doc.text") { request { PlatformActions.showLicenses(model) } }
            }
        }
    }
}
