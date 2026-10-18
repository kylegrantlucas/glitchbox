public struct GIFOptions: Codable, Hashable, Sendable {
    /// nil keeps the rendered width.
    public var width: Int?
    public var fps: Int
    public var dither: GIFDither
    /// Bayer pattern scale, 0–5; only used with `.bayer`.
    public var bayerScale: Int
    public var palette: GIFPalette
    /// Times the animation plays; 0 loops forever.
    public var plays: Int

    public static let widths = [320, 480, 640, 800]
    /// GIF frame delays are in 1/100 s, so these rates are exact or close.
    public static let frameRates = [10, 12, 15, 20, 25]

    public init(width: Int? = 480, fps: Int = 15, dither: GIFDither = .sierra2_4a, bayerScale: Int = 3,
                palette: GIFPalette = .global, plays: Int = 0) {
        self.width = width; self.fps = fps; self.dither = dither; self.bayerScale = bayerScale
        self.palette = palette; self.plays = plays
    }

    /// ffmpeg gif muxer `-loop`: 0 forever, -1 once, N repeats after the first play.
    var muxerLoop: Int { plays <= 0 ? 0 : plays == 1 ? -1 : plays - 1 }
}
