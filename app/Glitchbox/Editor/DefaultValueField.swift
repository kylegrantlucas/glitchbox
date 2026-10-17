import SwiftUI
import GlitchboxKit

/// Edits a param spec's default with a control matching its type.
struct DefaultValueField: View {
    @Binding var param: EditableParam

    var body: some View {
        let value = param.spec.default
        switch param.spec.type {
        case .int:
            TextField("Default", value: Binding(get: { Int(value.doubleValue ?? 0) }, set: { param.spec.default = .int($0) }),
                      format: .number.grouping(.never))
                .labelsHidden()
        case .float:
            TextField("Default", value: Binding(get: { value.doubleValue ?? 0 }, set: { param.spec.default = .float($0) }),
                      format: .number)
                .labelsHidden()
        case .bool:
            Toggle("Default", isOn: Binding(get: { value.boolValue ?? false }, set: { param.spec.default = .bool($0) }))
                .labelsHidden()
        case .enumeration:
            Picker("Default", selection: Binding(get: { value.stringValue ?? "" }, set: { param.spec.default = .string($0) })) {
                ForEach(Array(param.options.enumerated()), id: \.element) { i, option in
                    let labels = EditableParam.list(param.labelsText)
                    Text(labels.indices.contains(i) ? labels[i] : option).tag(option)
                }
            }
            .labelsHidden()
        case .string, .file:
            TextField("Default", text: Binding(get: { value.stringValue ?? "" }, set: { param.spec.default = .string($0) }))
                .labelsHidden()
        }
    }
}
