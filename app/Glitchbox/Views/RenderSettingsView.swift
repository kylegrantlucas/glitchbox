import GlitchboxKit
import SwiftUI

struct RenderSettingsView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            if model.sourceIsStill {
                GridRow {
                    Text("Duration")
                    TextField("Duration", value: $model.renderOptions.stillDuration, format: .number)
                        .frame(width: 70)
                        .help("Seconds of video made from the still image")
                }
            } else {
                GridRow {
                    Text("Range")
                    Picker("Range", selection: $model.renderOptions.range) {
                        Text("Whole clip").tag(RenderOptions.Range.whole)
                        Text("In/Out").tag(RenderOptions.Range.inOut)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .gridCellColumns(3)
                }
                if model.renderOptions.range == .inOut {
                    GridRow {
                        Text("In")
                        TextField("In", value: $model.renderOptions.inPoint, format: .number)
                            .frame(width: 70)
                            .help("Seconds into the source")
                        Text("Out")
                        TextField("Out", value: $model.renderOptions.outPoint, format: .number)
                            .frame(width: 70)
                            .help("Seconds into the source; empty renders to the end")
                    }
                }
            }
            GridRow {
                Text("Size")
                ResolutionPicker(title: "Size", selection: $model.renderOptions.height)
                    .labelsHidden()
                Text("FPS")
                FrameRatePicker(selection: $model.renderOptions.fps,
                                sourceRate: model.sourceIsStill ? nil : model.sourceProbe?.video?.frameRate)
                    .labelsHidden()
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
    }
}
