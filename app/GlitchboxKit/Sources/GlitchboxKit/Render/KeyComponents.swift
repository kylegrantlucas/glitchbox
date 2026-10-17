/// Everything that determines a layer's bytes; hashed into its cache key.
struct KeyComponents: Codable, Sendable {
    var schema = 1
    var parent: String
    var plugin: PluginManifest
    var params: [String: ParamValue]
    /// sha256 of each file param's resolved file.
    var files: [String: String]
    /// sha256 of each manifest asset.
    var assets: [String: String]
    /// toolchain.json `digest`.
    var toolchain: String
}
