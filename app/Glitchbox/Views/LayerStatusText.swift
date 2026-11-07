import SwiftUI

struct LayerStatusText: View {
    let status: LayerStatus

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .idle:
                Text("idle").foregroundStyle(.secondary)
            case .disabled:
                Text("disabled").foregroundStyle(.secondary)
            case .unavailable(let why):
                iconText(why, "exclamationmark.triangle").foregroundStyle(.orange).help(why)
            case .running(let step, let of, let name):
                ProgressView().controlSize(.mini)
                Text(of > 0 ? "step \(step)/\(of) \(name)" : name)
            case .done(let cached):
                iconText(cached ? "cached" : "done", cached ? "bolt.circle" : "checkmark.circle")
                    .foregroundStyle(.green)
            case .failed(let message):
                iconText(message, "xmark.octagon").foregroundStyle(.red).help(message)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// Icon and text side by side. Not a `Label`: inside an iOS List row, a Label's icon
    /// takes the row's wide leading icon column.
    private func iconText(_ text: String, _ systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
    }
}
