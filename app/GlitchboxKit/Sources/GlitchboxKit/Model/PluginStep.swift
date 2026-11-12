public struct PluginStep: Codable, Hashable, Sendable {
    public var name: String
    public var argv: [String]?
    public var script: String?
    /// An engine-provided implementation id (see `ToolRunner.native`), used when the runner
    /// can run neither `argv[0]` nor bash.
    public var native: String?

    public init(name: String, argv: [String]? = nil, script: String? = nil, native: String? = nil) {
        self.name = name; self.argv = argv; self.script = script; self.native = native
    }
}
