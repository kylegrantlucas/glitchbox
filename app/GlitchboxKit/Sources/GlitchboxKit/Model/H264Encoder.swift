public enum H264Encoder: String, Codable, CaseIterable, Sendable {
    case videoToolbox, x264

    public var title: String {
        switch self {
        case .videoToolbox: "VideoToolbox (hardware)"
        case .x264: "x264 (software)"
        }
    }

    /// libx264 `-preset` values.
    public static let x264Presets = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]
}
