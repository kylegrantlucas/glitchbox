/// `manifest.json` written next to each cached layer output.
struct LayerRecord: Codable, Sendable {
    var schema: Int
    var parent: String
    var plugin: PluginManifest
    var params: [String: ParamValue]
    var files: [String: String]
    var assets: [String: String]
    var toolchain: String
    var still: StillTarget?
    var key: String
    var output: String
    var outputSHA256: String
    var steps: [PluginStep]
    var generatedAt: String
    var elapsedS: Double

    init(_ k: KeyComponents, key: String, output: String, outputSHA256: String,
         steps: [PluginStep], generatedAt: String, elapsedS: Double) {
        schema = k.schema; parent = k.parent; plugin = k.plugin; params = k.params
        files = k.files; assets = k.assets; toolchain = k.toolchain; still = k.still
        self.key = key; self.output = output; self.outputSHA256 = outputSHA256
        self.steps = steps; self.generatedAt = generatedAt; self.elapsedS = elapsedS
    }

    enum CodingKeys: String, CodingKey {
        case schema, parent, plugin, params, files, assets, toolchain, still, key, output, steps
        case outputSHA256 = "output_sha256"
        case generatedAt = "generated_at"
        case elapsedS = "elapsed_s"
    }
}
