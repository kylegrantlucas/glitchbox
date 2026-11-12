import ImageIO
import SwiftUI

/// A 16:9 library thumbnail (`presets/thumbnails`); a placeholder while loading, for a nil
/// URL (the user's own looks have no picture), or for an unreadable file.
struct ThumbnailView: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .task(id: url) { image = url.flatMap(Self.load) }
    }

    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
