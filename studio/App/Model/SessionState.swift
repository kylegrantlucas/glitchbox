import VideobedKit

/// `out/studio/session.json`: the app's last stack, source, and settings.
struct SessionState: Codable {
    var schema = 1
    var source: String?
    var mode: RenderMode
    var previewSettings: RenderSettings
    var layers: [LayerSpec]
}
