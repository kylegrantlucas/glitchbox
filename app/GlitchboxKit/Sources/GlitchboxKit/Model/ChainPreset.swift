public struct ChainPreset: Codable, Hashable, Sendable {
    public var schema: Int
    public var name: String
    public var layers: [LayerSpec]

    public init(schema: Int = 1, name: String, layers: [LayerSpec]) {
        self.schema = schema; self.name = name; self.layers = layers
    }
}
