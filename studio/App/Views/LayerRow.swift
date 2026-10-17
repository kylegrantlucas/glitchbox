import SwiftUI

struct LayerRow: View {
    let item: LayerItem
    @Environment(StudioModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: Binding(get: { item.spec.enabled }, set: { model.setEnabled(item.id, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.plugin(item.spec.plugin)?.name ?? item.spec.plugin)
                    .foregroundStyle(item.spec.enabled ? .primary : .secondary)
                LayerStatusText(status: item.status)
            }
        }
        .padding(.vertical, 2)
    }
}
