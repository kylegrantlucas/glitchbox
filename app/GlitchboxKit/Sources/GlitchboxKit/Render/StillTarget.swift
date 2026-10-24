/// The clip a still-input layer renders: source prep's rate and size for the still, and its length.
public struct StillTarget: Codable, Hashable, Sendable {
    /// `FrameRate.ffmpeg`, e.g. "30000/1001".
    public var fps: String
    public var duration: Double
    public var width: Int
    public var height: Int

    public init(fps: String, duration: Double, width: Int, height: Int) {
        self.fps = fps; self.duration = duration; self.width = width; self.height = height
    }
}
