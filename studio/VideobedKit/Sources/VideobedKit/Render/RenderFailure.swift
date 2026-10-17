import Foundation

/// A render error attributed to a chain position.
public struct RenderFailure: Error, LocalizedError {
    /// Index into the rendered `layers` array; -1 is the source layer.
    public let index: Int
    public let plugin: String
    public let underlying: any Error

    public init(index: Int, plugin: String, underlying: any Error) {
        self.index = index; self.plugin = plugin; self.underlying = underlying
    }

    public var errorDescription: String? {
        let place = index < 0 ? "source" : "layer \(index + 1) (\(plugin))"
        return "\(place): \(underlying.localizedDescription)"
    }

    public var log: URL? { (underlying as? RenderError)?.log }
}
