public struct RenderSettings: Codable, Hashable, Sendable {
    public var start: Double
    /// nil renders to the end of the source.
    public var duration: Double?
    /// Short side in pixels (height for landscape, width for portrait); nil keeps the native size.
    public var height: Int?
    /// nil matches the source rate, snapped to `FrameRate.standard`.
    public var fps: FrameRate?
    /// Clip length for still-image sources when `duration` is nil.
    public var stillDuration: Double

    public init(start: Double = 0, duration: Double? = nil, height: Int? = nil,
                fps: FrameRate? = nil, stillDuration: Double = 5) {
        self.start = start; self.duration = duration; self.height = height
        self.fps = fps; self.stillDuration = stillDuration
    }
}
