import Foundation
import GBMedia
import GlitchboxFX
import GlitchboxKit

/// plugins/reactive-vcr.json → pipelines/reactive-vcr → `reactive-vcr render --video IN
/// --audio AUDIO --map MAP --audio-mode none`, in-process through GlitchboxFX's reactive core
/// (see glitchbox_fx.h, "reactive-vcr"): mono 48 kHz audio drives a per-frame schedule;
/// video is decoded to RGB24, retimed to the constant rate, effected, and written as
/// limited-range yuv444p FFV1 with the source's SAR. With no Map file the mapping comes from
/// the sliders, as the plugin script's jq builds it.
public struct ReactiveVCRStep: NativeStep {
    public init() {}

    public func run(_ c: NativeStepContext) async throws -> Int32 {
        // audio=${GB_P_AUDIO:-$GB_SOURCE_AUDIO}
        guard let audio = c.fileParam("audio") ?? c.sourceAudio?.path else {
            ToolCall.append(c.log, "reactive-vcr: the source has no audio track; choose an Audio file\n")
            return 1
        }
        let mapping: String, baseDir: String
        if let map = c.fileParam("map") {
            guard FileManager.default.fileExists(atPath: map) else {
                ToolCall.append(c.log, "reactive-vcr: map not found: \(map)\n")
                return 1
            }
            mapping = try String(contentsOfFile: map, encoding: .utf8)
            baseDir = URL(filePath: map).deletingLastPathComponent().path
        } else {
            mapping = Self.mapping(c.params)
            baseDir = c.work.path
        }
        return try await Effect.run(c, name: "reactive-vcr") { flag in
            try Self.render(c, audio: audio, mapping: mapping, baseDir: baseDir, flag: flag)
        }
    }

    /// The mapping for the plugin's sliders: the text the plugin script's jq program writes
    /// (minus jq's trailing newline), number for number. Keep the two in step.
    static func mapping(_ params: [String: ParamValue]) -> String {
        func value(_ key: String, _ fallback: Double) -> Double { params[key]?.doubleValue ?? fallback }
        let bass = value("bass", 0.5), hits = value("hits", 0.5), level = value("level", 0.5), highs = value("highs", 0.5)
        let response = value("response", 0.5), sensitivity = value("sensitivity", 1.5)
        /// Three decimals, from the rounded thousandths like the jq `f3`.
        func f3(_ x: Double) -> String {
            let n = Int((x * 1000).rounded())
            return "\(n / 1000).\(String(format: "%03d", n % 1000))"
        }
        func whole(_ x: Double) -> String { String(Int(x.rounded())) }
        func ms(_ base: Double) -> String { whole(base * max(0.2, 2 * response)) }
        func block(_ target: String, _ source: String, _ lines: [String]) -> String {
            "\n[[modulate]]\ntarget = \"\(target)\"\nsource = \"\(source)\"\n" + lines.map { $0 + "\n" }.joined()
        }
        var text = """
        # Built by Glitchbox from the Reactive VCR sliders.

        [audio]
        bands.bass = [20, 200]
        bands.high = [3000, 12000]
        normalize = "percentile:98"
        onset_sensitivity = \(f3(sensitivity))

        """
        if bass > 0 {
            text += block("tracking_noise", "rms", ["threshold = 0.0"])
            text += block("tracking_noise_wave_intensity", "band:bass",
                          ["range = [\(f3(4 * bass)), \(f3(50 * bass))]", "curve = \"pow:2\"", "attack_ms = 10", "release_ms = \(ms(300))"])
            text += block("tracking_noise_height", "band:bass",
                          ["range = [\(whole(12 * bass)), \(whole(120 * bass))]", "release_ms = \(ms(200))"])
        }
        if hits > 0 {
            text += block("head_switching", "onset", ["threshold = 0.5", "release_ms = \(ms(120))"])
            text += block("head_switching_horizontal_shift", "onset", ["range = [0.000, \(f3(80 * hits))]", "release_ms = \(ms(120))"])
        }
        if level > 0 {
            text += block("snow_intensity", "rms", ["range = [0.000, \(f3(4 * level))]", "curve = \"exp\"", "release_ms = \(ms(400))"])
        }
        if highs > 0 {
            text += block("chroma_noise_intensity", "band:high", ["range = [0.000, \(f3(0.8 * highs))]", "release_ms = \(ms(150))"])
        }
        return text
    }

    static func render(_ c: NativeStepContext, audio: String, mapping: String, baseDir: String, flag: CancelFlag) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: audio) else { throw EffectError("audio not found: \(audio)") }

        let samples = try MediaAudio.decodeMono(url: URL(filePath: audio), sampleRate: 48_000)
        try Effect.check(flag)

        let probe = try MediaDecoder(url: c.input, pixelFormat: "rgb24", threads: Effect.decodeThreads)
        let info = probe.info
        let rate = Effect.nominalRate(info.frame_rate)
        guard info.duration > 0 else { throw EffectError("\(c.input.lastPathComponent) has no duration") }

        let handle = try samples.withUnsafeBufferPointer { s in
            try Effect.fx("reactive-vcr", {
                gbfx_reactive_new(mapping, baseDir, s.baseAddress, s.count, UInt32(info.width), UInt32(info.height),
                                  rate.num, rate.den, info.duration, 0, $0)
            }, failed: { $0 == nil })
        }
        guard let reactive = handle else { throw EffectError("reactive-vcr: invalid mapping") }
        defer { gbfx_reactive_free(reactive) }
        let frameCount = Int64(gbfx_reactive_frame_count(reactive))
        var sw: UInt32 = 0, sh: UInt32 = 0
        guard gbfx_reactive_frame_size(reactive, &sw, &sh) == GBFX_OK else { throw EffectError("reactive-vcr: no frame size") }
        let w = Int(sw), h = Int(sh)

        let source = try RGBSource(url: c.input, width: w, height: h, bytesPerPixel: 3)
        // The CLI's Y444 caps carry explicit colorimetry: all three BT.601 (smpte170m) up to
        // 576 lines, all three BT.709 above; measured chroma siting center / left.
        let colour = Colorimetry.forHeight(h)
        let tag = colour.space
        let converter = try MediaConverter(
            width: w, height: h, pixelFormat: "rgb24",
            filters: "scale=out_range=tv:out_color_matrix=\(colour.matrix):flags=accurate_rnd+full_chroma_int,format=yuv444p")
        let sar = info.sar.num > 0 && info.sar.den > 0 ? info.sar : gbm_rational(num: 1, den: 1)
        let encoder = try MediaEncoder(url: c.output, config: Effect.encoderConfig(
            codec: Int32(GBM_CODEC_FFV1.rawValue), width: w, height: h, pixelFormat: "yuv444p", rate: rate, sar: sar,
            space: tag, primaries: tag, transfer: tag, chromaLocation: colour.chromaLocation))

        // Decode + RGB conversion and yuv444p conversion + encode run on their own threads;
        // the effect keeps the previous frame for retiming, hence three input buffers.
        let stride = w * 3
        var previous: FrameBuffer?
        var previousNs: Int64 = 0
        var retimer = Retimer(rate: rate)
        var written: Int64 = 0

        func emit(_ src: FrameBuffer, slot: Int64, _ out: ((FrameBuffer) throws -> Void) throws -> Void) throws {
            try Effect.check(flag)
            let t = UInt64(max(retimer.slotNs(slot), 0))
            let index = gbfx_reactive_frame_index(t, rate.num, rate.den)
            try out { d in
                let rc = try Effect.fx("reactive-vcr frame \(index)", {
                    gbfx_reactive_apply(reactive, src.base.assumingMemoryBound(to: UInt8.self), stride,
                                        d.base.assumingMemoryBound(to: UInt8.self), stride,
                                        UInt32(w), UInt32(h), UInt64(max(index, 0)), $0)
                }, failed: { $0 == GBFX_ERROR })
                if rc == GBFX_DROPPED { throw FramePipeline.Stop() }
                d.index = written
                written += 1
            }
        }

        var counter: Int64 = 0
        try FramePipeline.run(inBytes: stride * h, outBytes: stride * h, inDepth: 3, name: "reactive-vcr", produce: { b in
            guard let time = try source.next(into: b.base) else { return false }
            b.time = time
            return true
        }, transform: { current, out in
            try Effect.check(flag)
            let ns = current.time ?? retimer.slotNs(counter)
            counter += 1
            let done = previous
            if let previous {
                for k in retimer.advance(previousNs: previousNs, ns: ns) { try emit(previous, slot: k, out) }
            }
            previous = current
            previousNs = ns
            return done
        }, finish: { out in
            guard let previous else { throw EffectError("\(c.input.lastPathComponent) has no video frames") }
            for k in retimer.finish(lastNs: previousNs) { try emit(previous, slot: k, out) }
        }, consume: { d in
            let yuv = try converter.run(packed: d.base, stride: stride)
            try encoder.write(yuv, index: d.index)
        })
        guard written > 0 || frameCount == 0 else { throw EffectError("reactive-vcr rendered no frames") }
        try encoder.finish()
    }
}
