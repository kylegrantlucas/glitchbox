public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case h264, hevc, prores, ffv1, gif, pngSequence

    public var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .prores: "ProRes"
        case .ffv1: "Lossless (FFV1)"
        case .gif: "Animated GIF"
        case .pngSequence: "PNG Sequence"
        }
    }

    /// Containers this format can be written to; the first is the default.
    public var containers: [ExportContainer] {
        switch self {
        case .h264: [.mp4]
        case .hevc: [.mp4, .mov]
        case .prores: [.mov]
        case .ffv1: [.mkv]
        case .gif: [.gif]
        case .pngSequence: [.folder]
        }
    }

    public var isSequence: Bool { self == .pngSequence }

    /// Whether the Good/High/Max scale applies.
    public var hasQuality: Bool { self == .h264 || self == .hevc }

    /// Whether the output can carry audio (a PNG sequence gets an `audio.wav` beside it).
    public var hasAudio: Bool { self != .gif }

    /// GIF has its own width control instead of the size menu.
    public var usesOutputSize: Bool { self != .gif }
}
