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

    /// `prores_ks -profile:v` value (0 proxy, 1 lt, 2 standard, 3 hq, 4 4444).
    var proresKSProfile: String {
        switch self {
        case .lt: "1"
        case .standard: "2"
        case .hq: "3"
        case .p4444: "4"
        }
    }

    var pixelFormat: String { self == .p4444 ? "p410le" : "p210le" }
}
