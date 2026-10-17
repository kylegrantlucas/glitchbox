public struct PluginPreset: Codable, Hashable, Sendable {
    public var schema: Int
    public var name: String
    public var plugin: String
    public var params: [String: ParamValue]

    public init(schema: Int = 1, name: String, plugin: String, params: [String: ParamValue]) {
        self.schema = schema; self.name = name; self.plugin = plugin; self.params = params
    }
}
