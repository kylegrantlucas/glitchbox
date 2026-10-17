import SwiftUI
import VideobedKit

struct ParamSpecEditor: View {
    @Binding var params: [EditableParam]

    var body: some View {
        ForEach($params) { $param in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Key", text: $param.spec.key, prompt: Text("key"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Label", text: $param.spec.label, prompt: Text("Label"))
                    Picker("Type", selection: $param.spec.type) {
                        ForEach(ParamType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .onChange(of: param.spec.type) { param.typeChanged() }
                    rowButtons(param.id)
                }
                .labelsHidden()
                HStack {
                    Text("Default").foregroundStyle(.secondary)
                    DefaultValueField(param: $param)
                }
                if param.spec.type == .int || param.spec.type == .float {
                    HStack {
                        TextField("Min", value: $param.spec.min, format: .number, prompt: Text("min"))
                        TextField("Max", value: $param.spec.max, format: .number, prompt: Text("max"))
                        if param.spec.type == .float {
                            TextField("Step", value: $param.spec.step, format: .number, prompt: Text("step"))
                        }
                    }
                    .labelsHidden()
                }
                if param.spec.type == .enumeration {
                    TextField("Options", text: $param.optionsText, prompt: Text("option-a, option-b"))
                        .labelsHidden()
                }
                if param.spec.type == .file {
                    TextField("Extensions", text: $param.extensionsText, prompt: Text("json, toml"))
                        .labelsHidden()
                }
                TextField("Help", text: Binding(get: { param.spec.help ?? "" }, set: { param.spec.help = $0 }), prompt: Text("Help text"))
                    .labelsHidden()
            }
            .padding(.vertical, 4)
        }
        Button("Add Parameter", systemImage: "plus") {
            params.append(EditableParam(ParamSpec(key: "param\(params.count + 1)", label: "Param \(params.count + 1)",
                                                  type: .int, default: .int(0))))
        }
    }

    private func rowButtons(_ id: EditableParam.ID) -> some View {
        let index = params.firstIndex { $0.id == id } ?? 0
        return HStack(spacing: 2) {
            Button("Move Up", systemImage: "chevron.up") { params.swapAt(index, index - 1) }
                .disabled(index == 0)
            Button("Move Down", systemImage: "chevron.down") { params.swapAt(index, index + 1) }
                .disabled(index >= params.count - 1)
            Button("Remove", systemImage: "minus.circle") { params.removeAll { $0.id == id } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}
