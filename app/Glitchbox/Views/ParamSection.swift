import SwiftUI
import GlitchboxKit

/// One collapsible inspector section of a layer's params.
struct ParamSection: View {
    let group: ParamGroup
    let item: LayerItem
    @Binding var isExpanded: Bool
    @Environment(StudioModel.self) private var model

    private func value(_ spec: ParamSpec) -> ParamValue { item.spec.params[spec.key] ?? spec.default }

    private var modifiedCount: Int {
        group.params.filter { value($0) != $0.default }.count
    }

    var body: some View {
        Section {
            if isExpanded {
                ForEach(group.params, id: \.key) { spec in
                    ParamControl(spec: spec, value: value(spec)) {
                        model.setParam(item.id, key: spec.key, value: $0)
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .font(.caption.bold())
                        Text(group.name)
                        if modifiedCount > 0 {
                            Text("\(modifiedCount) changed")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(group.name)" : "Expand \(group.name)")
                Spacer()
                if modifiedCount > 0 {
                    Button("Reset") { model.resetParams(item.id, keys: group.params.map(\.key)) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Reset \(group.name) to the plugin defaults")
                }
            }
        }
    }
}
