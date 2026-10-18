public enum GIFPalette: String, Codable, CaseIterable, Sendable {
    /// One palette for the whole clip, built from what changes between frames.
    case global
    /// A new palette for every frame.
    case perFrame

    public var title: String {
        switch self {
        case .global: "Global"
        case .perFrame: "Per frame"
        }
    }
}
