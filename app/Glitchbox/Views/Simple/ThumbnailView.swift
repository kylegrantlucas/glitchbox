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
            .task(id: url) { image = if let url { await Self.image(url) } else { nil } }
    }

    /// Decoded thumbnails by URL, so scrolling a cell back into view or redrawing the gallery
    /// doesn't read and decode the JPEG again.
    nonisolated(unsafe) private static let cache = NSCache<NSURL, CGImage>()

    private static func image(_ url: URL) async -> CGImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) { decode(url) }.value
        if let decoded { cache.setObject(decoded, forKey: url as NSURL) }
        return decoded
    }

    /// Decodes now (off the main thread) instead of lazily at first draw.
    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
