public struct PluginStep: Codable, Hashable, Sendable {
    public var name: String
    public var argv: [String]?
    public var script: String?
    /// An engine-provided implementation id (see `ToolRunner.native`), used whenever the
    /// runner has it; otherwise argv, then script.
    public var native: String?

    public init(name: String, argv: [String]? = nil, script: String? = nil, native: String? = nil) {
        self.name = name; self.argv = argv; self.script = script; self.native = native
    }
}
