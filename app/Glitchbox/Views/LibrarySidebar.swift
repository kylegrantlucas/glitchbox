import SwiftUI
import GlitchboxKit

struct LibrarySidebar: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var pendingChain: ChainPreset?
    @State private var deletingChain: ChainPreset?

    var body: some View {
        List {
            Section("Chains") {
                ForEach(model.chainPresets, id: \.name) { preset in
                    Button {
                        if model.stack.isEmpty { model.load(chain: preset) } else { pendingChain = preset }
                    } label: {
                        Label(preset.name, systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.origin(of: preset) == .overridden {
                            Button("Revert to Built-in…") { deletingChain = preset }
                        } else {
                            Button("Delete…", role: .destructive) { deletingChain = preset }
                                .disabled(model.origin(of: preset) == .builtin)
                        }
                    }
                }
            }
            Section("Plugins") {
                ForEach(model.plugins) { plugin in
                    PluginLibraryRow(plugin: plugin)
                }
            }
            if !model.pluginIssues.isEmpty {
                Section("Invalid plugins") {
                    ForEach(model.pluginIssues.keys.sorted(), id: \.self) { file in
                        Label(file, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(model.pluginIssues[file, default: []].map(\.message).joined(separator: "\n"))
                            .contextMenu {
                                Button("Edit") { openWindow(id: "plugin-editor", value: String(file.dropLast(".json".count))) }
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("New Plugin…", systemImage: "plus") { model.showNewPlugin = true }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .confirmationDialog("Replace current stack?", isPresented: Binding(get: { pendingChain != nil }, set: { if !$0 { pendingChain = nil } }),
                            presenting: pendingChain) { preset in
            Button("Replace") { model.load(chain: preset) }
        } message: { preset in
            Text("Loading “\(preset.name)” replaces the layers in the stack.")
        }
        .confirmationDialog(deletingTitle,
                            isPresented: Binding(get: { deletingChain != nil }, set: { if !$0 { deletingChain = nil } }),
                            presenting: deletingChain) { preset in
            if model.origin(of: preset) == .overridden {
                Button("Revert “\(preset.name)”", role: .destructive) { model.deleteChain(preset) }
            } else {
                Button("Delete “\(preset.name)”", role: .destructive) { model.deleteChain(preset) }
            }
        }
    }

    private var deletingTitle: String {
        if let deletingChain, model.origin(of: deletingChain) == .overridden { return "Revert chain preset to built-in?" }
        return "Delete chain preset?"
    }
}
