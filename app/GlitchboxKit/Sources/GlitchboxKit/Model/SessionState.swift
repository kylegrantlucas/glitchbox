/// `<user library>/session.json`: the app's last source, render controls, and stack.
///
/// Schema 1 stored a Preview/Full `mode` plus `previewSettings`; decoding migrates it:
/// preview becomes an in/out range at the preview height, full becomes the whole clip at
/// native resolution. Either way the preview's start/duration survive as the in/out points.
public struct SessionState: Codable, Sendable {
    public static let schemaVersion = 2

    public var schema: Int
    public var source: String?
    public var render: RenderOptions
    public var layers: [LayerSpec]

    public init(source: String?, render: RenderOptions, layers: [LayerSpec]) {
        schema = Self.schemaVersion
        self.source = source; self.render = render; self.layers = layers
    }

    private enum CodingKeys: String, CodingKey {
        case schema, source, render, layers
        case mode, previewSettings
    }

    /// Schema 1 `previewSettings`; `fps` was an integer.
    private struct LegacySettings: Decodable {
        var start: Double
        var duration: Double?
        var height: Int?
        var fps: FrameRate
        var stillDuration: Double?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        layers = try c.decode([LayerSpec].self, forKey: .layers)
        schema = Self.schemaVersion
        if let render = try c.decodeIfPresent(RenderOptions.self, forKey: .render) {
            self.render = render
            return
        }
        let old = try c.decode(LegacySettings.self, forKey: .previewSettings)
        let full = try c.decodeIfPresent(String.self, forKey: .mode) == "full"
        render = RenderOptions(range: full ? .whole : .inOut,
                               inPoint: old.start,
                               outPoint: old.duration.map { old.start + $0 },
                               height: full ? nil : old.height,
                               fps: old.fps,
                               stillDuration: old.stillDuration ?? 5)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(render, forKey: .render)
        try c.encode(layers, forKey: .layers)
    }
}
