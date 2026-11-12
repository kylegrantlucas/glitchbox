public struct ChainPreset: Codable, Hashable, Sendable {
    public var schema: Int
    public var name: String
    public var layers: [LayerSpec]
    /// Section in Simple mode's Looks gallery; nil for user-saved chains.
    public var category: String?

    public init(schema: Int = 1, name: String, layers: [LayerSpec], category: String? = nil) {
        self.schema = schema; self.name = name; self.layers = layers; self.category = category
    }
}
