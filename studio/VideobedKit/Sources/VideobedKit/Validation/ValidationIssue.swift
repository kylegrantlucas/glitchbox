public struct ValidationIssue: Hashable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
