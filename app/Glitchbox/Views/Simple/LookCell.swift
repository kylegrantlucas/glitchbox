import GlitchboxKit
import SwiftUI

/// One look in the gallery: thumbnail over name, outlined while it is the applied look.
struct LookCell: View {
    let preset: ChainPreset
    let isApplied: Bool
    /// What the look lacks on this source ("Needs a photo", "Needs sound"), and whether that rules it out.
    let missing: (note: String, blocks: Bool)?
    let action: () -> Void
    @Environment(StudioModel.self) private var model

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                ThumbnailView(url: model.workspace.lookThumbnail(name: preset.name))
                    .overlay {
                        if isApplied {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 3)
                        }
                    }
                Text(preset.name)
                    .font(.caption)
                    .lineLimit(1)
                if let missing {
                    Text(missing.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(missing?.blocks ?? false)
        .accessibilityAddTraits(isApplied ? .isSelected : [])
    }
}
