public struct LayerSpec: Codable, Hashable, Sendable {
    public var plugin: String
    public var enabled: Bool
    public var params: [String: ParamValue]

    public init(plugin: String, enabled: Bool = true, params: [String: ParamValue] = [:]) {
        self.plugin = plugin; self.enabled = enabled; self.params = params
    }
}
