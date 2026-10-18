import Testing
@testable import GlitchboxKit

struct SourcePrepTests {
    /// The `-vf` value and full argv of the prepare step.
    func prepare(_ settings: RenderSettings, _ video: MediaProbe.Video, audio: MediaProbe.Audio? = nil,
                 still: Bool = false) -> (vf: String, argv: [String], manifest: PluginManifest) {
        let m = SourcePrep.manifest(settings: settings, video: video, audio: audio, still: still)
        let argv = m.steps[0].argv!
        return (argv[argv.firstIndex(of: "-vf")! + 1], argv, m)
    }

    func value(after flag: String, in argv: [String]) -> String? {
        argv.firstIndex(of: flag).map { argv[$0 + 1] }
    }

    @Test func rationalRateGoesToFfmpegVerbatim() {
        let m = prepare(RenderSettings(fps: .fps29_97), MediaProbe.Video(width: 1920, height: 1080, frameRate: 25)).manifest
        #expect(m.defaults()["fps"] == .string("30000/1001"))
        #expect(prepare(RenderSettings(fps: .fps29_97), MediaProbe.Video(width: 1920, height: 1080)).vf.hasPrefix("fps={p.fps},"))
    }

    @Test(arguments: [(23.0, FrameRate.fps23_976), (29.97002997, .fps29_97), (17.0, .fps23_976), (120.0, .fps60),
                      (24.0, .fps24), (59.94, .fps59_94), (48.0, .fps50), (30.0, .fps30), (25.0, .fps25),
                      // Low rates go to a whole multiple, so every frame repeats the same number of times.
                      (15.0, .fps30), (12.0, .fps24), (10.0, .fps30), (20.0, .fps60), (14.985014985, .fps29_97)])
    func matchSourceSnapsToStandardRates(source: Double, expected: FrameRate) {
        let snapped = SourcePrep.frameRate(settings: RenderSettings(fps: nil),
                                           video: MediaProbe.Video(width: 640, height: 480, frameRate: source), still: false)
        #expect(snapped == expected)
    }
    @Test func stillsWithoutAnExplicitRateUse30() {
        let rate = SourcePrep.frameRate(settings: RenderSettings(), video: MediaProbe.Video(width: 800, height: 600, frameRate: 25),
                                        still: true)
        #expect(rate == .fps30)
    }

    @Test func heightIsTheShortSideForPortrait() {
        let portrait = prepare(RenderSettings(height: 480), MediaProbe.Video(width: 1080, height: 1920)).vf
        #expect(portrait.contains("scale=480:-2:flags=lanczos"))
        let landscape = prepare(RenderSettings(height: 480), MediaProbe.Video(width: 1920, height: 1080)).vf
        #expect(landscape.contains("scale=-2:480:flags=lanczos"))
        #expect(SourcePrep.outputSize(settings: RenderSettings(height: 480), video: MediaProbe.Video(width: 1080, height: 1920)) == (480, 854))
    }

    @Test func rotatedPhoneVideoCountsAsPortrait() {
        let video = MediaProbe.Video(width: 1920, height: 1080, rotation: -90)
        #expect(prepare(RenderSettings(height: 720), video).vf.contains("scale=720:-2"))
    }

    @Test func oddNativeSizeIsCroppedNotResampled() {
        let (vf, _, _) = prepare(RenderSettings(), MediaProbe.Video(width: 1281, height: 721))
        #expect(vf.contains("crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0"))
        #expect(!vf.contains("scale="))
        #expect(SourcePrep.outputSize(settings: RenderSettings(), video: MediaProbe.Video(width: 1281, height: 721)) == (1280, 720))
        #expect(!prepare(RenderSettings(), MediaProbe.Video(width: 1280, height: 720)).vf.contains("crop"))
    }

    @Test func anamorphicPixelsBecomeSquare() {
        let dv = MediaProbe.Video(width: 720, height: 480, sarNumerator: 8, sarDenominator: 9)
        #expect(prepare(RenderSettings(), dv).vf.contains("scale=trunc(iw*sar/2)*2:ih:flags=lanczos,setsar=1"))
        #expect(SourcePrep.outputSize(settings: RenderSettings(), video: dv) == (640, 480))
        #expect(!prepare(RenderSettings(), MediaProbe.Video(width: 720, height: 480)).vf.contains("sar"))
    }

    @Test func rotatedAnamorphicSourceInvertsItsAspect() {
        // 1440×1080 HDV (SAR 4:3) shot rotated: ffmpeg's transpose turns it 1080×1440 at SAR 3:4.
        let hdv = MediaProbe.Video(width: 1440, height: 1080, sarNumerator: 4, sarDenominator: 3, rotation: 90)
        #expect(hdv.squareSize == (810, 1440))
        #expect(SourcePrep.outputSize(settings: RenderSettings(height: 480), video: hdv) == (480, 854))
    }

    @Test func tagsComeFromTheProbeWithSizeFallback() {
        let tagged = MediaProbe.Video(width: 720, height: 576, colorPrimaries: "bt470bg", colorTransfer: "bt709", colorSpace: "bt470bg")
        let a = prepare(RenderSettings(), tagged)
        #expect(a.vf.hasSuffix("format=yuv420p,setparams=color_primaries=bt470bg:color_trc=bt709"))
        #expect(value(after: "-colorspace", in: a.argv) == "bt470bg")
        #expect(value(after: "-color_range", in: a.argv) == "tv")

        let hd = prepare(RenderSettings(), MediaProbe.Video(width: 1280, height: 720))
        #expect(hd.vf.hasSuffix("setparams=color_primaries=bt709:color_trc=bt709"))
        #expect(value(after: "-colorspace", in: hd.argv) == "bt709")

        let sd = prepare(RenderSettings(), MediaProbe.Video(width: 640, height: 480))
        #expect(sd.vf.hasSuffix("setparams=color_primaries=smpte170m:color_trc=smpte170m"))
        #expect(value(after: "-colorspace", in: sd.argv) == "smpte170m")

        // An RGB still's "gbr" is not a Y'CbCr matrix.
        let png = prepare(RenderSettings(), MediaProbe.Video(width: 1920, height: 1080, pixelFormat: "rgb24", colorSpace: "gbr"), still: true)
        #expect(value(after: "-colorspace", in: png.argv) == "bt709")
    }

    @Test func hdrIsTaggedAsSDR() {
        let hlg = MediaProbe.Video(width: 3840, height: 2160, pixelFormat: "yuv420p10le", colorPrimaries: "bt2020",
                                   colorTransfer: "arib-std-b67", colorSpace: "bt2020nc")
        #expect(ColorTags.isHDR(hlg))
        let p = prepare(RenderSettings(), hlg)
        #expect(p.vf.hasSuffix("setparams=color_primaries=bt709:color_trc=bt709"))
        #expect(value(after: "-colorspace", in: p.argv) == "bt709")
    }

    @Test func writesFfvhuff() {
        #expect(value(after: "-c:v", in: prepare(RenderSettings(), MediaProbe.Video(width: 640, height: 480)).argv) == "ffvhuff")
    }

    @Test func audioKeeps24BitOnlyForDeepSources() {
        let video = MediaProbe.Video(width: 640, height: 480)
        let deep = SourcePrep.manifest(settings: RenderSettings(), video: video,
                                       audio: MediaProbe.Audio(codec: "pcm_s24le", sampleFormat: "s32", bitDepth: 24), still: false)
        #expect(deep.steps[1].script!.contains("-c:a pcm_s24le"))
        let aac = SourcePrep.manifest(settings: RenderSettings(), video: video,
                                      audio: MediaProbe.Audio(codec: "aac", sampleFormat: "fltp"), still: false)
        #expect(aac.steps[1].script!.contains("-c:a pcm_s16le"))
        #expect(SourcePrep.manifest(settings: RenderSettings(), video: video, audio: nil, still: false).steps.count == 1)
    }

    @Test func trimAppliesToVideoAndAudio() {
        let video = MediaProbe.Video(width: 640, height: 480)
        let m = SourcePrep.manifest(settings: RenderSettings(start: 1.5, duration: 2), video: video,
                                    audio: MediaProbe.Audio(codec: "aac", sampleFormat: "fltp"), still: false)
        let argv = m.steps[0].argv!
        #expect(argv.firstIndex(of: "-ss")! < argv.firstIndex(of: "-i")!)
        #expect(m.defaults()["start"] == .float(1.5))
        #expect(m.steps[1].script!.contains("-ss 1.5 -t 2.0 -i"))
    }
}
