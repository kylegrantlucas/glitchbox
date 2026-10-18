import SwiftUI

/// The last export's result: a Reveal in Finder link, or the failure and its log tail.
struct ExportOutcomeView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        if let outcome = model.exportOutcome {
            VStack(alignment: .leading, spacing: 6) {
                switch outcome {
                case .finished(let url):
                    HStack {
                        Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") { model.revealExport() }
                        dismissButton
                    }
                case .failed(let message, let tail):
                    HStack(alignment: .firstTextBaseline) {
                        Label("Export failed: \(message)", systemImage: "exclamationmark.triangle")
                            .textSelection(.enabled)
                        Spacer()
                        dismissButton
                    }
                    if !tail.isEmpty {
                        ScrollView {
                            Text(tail.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .background(outcomeTint.opacity(0.12))
        }
    }

    private var dismissButton: some View {
        Button("Dismiss", systemImage: "xmark") { model.exportOutcome = nil }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
    }

    private var outcomeTint: Color {
        if case .failed = model.exportOutcome { return .red }
        return .green
    }
}
