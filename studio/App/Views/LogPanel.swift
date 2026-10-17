import SwiftUI

/// Tail of the current log; polls while a render or environment resolve runs.
struct LogPanel: View {
    @Environment(StudioModel.self) private var model
    @State private var text = ""

    private struct Watch: Equatable {
        let url: URL?
        let live: Bool
    }

    var body: some View {
        let live: Bool = {
            if model.isRendering { return true }
            if case .resolving = model.envState { return true }
            return false
        }()
        ScrollView {
            Text(text.isEmpty ? "No log" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .background(.background.secondary)
        .task(id: Watch(url: model.logURL, live: live)) {
            repeat {
                text = Self.tail(model.logURL, lines: 200)
                guard live else { return }
                try? await Task.sleep(for: .milliseconds(500))
            } while !Task.isCancelled
        }
    }

    private static func tail(_ url: URL?, lines: Int) -> String {
        guard let url, let data = try? Data(contentsOf: url) else { return "" }
        let all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }
}
