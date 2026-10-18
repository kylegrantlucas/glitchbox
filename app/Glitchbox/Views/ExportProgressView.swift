import SwiftUI

/// Toolbar status of a running export.
struct ExportProgressView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.exportPhase)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                ProgressView(value: model.exportFraction ?? 0)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            .frame(width: 150)
            Button("Cancel Export", systemImage: "xmark.circle.fill") { model.cancelExport() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Cancel the export")
        }
        .accessibilityElement(children: .combine)
    }
}
