public enum ParamType: String, Codable, Sendable, CaseIterable {
    case int, float, bool
    case enumeration = "enum"
    case string, file
}
