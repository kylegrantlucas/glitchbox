public struct PluginManifest: Codable, Hashable, Sendable, Identifiable {
    public var schema: Int
    public var id: String
    public var name: String
    public var summary: String
    public var requires: [String]
    public var assets: [String]
    public var params: [ParamSpec]
    public var steps: [PluginStep]

    public init(schema: Int = 1, id: String, name: String, summary: String = "",
                requires: [String] = [], assets: [String] = [],
                params: [ParamSpec] = [], steps: [PluginStep] = []) {
        self.schema = schema; self.id = id; self.name = name; self.summary = summary
        self.requires = requires; self.assets = assets; self.params = params; self.steps = steps
    }

    public func defaults() -> [String: ParamValue] {
        Dictionary(params.map { ($0.key, $0.default) }, uniquingKeysWith: { a, _ in a })
    }

    public func spec(_ key: String) -> ParamSpec? { params.first { $0.key == key } }
}
