import Foundation

/// The implicit first layer: trims, rescales, and normalizes the source to constant-fps,
/// video-only, explicitly colour-tagged ffvhuff, and extracts its audio (same trim) to
/// `audio.wav` beside it for layers that react to sound and for export.
///
/// - Frame rate: MPEG-2 (`mpeg2-mosh`) rewrites non-standard rates and changes the frame
///   count, so "match source" snaps to `FrameRate.standard`.
/// - Size: anamorphic pixels are made square; the height setting is the short side, so
///   portrait sources keep their shape; native odd sizes lose a row/column by cropping.
/// - Colour: tags come from the probe, with a size-based fallback (`ColorTags`).
public enum SourcePrep {
    public static let stillExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "tif", "tiff", "webp"]

    public static func isStill(_ url: URL) -> Bool {
        stillExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether source prep decodes `video` with VideoToolbox: 8-bit 4:2:0 (`yuv420p`) H.264 and
    /// HEVC whose stream tags its matrix and limited range, as phone and camera footage does.
    /// Their decoding is bit-exact by spec and prep then converts nothing, so frames match
    /// FFmpeg's software decoders (framemd5: native, scaled, rotated, 4K), while a 4K HEVC source
    /// costs about 1% of the CPU. Everything else stays in software, because the frames differ:
    /// VideoToolbox guesses a matrix for untagged streams (BT.2020 at UHD), so prep's relabel
    /// becomes a conversion; its 10-bit frames arrive as `p010le`, which converts to `yuv420p`
    /// with different rounding; its ProRes decoder differs from FFmpeg's. ffmpeg decodes in
    /// software when a session can't open. iOS stays in software until hardware sessions are
    /// proven inside a backgrounded `BGContinuedProcessingTask`.
    public static func decodesInHardware(_ video: MediaProbe.Video) -> Bool {
        #if os(macOS)
        ["h264", "hevc"].contains(video.codec) && video.pixelFormat == "yuv420p"
            && video.colorSpace != nil && ColorTags.resolve(video).space == video.colorSpace
            && video.colorRange == "tv"
        #else
        false
        #endif
    }

    /// File name of the trimmed source audio inside the source layer's directory.
    public static let audioFileName = "audio.wav"

    /// The rate a render uses: the explicit one, else the source's snapped to the standard set.
    /// Stills have no rate of their own and default to 30.
    public static func frameRate(settings: RenderSettings, video: MediaProbe.Video, still: Bool) -> FrameRate {
        if let fps = settings.fps { return fps }
        guard !still, let source = video.frameRate else { return .fps30 }
        return FrameRate.nearestStandard(to: source)
    }

    /// The size source prep produces for `video`.
    public static func outputSize(settings: RenderSettings, video: MediaProbe.Video) -> (width: Int, height: Int) {
        let (w, h) = video.squareSize
        guard let short = settings.height.map(evenFloor) else { return (w - w % 2, h - h % 2) }
        if h > w { return (short, roundEven(Double(h) * Double(short) / Double(w))) }
        return (roundEven(Double(w) * Double(short) / Double(h)), short)
    }

    /// The clip a still-input layer renders for a still `video`: the rate and size source prep
    /// would use for it, and the still's length.
    public static func stillTarget(settings: RenderSettings, video: MediaProbe.Video) -> StillTarget {
        let (w, h) = outputSize(settings: settings, video: video)
        return StillTarget(fps: frameRate(settings: settings, video: video, still: true).ffmpeg,
                           duration: settings.duration ?? settings.stillDuration, width: w, height: h)
    }

    /// Generated per settings and probe; never written to `plugins/`. `tags` overrides the
    /// probed tags (a still-input layer's clip keeps the original still's).
    public static func manifest(settings: RenderSettings, video: MediaProbe.Video, audio: MediaProbe.Audio?,
                                still: Bool, tags: ColorTags? = nil) -> PluginManifest {
        let duration = settings.duration ?? (still ? settings.stillDuration : -1)
        let fps = frameRate(settings: settings, video: video, still: still)
        let tags = tags ?? ColorTags.resolve(video)
        let params = [
            ParamSpec(key: "start", label: "Start", type: .float, default: .float(settings.start)),
            ParamSpec(key: "duration", label: "Duration", type: .float, default: .float(duration)),
            ParamSpec(key: "height", label: "Height", type: .int, default: .int(settings.height ?? 0)),
            ParamSpec(key: "fps", label: "FPS", type: .string, default: .string(fps.ffmpeg)),
            ParamSpec(key: "still", label: "Still", type: .bool, default: .bool(still)),
        ]

        var filters = ["fps={p.fps}"]
        if !video.hasSquarePixels { filters.append("scale=trunc(iw*sar/2)*2:ih:flags=lanczos,setsar=1") }
        let (w, h) = video.squareSize
        if let short = settings.height.map(evenFloor) {
            filters.append(h > w ? "scale=\(short):-2:flags=lanczos" : "scale=-2:\(short):flags=lanczos")
        } else if w % 2 != 0 || h % 2 != 0 {
            filters.append("crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0")
        }
        // ffmpeg converts the matrix and range to match -colorspace/-color_range (it only
        // relabels untagged input); primaries and transfer take effect only via setparams.
        filters.append("format=yuv420p")
        // VideoToolbox frames lose the stream's chroma location, which software decoding keeps
        // unless a scale resets it; restating it keeps the hardware path's out.mkv byte-identical,
        // not only its pixels.
        let hardware = !still && decodesInHardware(video)
        let scales = filters.contains { $0.hasPrefix("scale=") }
        let chroma = hardware && !scales ? video.chromaLocation.map { ":chroma_location=\($0)" } ?? "" : ""
        filters.append("setparams=color_primaries=\(tags.primaries):color_trc=\(tags.transfer)\(chroma)")

        var argv = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error"]
        if still { argv += ["-loop", "1", "-framerate", "{p.fps}"] }
        else if hardware { argv += ["-hwaccel", "videotoolbox"] }
        if settings.start > 0 { argv += ["-ss", "{p.start}"] }
        if duration >= 0 { argv += ["-t", "{p.duration}"] }
        // Two encoder threads keep up with decoding (even VideoToolbox 4K) and write the same
        // bytes as ncpu, while each extra frame thread holds ~100 MB at 4K (2.0 → 0.95 GB peak).
        // An output -threads also caps the -vf graph's slice threads unless -filter_threads is
        // given; 0 keeps the graph at ncpu.
        argv += ["-i", "{in}", "-an", "-vf", filters.joined(separator: ","), "-filter_threads", "0",
                 "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1", "-map_chapters", "-1",
                 "-colorspace", tags.space, "-color_range", "tv",
                 "-c:v", "ffvhuff", "-threads:v", "2", "-y", "{out}"]
        var steps = [PluginStep(name: "prepare", argv: argv)]
        if let audio, !still {
            steps.append(PluginStep(name: "audio", argv: audioArgv(settings: settings, duration: duration, audio: audio)))
        }
        return PluginManifest(id: "source", name: "Source", summary: "Trim, scale, and normalize the source",
                              requires: ["ffmpeg"], params: params, steps: steps)
    }

    /// Extracts the first audio track, trimmed exactly like the video, next to `out.mkv`.
    /// Sources stored deeper than 16 bits keep 24.
    private static func audioArgv(settings: RenderSettings, duration: Double, audio: MediaProbe.Audio) -> [String] {
        var argv = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error"]
        if settings.start > 0 { argv += ["-ss", "{p.start}"] }
        if duration >= 0 { argv += ["-t", "{p.duration}"] }
        argv += ["-i", "{in}", "-map", "0:a:0", "-vn",
                 "-c:a", audio.isDeeperThan16Bit ? "pcm_s24le" : "pcm_s16le",
                 "-fflags", "+bitexact", "-flags:a", "+bitexact", "-map_metadata", "-1",
                 "-y", "{layer}/\(audioFileName)"]
        return argv
    }

    private static func evenFloor(_ n: Int) -> Int { max(2, n - n % 2) }
    private static func roundEven(_ x: Double) -> Int { max(2, Int((x / 2).rounded()) * 2) }
}
