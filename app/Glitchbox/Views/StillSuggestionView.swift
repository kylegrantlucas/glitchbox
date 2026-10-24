import SwiftUI

/// Offers Still Motion (the still-input plugin) when the source is a still image.
/// One line of truncating text: a wrapping Text here made the window loop on constraint
/// updates and abort at launch (macOS 27).
struct StillSuggestionView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        if let plugin = model.suggestedStillPlugin {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label("Animate this still?", systemImage: "photo")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Spacer(minLength: 0)
                    Button("Add \(plugin.name)") { model.addLayer(plugin: plugin.id) }
                        .controlSize(.small)
                    Button {
                        model.dismissStillSuggestion()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Don't suggest \(plugin.name) for this image")
                    .accessibilityLabel("Dismiss")
                }
                .help("A still image glitches as a frozen frame. \(plugin.name) gives it camera motion first.")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
                Divider()
            }
        }
    }
}
