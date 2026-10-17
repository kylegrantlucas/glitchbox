public struct PluginStep: Codable, Hashable, Sendable {
    public var name: String
    public var argv: [String]?
    public var script: String?

    public init(name: String, argv: [String]? = nil, script: String? = nil) {
        self.name = name; self.argv = argv; self.script = script
    }
}
