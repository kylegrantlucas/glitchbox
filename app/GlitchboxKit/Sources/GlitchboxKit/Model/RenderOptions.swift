/// The app's render controls: range, resolution, frame rate, and still duration.
public struct RenderOptions: Codable, Hashable, Sendable {
    public enum Range: String, Codable, CaseIterable, Sendable {
        case whole, inOut
    }

    public var range: Range
    /// Seconds into the source; used when `range` is `.inOut`.
    public var inPoint: Double
    /// nil runs to the end of the source.
    public var outPoint: Double?
    /// Short side in pixels; nil is native.
    public var height: Int?
    /// nil matches the source rate.
    public var fps: FrameRate?
    public var stillDuration: Double

    /// Resolution choices besides native.
    public static let heights = [360, 480, 720, 1080]

    public init(range: Range = .inOut, inPoint: Double = 0, outPoint: Double? = 5, height: Int? = 480,
                fps: FrameRate? = nil, stillDuration: Double = 5) {
        self.range = range; self.inPoint = inPoint; self.outPoint = outPoint
        self.height = height; self.fps = fps; self.stillDuration = stillDuration
    }

    /// Engine settings. Still images ignore the range and last `stillDuration` seconds.
    public func settings(still: Bool) -> RenderSettings {
        guard !still, range == .inOut else {
            return RenderSettings(start: 0, duration: nil, height: height, fps: fps, stillDuration: stillDuration)
        }
        let start = max(0, inPoint)
        return RenderSettings(start: start, duration: outPoint.map { max(0, $0 - start) }, height: height,
                              fps: fps, stillDuration: stillDuration)
    }
}
