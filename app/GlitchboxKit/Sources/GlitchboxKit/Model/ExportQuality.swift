public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case good, high, max

    public var title: String {
        switch self {
        case .good: "Smaller"
        case .high: "Balanced"
        case .max: "Best"
        }
    }

    /// VideoToolbox `-q:v` (H.264 and HEVC).
    public var videoToolboxQuality: Int {
        switch self {
        case .good: 65
        case .high: 75
        case .max: 85
        }
    }
}
