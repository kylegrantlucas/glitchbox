import SwiftUI

struct RenderSettingsView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let preview = model.mode == .preview
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Start")
                TextField("Start", value: $model.previewSettings.start, format: .number)
                    .frame(width: 70)
                    .disabled(!preview)
                Text("Duration")
                TextField("Duration", value: $model.previewSettings.duration, format: .number)
                    .frame(width: 70)
                    .disabled(!preview)
                    .help("Seconds; empty renders to the end")
            }
            GridRow {
                Text("Height")
                Picker("Height", selection: $model.previewSettings.height) {
                    ForEach([360, 480, 720, 1080], id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
                    Text("Native").tag(Int?.none)
                }
                .labelsHidden()
                .disabled(!preview)
                Text("FPS")
                Picker("FPS", selection: $model.previewSettings.fps) {
                    ForEach([24, 25, 30, 60], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
    }
}
