import SwiftUI

struct StackView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SourceSection()
            Divider()
            StillSuggestionView()
            List(selection: $model.selection) {
                ForEach(model.stack) { item in
                    LayerRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Remove Layer", role: .destructive) { model.removeLayer(item.id) }
                        }
                }
                .onMove { model.moveLayers($0, to: $1) }
                .onDelete { model.removeLayers($0) }
            }
            .onDeleteCommand {
                if let id = model.selection { model.removeLayer(id) }
            }
            .overlay {
                if model.stack.isEmpty {
                    ContentUnavailableView("No Layers", systemImage: "square.stack.3d.up",
                                           description: Text("Add plugins from the sidebar or load a chain."))
                }
            }
            NoticesView()
            ExportOutcomeView()
        }
    }
}
