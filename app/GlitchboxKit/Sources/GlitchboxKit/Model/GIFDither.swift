public enum GIFDither: String, Codable, CaseIterable, Sendable {
    case none, bayer
    case floydSteinberg = "floyd_steinberg"
    case sierra2_4a

    public var title: String {
        switch self {
        case .none: "None"
        case .bayer: "Bayer"
        case .floydSteinberg: "Floyd-Steinberg"
        case .sierra2_4a: "Sierra Lite"
        }
    }
}
