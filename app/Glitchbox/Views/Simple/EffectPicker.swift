import GlitchboxKit
import SwiftUI

/// "Add Effect" sheet: every plugin with a `simple` block, by category. Still-input effects
/// are offered only for a photo.
struct EffectPicker: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Effect")
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                                ForEach(section.items) { plugin in
                                    EffectCell(plugin: plugin) {
                                        model.addLayer(plugin: plugin.id)
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 520)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var sections: [(title: String, items: [PluginManifest])] {
        let offered = model.plugins.filter { $0.simple != nil && ($0.input != .still || model.sourceIsStill) }
        return SimpleCatalog.sections(offered, order: SimpleCatalog.effectCategories) { $0.simple?.category ?? "" }
    }
}
