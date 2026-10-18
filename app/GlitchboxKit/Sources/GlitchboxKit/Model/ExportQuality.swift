public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case good, high, max

    public var title: String {
        switch self {
        case .good: "Good"
        case .high: "High"
        case .max: "Max"
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

    /// libx264 `-crf`.
    public var x264CRF: Int {
        switch self {
        case .good: 23
        case .high: 18
        case .max: 14
        }
    }
}
