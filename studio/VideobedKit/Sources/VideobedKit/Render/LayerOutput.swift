import Foundation

public struct LayerOutput: Hashable, Sendable {
    public let key: String
    public let dir: URL
    public let output: URL
    public let cached: Bool

    public init(key: String, dir: URL, output: URL, cached: Bool) {
        self.key = key; self.dir = dir; self.output = output; self.cached = cached
    }
}
