import GlitchboxKit
import SwiftUI

/// Simple mode's looks (chain presets) as a thumbnail grid by category. Tapping one replaces
/// the effects, asking first when the current ones were adjusted.
struct LooksGallery: View {
    @Environment(StudioModel.self) private var model
    @State private var pendingLook: ChainPreset?
    @State private var deletingLook: ChainPreset?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(section.items, id: \.name) { preset in
                                LookCell(preset: preset,
                                         isApplied: model.appliedLook == preset.name && !model.stack.isEmpty,
                                         missing: model.missingInput(for: preset)) {
                                    choose(preset)
                                }
                                .contextMenu {
                                    if model.origin(of: preset) == .overridden {
                                        Button("Revert to Built-in…") { deletingLook = preset }
                                    } else {
                                        Button("Delete…", role: .destructive) { deletingLook = preset }
                                            .disabled(model.origin(of: preset) == .builtin)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .confirmationDialog("Replace your changes?", isPresented: Binding(get: { pendingLook != nil }, set: { if !$0 { pendingLook = nil } }),
                            presenting: pendingLook) { preset in
            Button("Replace") { model.load(chain: preset, keepingStillInput: true) }
        } message: { preset in
            Text("“\(preset.name)” replaces the effects you've adjusted.")
        }
        .confirmationDialog(deletingTitle,
                            isPresented: Binding(get: { deletingLook != nil }, set: { if !$0 { deletingLook = nil } }),
                            presenting: deletingLook) { preset in
            if model.origin(of: preset) == .overridden {
                Button("Revert “\(preset.name)”", role: .destructive) { model.deleteChain(preset) }
            } else {
                Button("Delete “\(preset.name)”", role: .destructive) { model.deleteChain(preset) }
            }
        }
    }

    private var sections: [(title: String, items: [ChainPreset])] {
        SimpleCatalog.sections(model.chainPresets, order: SimpleCatalog.lookCategories) { $0.category ?? SimpleCatalog.userLooks }
    }

    private func choose(_ preset: ChainPreset) {
        if model.lookIsModified { pendingLook = preset } else { model.load(chain: preset, keepingStillInput: true) }
    }

    private var deletingTitle: String {
        if let deletingLook, model.origin(of: deletingLook) == .overridden { return "Revert look to built-in?" }
        return "Delete look?"
    }
}
