public struct RenderSettings: Codable, Hashable, Sendable {
    public var start: Double
    /// nil renders to the end of the source.
    public var duration: Double?
    /// nil keeps the native height.
    public var height: Int?
    public var fps: Int
    /// Clip length for still-image sources when `duration` is nil.
    public var stillDuration: Double

    public init(start: Double = 0, duration: Double? = nil, height: Int? = nil,
                fps: Int = 30, stillDuration: Double = 5) {
        self.start = start; self.duration = duration; self.height = height
        self.fps = fps; self.stillDuration = stillDuration
    }
}
