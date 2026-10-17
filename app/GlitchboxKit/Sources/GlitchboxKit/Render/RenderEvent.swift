import Foundation

public enum RenderEvent: Sendable {
    /// `index` is the position in the rendered `layers` array; -1 is the source layer.
    case layerStarted(index: Int, plugin: String)
    /// `log` is the layer's in-progress log file.
    case step(index: Int, step: Int, of: Int, name: String, log: URL)
    case layerFinished(index: Int, LayerOutput)
    case finished(LayerOutput)
}
