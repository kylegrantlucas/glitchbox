/// What a layer reads instead of the previous layer's output.
public enum PluginInput: String, Codable, Hashable, Sendable {
    /// The original still image; the layer must be the first enabled one and renders
    /// the clip that source prep then normalizes (see `Renderer`).
    case still
}
