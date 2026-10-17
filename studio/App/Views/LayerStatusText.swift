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
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(why)
            case .running(let step, let of, let name):
                ProgressView().controlSize(.mini)
                Text(of > 0 ? "step \(step)/\(of) \(name)" : name)
            case .done(let cached):
                Label(cached ? "cached" : "done", systemImage: cached ? "bolt.circle" : "checkmark.circle")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).help(message)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
