public enum OutputSize: Codable, Hashable, Sendable {
    case asRendered
    /// Short side in pixels; the long side keeps the aspect ratio.
    case shortSide(Int)
    case box(width: Int, height: Int, fit: FitMode)

    public static let shortSides = [2160, 1440, 1080, 720, 480, 360]

    /// Social-media frame sizes, filled and cropped.
    public static let social: [(title: String, size: OutputSize)] = [
        ("9:16 (1080 × 1920)", .box(width: 1080, height: 1920, fit: .fill)),
        ("1:1 (1080 × 1080)", .box(width: 1080, height: 1080, fit: .fill)),
        ("4:5 (1080 × 1350)", .box(width: 1080, height: 1350, fit: .fill)),
        ("16:9 (1920 × 1080)", .box(width: 1920, height: 1080, fit: .fill)),
    ]
}
