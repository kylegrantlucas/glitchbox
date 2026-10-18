/// Explicit colour tags for SDR video, in ffmpeg/ffprobe names.
public struct ColorTags: Hashable, Sendable {
    public var primaries: String
    public var transfer: String
    public var space: String

    public init(primaries: String, transfer: String, space: String) {
        self.primaries = primaries; self.transfer = transfer; self.space = space
    }

    public static let bt709 = ColorTags(primaries: "bt709", transfer: "bt709", space: "bt709")
    public static let smpte170m = ColorTags(primaries: "smpte170m", transfer: "smpte170m", space: "smpte170m")

    /// HLG and PQ transfer functions.
    public static let hdrTransfers: Set<String> = ["arib-std-b67", "smpte2084"]

    /// The usual default for untagged video: bt709 for HD, smpte170m for SD.
    public static func fallback(width: Int, height: Int) -> ColorTags {
        max(width, height) >= 1280 || min(width, height) >= 720 ? .bt709 : .smpte170m
    }

    /// Tags to write for a source: each one from the probe when known, else the size-based
    /// fallback. HDR sources become bt709 throughout: the Y'CbCr matrix is converted, but the
    /// transfer and primaries are relabelled, not tone-mapped.
    public static func resolve(_ video: MediaProbe.Video) -> ColorTags {
        let (w, h) = video.rotatedSize
        if isHDR(video) { return .bt709 }
        let fallback = fallback(width: w, height: h)
        // An RGB source has no Y'CbCr matrix of its own ("gbr").
        let space = video.colorSpace.flatMap { $0 == "gbr" || video.isRGB ? nil : $0 }
        return ColorTags(primaries: video.colorPrimaries ?? fallback.primaries,
                         transfer: video.colorTransfer ?? fallback.transfer,
                         space: space ?? fallback.space)
    }

    public static func isHDR(_ video: MediaProbe.Video) -> Bool {
        video.colorTransfer.map(hdrTransfers.contains) ?? false
    }
}
