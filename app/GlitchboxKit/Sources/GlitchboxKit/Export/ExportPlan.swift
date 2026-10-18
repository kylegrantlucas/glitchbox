import Foundation

/// Builds the ffmpeg command line for an export. Pure: everything it needs is passed in.
///
/// Layer outputs vary (yuv420p ffvhuff, yuv444p from ntsc-rs, bgr0 from reactive-vcr), so
/// every export sets `-pix_fmt` and bt709/tv tags explicitly. ffmpeg converts the matrix and
/// range to match `-colorspace`/`-color_range` when the input is tagged, but takes primaries
/// and transfer only from `setparams`.
public enum ExportPlan {
    public enum AudioInput: Hashable, Sendable {
        /// The source layer's `audio.wav`, already trimmed like the video.
        case source(URL)
        /// A user file, used from its start.
        case file(URL)

        var url: URL {
            switch self {
            case .source(let url), .file(let url): url
            }
        }
    }

    /// The output size and the filters that scale, crop, or pad to it.
    public struct Geometry: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// Runs after square-pixel correction, before `setsar=1`.
        public var filters: [String]
    }

    public static let sequenceFramePattern = "frame_%06d.png"
    public static let sequenceAudioName = "audio.wav"

    // MARK: Geometry

    public static func pixelFormat(_ settings: ExportSettings, video: MediaProbe.Video) -> String? {
        switch settings.format {
        case .h264, .hevc: return "yuv420p"
        case .prores: return settings.proresProfile.pixelFormat
        case .ffv1:
            if video.isRGB { return "gbrp" }
            if video.pixelFormat.contains("444") { return "yuv444p" }
            if video.pixelFormat.contains("422") { return "yuv422p" }
            return "yuv420p"
        case .gif: return nil
        case .pngSequence: return "rgb24"
        }
    }

    /// Chroma-subsampled outputs and the hardware encoders need even sizes.
    public static func needsEvenDimensions(_ settings: ExportSettings, video: MediaProbe.Video) -> Bool {
        switch settings.format {
        case .h264, .hevc, .prores: true
        case .ffv1: pixelFormat(settings, video: video).map { $0 == "yuv420p" || $0 == "yuv422p" } ?? false
        case .gif, .pngSequence: false
        }
    }

    /// Output size for a frame of `video` (after autorotation and square-pixel correction).
    /// Without `allowUpscale`, nothing is scaled up: a box larger than the picture shrinks,
    /// keeping its aspect ratio, until the picture fits at its own size.
    public static func geometry(video: MediaProbe.Video, settings: ExportSettings) -> Geometry {
        let (w, h) = video.squareSize
        let even = needsEvenDimensions(settings, video: video)
        let fw = Double(w), fh = Double(h)
        /// Rounds down to the size grid; the epsilon absorbs ratios like 1920 / (1920 / 1080).
        func floorGrid(_ x: Double) -> Int {
            let n = Int(x + 1e-6)
            return even ? max(2, n - n % 2) : max(1, n)
        }
        /// Rounds to the nearest size on the grid.
        func nearGrid(_ x: Double) -> Int { even ? max(2, Int((x / 2).rounded()) * 2) : max(1, Int(x.rounded())) }
        func scale(_ sw: Int, _ sh: Int) -> [String] { (sw, sh) == (w, h) ? [] : ["scale=\(sw):\(sh):flags=lanczos"] }
        let asRendered: Geometry = {
            let (ew, eh) = (floorGrid(fw), floorGrid(fh))
            return Geometry(width: ew, height: eh, filters: (ew, eh) == (w, h) ? [] : ["crop=\(ew):\(eh):0:0"])
        }()

        if settings.format == .gif {
            guard let target = settings.gif.width, settings.allowUpscale || target < w else { return asRendered }
            let gh = nearGrid(fh * Double(target) / fw)
            return Geometry(width: target, height: gh, filters: scale(target, gh))
        }

        switch settings.size {
        case .asRendered:
            return asRendered
        case .shortSide(let side):
            let short = min(w, h)
            guard settings.allowUpscale || side < short else { return asRendered }
            let s = floorGrid(Double(side))
            let (sw, sh) = h > w ? (s, nearGrid(fh * Double(s) / fw)) : (nearGrid(fw * Double(s) / fh), s)
            return Geometry(width: sw, height: sh, filters: scale(sw, sh))
        case .box(let bw, let bh, let fit):
            var boxW = Double(floorGrid(Double(bw))), boxH = Double(floorGrid(Double(bh)))
            switch fit {
            case .fit, .fill:
                var k = fit == .fit ? min(boxW / fw, boxH / fh) : max(boxW / fw, boxH / fh)
                if !settings.allowUpscale, k > 1 {
                    boxW /= k; boxH /= k; k = 1
                }
                let W = floorGrid(boxW), H = floorGrid(boxH)
                if fit == .fit {
                    let cw = min(W, nearGrid(fw * k)), ch = min(H, nearGrid(fh * k))
                    let pad = (cw, ch) == (W, H) ? [] : ["pad=\(W):\(H):\((W - cw) / 2):\((H - ch) / 2):color=black"]
                    return Geometry(width: W, height: H, filters: scale(cw, ch) + pad)
                }
                let cw = max(W, nearGrid(fw * k)), ch = max(H, nearGrid(fh * k))
                let crop = (cw, ch) == (W, H) ? [] : ["crop=\(W):\(H):\((cw - W) / 2):\((ch - H) / 2)"]
                return Geometry(width: W, height: H, filters: scale(cw, ch) + crop)
            case .stretch:
                let m = max(boxW / fw, boxH / fh)
                if !settings.allowUpscale, m > 1 { boxW /= m; boxH /= m }
                let W = floorGrid(boxW), H = floorGrid(boxH)
                return Geometry(width: W, height: H, filters: scale(W, H))
            }
        }
    }

    // MARK: Filters

    /// `setparams` filling the tags an untagged layer output is missing, from the source's.
    static func untaggedFix(_ video: MediaProbe.Video, sourceTags: ColorTags) -> String? {
        var parts: [String] = []
        if !video.isRGB, video.colorSpace == nil { parts.append("colorspace=\(sourceTags.space)") }
        if video.colorPrimaries == nil { parts.append("color_primaries=\(sourceTags.primaries)") }
        if video.colorTransfer == nil { parts.append("color_trc=\(sourceTags.transfer)") }
        if !video.isRGB, video.colorRange == nil { parts.append("range=tv") }
        return parts.isEmpty ? nil : "setparams=" + parts.joined(separator: ":")
    }

    /// Tag fix, then square pixels.
    private static func inputFilters(_ video: MediaProbe.Video, sourceTags: ColorTags) -> [String] {
        var filters: [String] = []
        if let fix = untaggedFix(video, sourceTags: sourceTags) { filters.append(fix) }
        if !video.hasSquarePixels { filters.append("scale=trunc(iw*sar/2)*2:ih:flags=lanczos") }
        return filters
    }

    // MARK: Arguments

    static func common(progress: URL) -> [String] {
        ["-hide_banner", "-nostdin", "-loglevel", "error", "-nostats", "-stats_period", "0.5",
         "-progress", progress.path, "-y"]
    }

    /// `output` is the file to write, or for a PNG sequence the directory to fill.
    /// `duration` is the input video's length; MPEG-2 mosh can change frame counts, so audio is
    /// fitted to it rather than to the requested range.
    public static func arguments(input: URL, video: MediaProbe.Video, duration: Double?, sourceTags: ColorTags,
                                 audio: AudioInput?, settings: ExportSettings, output: URL, progress: URL) -> [String] {
        let geometry = geometry(video: video, settings: settings)
        let pre = inputFilters(video, sourceTags: sourceTags)
        var args = common(progress: progress) + ["-i", input.path]
        let audio = settings.format.hasAudio ? audio : nil
        if let audio { args += ["-i", audio.url.path] }

        switch settings.format {
        case .gif:
            let gif = settings.gif
            let stats = gif.palette == .perFrame ? "single" : "diff"
            var use = "paletteuse=dither=\(gif.dither.rawValue)"
            if gif.dither == .bayer { use += ":bayer_scale=\(min(5, max(0, gif.bayerScale)))" }
            use += ":diff_mode=rectangle"
            if gif.palette == .perFrame { use += ":new=1" }
            let chain = (pre + ["fps=\(gif.fps)"] + geometry.filters + ["setsar=1", "split[a][b]"]).joined(separator: ",")
            let graph = "[0:v]\(chain);[a]palettegen=max_colors=256:reserve_transparent=0:stats_mode=\(stats)[p];[b][p]\(use)[out]"
            args += ["-filter_complex", graph, "-map", "[out]", "-loop", String(gif.muxerLoop),
                     "-f", "gif", output.path]

        case .pngSequence:
            let vf = (pre + geometry.filters + ["setsar=1"]).joined(separator: ",")
            args += ["-map", "0:v:0", "-vf", vf, "-c:v", "png", "-pix_fmt", "rgb24", "-compression_level", "3",
                     "-start_number", "0", "-f", "image2", output.appending(path: sequenceFramePattern).path]
            if audio != nil {
                args += ["-map", "1:a:0"] + audioLength(duration) + ["-c:a", "pcm_s24le", "-f", "wav",
                                                                    output.appending(path: sequenceAudioName).path]
            }

        case .h264, .hevc, .prores, .ffv1:
            let container = settings.container
            let pixelFormat = pixelFormat(settings, video: video)!
            let rgb = pixelFormat == "gbrp"
            let vf = (pre + geometry.filters + ["setsar=1", "setparams=color_primaries=bt709:color_trc=bt709"])
                .joined(separator: ",")
            args += ["-map", "0:v:0"]
            if audio != nil, let codec = settings.effectiveAudioCodec {
                args += ["-map", "1:a:0"] + audioLength(duration) + ["-c:a", codec.encoder]
                if codec.hasBitrate { args += ["-b:a", "\(settings.audioBitrate)k"] }
            } else {
                args += ["-an"]
            }
            args += ["-vf", vf] + videoCodec(settings) + ["-pix_fmt", pixelFormat]
            args += ["-color_primaries", "bt709", "-color_trc", "bt709"]
            args += rgb ? [] : ["-colorspace", "bt709", "-color_range", "tv"]
            if container.supportsFaststart { args += ["-movflags", "+faststart"] }
            args += ["-f", container.muxer, output.path]
        }
        return args
    }

    /// Ends the audio exactly where the video ends: `apad` fills short audio with silence and
    /// `-t` cuts long audio at the sample. `-shortest` alone cuts at an audio packet boundary,
    /// up to ~85 ms early for ALAC and PCM, so it is only the fallback for an unknown length.
    static func audioLength(_ duration: Double?) -> [String] {
        guard let duration, duration > 0 else { return ["-shortest"] }
        return ["-af", "apad", "-t", seconds(duration)]
    }

    static func videoCodec(_ settings: ExportSettings) -> [String] {
        switch settings.format {
        case .h264:
            switch settings.h264Encoder {
            case .videoToolbox:
                return ["-c:v", "h264_videotoolbox", "-q:v", String(settings.effectiveVideoToolboxQuality), "-profile:v", "high"]
            case .x264:
                return ["-c:v", "libx264", "-preset", settings.x264Preset, "-crf", String(settings.effectiveX264CRF),
                        "-profile:v", "high"]
            }
        case .hevc:
            return ["-c:v", "hevc_videotoolbox", "-q:v", String(settings.effectiveVideoToolboxQuality),
                    "-profile:v", "main", "-tag:v", "hvc1"]
        case .prores:
            return ["-c:v", "prores_videotoolbox", "-allow_sw", "1", "-profile:v", settings.proresProfile.ffmpegProfile]
        case .ffv1:
            return ["-c:v", "ffv1", "-level", "3", "-g", "1", "-slices", "16", "-slicecrc", "1"]
        case .gif, .pngSequence:
            return []
        }
    }

    /// One PNG of the frame shown at `time` seconds: the last frame starting at or before it.
    public static func frameArguments(input: URL, video: MediaProbe.Video, sourceTags: ColorTags, time: Double,
                                      output: URL) -> [String] {
        let fps = video.frameRate ?? 30
        let index = max(0, (time * fps + 1e-6).rounded(.down))
        // Accurate seeking drops frames starting before the seek point; aim half a frame
        // early so timestamp rounding can't skip the frame we want.
        let seek = max(0, (index - 0.5) / fps)
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        if seek > 0 { args += ["-ss", seconds(seek)] }
        let vf = (inputFilters(video, sourceTags: sourceTags) + ["setsar=1"]).joined(separator: ",")
        args += ["-i", input.path, "-map", "0:v:0", "-frames:v", "1", "-vf", vf,
                 "-c:v", "png", "-pix_fmt", "rgb24", "-update", "1", "-f", "image2", output.path]
        return args
    }

    // MARK: Estimates

    /// Rough GIF size: about 0.6 bytes per pixel per frame, measured on noisy glitch footage
    /// (the worst case; smooth content compresses better).
    public static func estimatedGIFBytes(width: Int, height: Int, duration: Double, options: GIFOptions) -> Int {
        Int(Double(width * height) * duration * Double(options.fps) * 0.6)
    }

    /// GIFs above this size get a warning.
    public static let largeGIFBytes = 20_000_000

    static func seconds(_ d: Double) -> String {
        d.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
