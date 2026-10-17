/// How a numeric param's slider maps to its range.
public enum ParamScale: String, Codable, Sendable, CaseIterable {
    case linear
    /// Skewed toward `min`, for intensities whose useful values are tiny.
    case log
}
