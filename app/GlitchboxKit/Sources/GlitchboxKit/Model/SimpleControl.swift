/// One Simple-mode control: a declared param under a plain-language label.
public struct SimpleControl: Codable, Hashable, Sendable {
    public var key: String
    public var label: String

    public init(key: String, label: String) {
        self.key = key; self.label = label
    }
}
