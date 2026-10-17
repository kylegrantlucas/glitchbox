import SwiftUI

struct StepEditor: View {
    @Binding var steps: [EditableStep]

    var body: some View {
        ForEach($steps) { $step in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Name", text: $step.name, prompt: Text("step name"))
                        .labelsHidden()
                    Picker("Mode", selection: $step.mode) {
                        ForEach(EditableStep.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                    rowButtons(step.id)
                }
                Group {
                    switch step.mode {
                    case .argv: TextEditor(text: $step.argvText)
                    case .script: TextEditor(text: $step.script)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110)
                .help(step.mode == .argv ? "One argument per line; blank lines are dropped" : "Runs as bash -euo pipefail -c")
            }
            .padding(.vertical, 4)
        }
        Button("Add Step", systemImage: "plus") {
            steps.append(EditableStep(.init(name: "step\(steps.count + 1)", argv: ["ffmpeg"])))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Argv placeholders: {in} {out} {work} {root} {params} {source_audio} {p.<key>} — write {{ and }} for literal braces.")
            Text("Script variables: $VB_IN $VB_OUT $VB_WORK $VB_ROOT $VB_PARAMS $VB_SOURCE_AUDIO $VB_P_<KEY> (scripts are not template-expanded).")
            Text("{params} / $VB_PARAMS is a JSON file of the resolved params; {source_audio} is the source's trimmed audio, or empty.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func rowButtons(_ id: EditableStep.ID) -> some View {
        let index = steps.firstIndex { $0.id == id } ?? 0
        return HStack(spacing: 2) {
            Button("Move Up", systemImage: "chevron.up") { steps.swapAt(index, index - 1) }
                .disabled(index == 0)
            Button("Move Down", systemImage: "chevron.down") { steps.swapAt(index, index + 1) }
                .disabled(index >= steps.count - 1)
            Button("Remove", systemImage: "minus.circle") { steps.removeAll { $0.id == id } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}
