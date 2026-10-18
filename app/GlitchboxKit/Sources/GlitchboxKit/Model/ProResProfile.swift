public enum ProResProfile: String, Codable, CaseIterable, Sendable {
    case lt, standard, hq
    case p4444 = "4444"

    public var title: String {
        switch self {
        case .lt: "422 LT"
        case .standard: "422"
        case .hq: "422 HQ"
        case .p4444: "4444"
        }
    }

    /// `prores_videotoolbox -profile:v` value.
    var ffmpegProfile: String { rawValue }

    var pixelFormat: String { self == .p4444 ? "p410le" : "p210le" }
}
