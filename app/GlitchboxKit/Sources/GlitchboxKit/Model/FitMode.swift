/// How a picture goes into a box of a different aspect ratio.
public enum FitMode: String, Codable, CaseIterable, Sendable {
    /// Scale to fit inside and pad with black.
    case fit
    /// Scale to cover and crop the overflow.
    case fill
    /// Scale each axis independently.
    case stretch

    public var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        }
    }
}
