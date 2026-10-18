import Foundation
import Testing
@testable import GlitchboxKit

struct ExportPlanTests {
    let input = URL(filePath: "/cache/final/out.mkv")
    let wav = URL(filePath: "/cache/source/audio.wav")
    let progress = URL(filePath: "/cache/exports/job/progress.txt")
    let hd = MediaProbe.Video(width: 1920, height: 1080, frameRate: 30, colorPrimaries: "bt709",
                              colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")

    func args(_ s: ExportSettings, video: MediaProbe.Video? = nil, audio: ExportPlan.AudioInput?? = .none,
              duration: Double? = 4, output: String = "/out/x") -> [String] {
        let audio: ExportPlan.AudioInput? = switch audio { case .none: .source(wav); case .some(let a): a }
        return ExportPlan.arguments(input: input, video: video ?? hd, duration: duration, sourceTags: .bt709, audio: audio,
                                    settings: s, output: URL(filePath: output), progress: progress)
    }

    func value(_ flag: String, _ argv: [String]) -> String? {
        argv.firstIndex(of: flag).map { argv[$0 + 1] }
    }

    func values(_ flag: String, _ argv: [String]) -> [String] {
        argv.indices.filter { argv[$0] == flag }.map { argv[$0 + 1] }
    }

    func geometry(_ w: Int, _ h: Int, _ size: OutputSize, format: ExportFormat = .h264, upscale: Bool = false) -> ExportPlan.Geometry {
        ExportPlan.geometry(video: MediaProbe.Video(width: w, height: h),
                            settings: ExportSettings(format: format, size: size, allowUpscale: upscale))
    }

    // MARK: Formats

    @Test func h264VideoToolboxMP4() {
        let a = args(ExportSettings(format: .h264))
        #expect(values("-i", a) == [input.path, wav.path])
        #expect(values("-map", a) == ["0:v:0", "1:a:0"])
        #expect(value("-c:v", a) == "h264_videotoolbox")
        #expect(value("-q:v", a) == "75")
        #expect(value("-profile:v", a) == "high")
        #expect(value("-pix_fmt", a) == "yuv420p")
        #expect(value("-c:a", a) == "aac_at")
        #expect(value("-b:a", a) == "192k")
        #expect(value("-colorspace", a) == "bt709")
        #expect(value("-color_range", a) == "tv")
        #expect(value("-vf", a)!.hasSuffix("setsar=1,setparams=color_primaries=bt709:color_trc=bt709"))
        #expect(value("-movflags", a) == "+faststart")
        #expect(value("-af", a) == "apad")
        #expect(value("-t", a) == "4")
        #expect(value("-f", a) == "mp4")
        #expect(a.last == "/out/x")
        #expect(value("-progress", a) == progress.path)
    }

    @Test func h264X264UsesCRFAndPreset() {
        let a = args(ExportSettings(format: .h264, quality: .max, h264Encoder: .x264, x264Preset: "slow"))
        #expect(value("-c:v", a) == "libx264")
        #expect(value("-crf", a) == "14")
        #expect(value("-preset", a) == "slow")
        let advanced = args(ExportSettings(format: .h264, h264Encoder: .x264, x264CRF: 20))
        #expect(value("-crf", advanced) == "20")
    }

    @Test func hevcTagsHvc1AndHonoursContainer() {
        let mp4 = args(ExportSettings(format: .hevc, quality: .good))
        #expect(value("-c:v", mp4) == "hevc_videotoolbox")
        #expect(value("-q:v", mp4) == "65")
        #expect(value("-tag:v", mp4) == "hvc1")
        #expect(value("-f", mp4) == "mp4")
        let mov = args(ExportSettings(format: .hevc, preferredContainer: .mov))
        #expect(value("-f", mov) == "mov")
        #expect(value("-movflags", mov) == "+faststart")
    }

    @Test func proresProfilesAndPixelFormats() {
        let hq = args(ExportSettings(format: .prores))
        #expect(value("-c:v", hq) == "prores_videotoolbox")
        #expect(value("-allow_sw", hq) == "1")
        #expect(value("-profile:v", hq) == "hq")
        #expect(value("-pix_fmt", hq) == "p210le")
        #expect(value("-c:a", hq) == "pcm_s24le")
        #expect(value("-f", hq) == "mov")
        let p4444 = args(ExportSettings(format: .prores, proresProfile: .p4444))
        #expect(value("-profile:v", p4444) == "4444")
        #expect(value("-pix_fmt", p4444) == "p410le")
    }

    @Test func ffv1ReencodesAndKeepsChroma() {
        let a = args(ExportSettings(format: .ffv1))
        #expect(value("-c:v", a) == "ffv1")
        #expect(!a.contains("copy"))
        #expect(value("-c:a", a) == "flac")
        #expect(value("-f", a) == "matroska")
        #expect(value("-movflags", a) == nil)
        let yuv444 = args(ExportSettings(format: .ffv1), video: MediaProbe.Video(width: 720, height: 480, pixelFormat: "yuv444p"))
        #expect(value("-pix_fmt", yuv444) == "yuv444p")
        let rgb = args(ExportSettings(format: .ffv1), video: MediaProbe.Video(width: 721, height: 480, pixelFormat: "bgr0"))
        #expect(value("-pix_fmt", rgb) == "gbrp")
        #expect(value("-colorspace", rgb) == nil)
        // 4:4:4 and RGB keep odd sizes.
        #expect(!value("-vf", rgb)!.contains("crop"))
    }

    // MARK: Audio

    @Test func audioCodecFollowsContainer() {
        #expect(value("-c:a", args(ExportSettings(format: .h264, audioCodec: .alac))) == "alac")
        // PCM in MP4 is not offered; it falls back to the container default.
        #expect(value("-c:a", args(ExportSettings(format: .h264, audioCodec: .pcmS24))) == "aac_at")
        #expect(value("-c:a", args(ExportSettings(format: .hevc, preferredContainer: .mov, audioCodec: .pcmS16))) == "pcm_s16le")
        #expect(value("-c:a", args(ExportSettings(format: .hevc, preferredContainer: .mov))) == "aac_at")
        #expect(value("-c:a", args(ExportSettings(format: .ffv1, audioCodec: .pcmS24))) == "pcm_s24le")
        #expect(value("-c:a", args(ExportSettings(format: .ffv1, audioCodec: .aac))) == "flac")
        #expect(value("-b:a", args(ExportSettings(format: .h264, audioBitrate: 320))) == "320k")
        #expect(value("-b:a", args(ExportSettings(format: .h264, audioCodec: .alac))) == nil)
    }

    @Test func noAudioDropsTheSecondInput() {
        let a = args(ExportSettings(format: .h264), audio: .some(nil))
        #expect(values("-i", a) == [input.path])
        #expect(values("-map", a) == ["0:v:0"])
        #expect(a.contains("-an"))
        #expect(!a.contains("-t"))
    }

    @Test func audioIsFittedToTheRenderedVideo() {
        // Mosh can change the frame count, so the length comes from the final layer, not the range.
        let song = URL(filePath: "/music/song.m4a")
        let a = args(ExportSettings(format: .h264), audio: .file(song), duration: 4.033333)
        #expect(values("-i", a) == [input.path, song.path])
        #expect(!a.contains("-ss"))
        let t = a.firstIndex(of: "-t")!
        #expect(a[t + 1] == "4.033333")
        #expect(t > a.lastIndex(of: "-i")!)
        #expect(Array(a[(t - 2)..<t]) == ["-af", "apad"])
        // Unknown length falls back to -shortest.
        let unknown = args(ExportSettings(format: .h264), duration: nil)
        #expect(unknown.contains("-shortest"))
        #expect(!unknown.contains("-t"))
    }

    // MARK: Colour

    @Test func untaggedLayerGetsSourceTagsFirst() {
        let untagged = MediaProbe.Video(width: 640, height: 480)
        let a = ExportPlan.arguments(input: input, video: untagged, duration: 4, sourceTags: .smpte170m, audio: nil,
                                     settings: ExportSettings(format: .h264), output: URL(filePath: "/o.mp4"), progress: progress)
        #expect(value("-vf", a)!.hasPrefix("setparams=colorspace=smpte170m:color_primaries=smpte170m:color_trc=smpte170m:range=tv,"))
        #expect(!value("-vf", args(ExportSettings(format: .h264)))!.hasPrefix("setparams"))
        // RGB has no matrix or range to fill.
        let rgb = MediaProbe.Video(width: 640, height: 480, pixelFormat: "bgr0")
        let b = ExportPlan.arguments(input: input, video: rgb, duration: 4, sourceTags: .smpte170m, audio: nil,
                                     settings: ExportSettings(format: .h264), output: URL(filePath: "/o.mp4"), progress: progress)
        #expect(value("-vf", b)!.hasPrefix("setparams=color_primaries=smpte170m:color_trc=smpte170m,"))
    }

    // MARK: Size

    @Test func shortSideScalesByOrientation() {
        #expect(geometry(1920, 1080, .shortSide(720)) == .init(width: 1280, height: 720, filters: ["scale=1280:720:flags=lanczos"]))
        #expect(geometry(1080, 1920, .shortSide(720)) == .init(width: 720, height: 1280, filters: ["scale=720:1280:flags=lanczos"]))
        #expect(geometry(1080, 1920, .shortSide(480)).height == 854)
    }

    @Test func noUpscaleKeepsTheRenderedSize() {
        #expect(geometry(1280, 720, .shortSide(1080)) == .init(width: 1280, height: 720, filters: []))
        #expect(geometry(1280, 720, .shortSide(1080), upscale: true).width == 1920)
    }

    @Test func fitPadsToTheBox() {
        #expect(geometry(1920, 1080, .box(width: 1080, height: 1920, fit: .fit))
                == .init(width: 1080, height: 1920,
                         filters: ["scale=1080:608:flags=lanczos", "pad=1080:1920:0:656:color=black"]))
        // Without upscaling, a larger box shrinks to the picture's own scale.
        #expect(geometry(1280, 720, .box(width: 3840, height: 2160, fit: .fit)) == .init(width: 1280, height: 720, filters: []))
    }

    @Test func fillCropsTheOverflow() {
        #expect(geometry(1920, 1080, .box(width: 1080, height: 1920, fit: .fill), upscale: true)
                == .init(width: 1080, height: 1920, filters: ["scale=3414:1920:flags=lanczos", "crop=1080:1920:1167:0"]))
        // No upscale: a native-resolution 9:16 crop.
        #expect(geometry(1920, 1080, .box(width: 1080, height: 1920, fit: .fill))
                == .init(width: 606, height: 1080, filters: ["crop=606:1080:657:0"]))
        #expect(geometry(3840, 2160, .box(width: 1080, height: 1080, fit: .fill))
                == .init(width: 1080, height: 1080, filters: ["scale=1920:1080:flags=lanczos", "crop=1080:1080:420:0"]))
    }

    @Test func stretchScalesEachAxis() {
        #expect(geometry(1920, 1080, .box(width: 1000, height: 1000, fit: .stretch))
                == .init(width: 1000, height: 1000, filters: ["scale=1000:1000:flags=lanczos"]))
        #expect(geometry(1280, 720, .box(width: 1000, height: 1000, fit: .stretch))
                == .init(width: 720, height: 720, filters: ["scale=720:720:flags=lanczos"]))
    }

    @Test func evenRoundingOnlyWhereTheCodecNeedsIt() {
        #expect(geometry(1920, 1080, .box(width: 1081, height: 1001, fit: .stretch))
                == .init(width: 1080, height: 1000, filters: ["scale=1080:1000:flags=lanczos"]))
        #expect(geometry(1920, 1080, .box(width: 1081, height: 1001, fit: .stretch), format: .pngSequence)
                == .init(width: 1081, height: 1001, filters: ["scale=1081:1001:flags=lanczos"]))
        #expect(geometry(1281, 721, .asRendered) == .init(width: 1280, height: 720, filters: ["crop=1280:720:0:0"]))
        #expect(geometry(1281, 721, .asRendered, format: .pngSequence) == .init(width: 1281, height: 721, filters: []))
    }

    @Test func anamorphicLayersBecomeSquare() {
        let dv = MediaProbe.Video(width: 720, height: 480, sarNumerator: 8, sarDenominator: 9)
        let a = args(ExportSettings(format: .h264), video: dv)
        #expect(value("-vf", a)!.contains("scale=trunc(iw*sar/2)*2:ih:flags=lanczos,setsar=1"))
        #expect(ExportPlan.geometry(video: dv, settings: ExportSettings()).width == 640)
    }

    // MARK: GIF and PNG

    @Test func gifFilterGraph() {
        let a = args(ExportSettings(format: .gif))
        #expect(values("-i", a) == [input.path])
        #expect(value("-filter_complex", a) == "[0:v]fps=15,scale=480:270:flags=lanczos,setsar=1,split[a][b];"
            + "[a]palettegen=max_colors=256:reserve_transparent=0:stats_mode=diff[p];"
            + "[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle[out]")
        #expect(value("-map", a) == "[out]")
        #expect(value("-loop", a) == "0")
        #expect(value("-f", a) == "gif")
        #expect(value("-pix_fmt", a) == nil)

        let custom = args(ExportSettings(format: .gif, gif: GIFOptions(width: 320, fps: 10, dither: .bayer, bayerScale: 2,
                                                                       palette: .perFrame, plays: 1)))
        let graph = value("-filter_complex", custom)!
        #expect(graph.contains("fps=10,scale=320:180"))
        #expect(graph.contains("stats_mode=single"))
        #expect(graph.contains("paletteuse=dither=bayer:bayer_scale=2:diff_mode=rectangle:new=1"))
        #expect(value("-loop", custom) == "-1")
        #expect(value("-loop", args(ExportSettings(format: .gif, gif: GIFOptions(plays: 3)))) == "2")
    }

    @Test func gifWidthNeverUpscalesByDefault() {
        let small = MediaProbe.Video(width: 320, height: 240)
        #expect(ExportPlan.geometry(video: small, settings: ExportSettings(format: .gif)).width == 320)
        #expect(ExportPlan.geometry(video: small, settings: ExportSettings(format: .gif, allowUpscale: true)).width == 480)
    }

    @Test func gifSizeEstimate() {
        // 480×270, 2 s at 15 fps: about 2.3 MB, as measured on noisy footage.
        #expect(ExportPlan.estimatedGIFBytes(width: 480, height: 270, duration: 2, options: GIFOptions()) == 2_332_800)
    }

    @Test func pngSequenceWithSidecarAudio() {
        let a = args(ExportSettings(format: .pngSequence), output: "/out/seq")
        #expect(a.contains("/out/seq/frame_%06d.png"))
        #expect(value("-pix_fmt", a) == "rgb24")
        #expect(value("-start_number", a) == "0")
        #expect(values("-map", a) == ["0:v:0", "1:a:0"])
        #expect(value("-c:a", a) == "pcm_s24le")
        #expect(value("-t", a) == "4")
        #expect(a.last == "/out/seq/audio.wav")
        let silent = args(ExportSettings(format: .pngSequence), audio: .some(nil), output: "/out/seq")
        #expect(silent.last == "/out/seq/frame_%06d.png")
    }

    @Test func currentFrameSeeksHalfAFrameEarly() {
        let a = ExportPlan.frameArguments(input: input, video: hd, sourceTags: .bt709, time: 1.01, output: URL(filePath: "/f.png"))
        // 1.01 s at 30 fps shows frame 30, which starts at 1.0 s.
        #expect(value("-ss", a) == "0.983333")
        #expect(value("-frames:v", a) == "1")
        #expect(value("-pix_fmt", a) == "rgb24")
        #expect(a.firstIndex(of: "-ss")! < a.firstIndex(of: "-i")!)
        #expect(!ExportPlan.frameArguments(input: input, video: hd, sourceTags: .bt709, time: 0, output: URL(filePath: "/f.png"))
            .contains("-ss"))
    }
}
