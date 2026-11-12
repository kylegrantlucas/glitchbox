import SwiftUI

struct StackView: View {
    /// Compact (iPhone) layouts open the inspector for a tapped layer instead of selecting it in place.
    var openLayer: ((LayerItem.ID) -> Void)?
    @Environment(StudioModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SourceSection()
            Divider()
            StillSuggestionView()
            layers
            .overlay {
                if model.stack.isEmpty {
                    ContentUnavailableView("No Layers", systemImage: "square.stack.3d.up",
                                           description: Text("Add plugins from the library or load a chain."))
                }
            }
            NoticesView()
            ExportOutcomeView()
        }
    }

    @ViewBuilder private var layers: some View {
        @Bindable var model = model
        if let openLayer {
            List {
                ForEach(model.stack) { item in
                    Button { openLayer(item.id) } label: {
                        HStack {
                            LayerRow(item: item)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                    .contextMenu { removeButton(item) }
                }
                .onMove { model.moveLayers($0, to: $1) }
                .onDelete { model.removeLayers($0) }
            }
        } else {
            List(selection: $model.selection) {
                ForEach(model.stack) { item in
                    LayerRow(item: item)
                        .tag(item.id)
                        .contextMenu { removeButton(item) }
                }
                .onMove { model.moveLayers($0, to: $1) }
                .onDelete { model.removeLayers($0) }
            }
            #if os(macOS)
            .onDeleteCommand {
                if let id = model.selection { model.removeLayer(id) }
            }
            #endif
        }
    }

    private func removeButton(_ item: LayerItem) -> some View {
        Button("Remove Layer", role: .destructive) { model.removeLayer(item.id) }
    }
}
