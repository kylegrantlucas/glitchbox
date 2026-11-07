import Foundation
import GBMedia
import GlitchboxFX
import GlitchboxKit

/// plugins/reactive-vcr.json → pipelines/reactive-vcr → `reactive-vcr render --video IN
/// --audio AUDIO --map MAP --audio-mode none`, in-process through GlitchboxFX's reactive core
/// (see glitchbox_fx.h, "reactive-vcr"): mono 48 kHz audio drives a per-frame schedule;
/// video is decoded to RGB24, retimed to the constant rate, effected, and written as
/// limited-range yuv444p FFV1 with the source's SAR.
public struct ReactiveVCRStep: NativeStep {
    public init() {}

    public func run(_ c: NativeStepContext) async throws -> Int32 {
        // audio=${GB_P_AUDIO:-$GB_SOURCE_AUDIO}
        guard let audio = c.fileParam("audio") ?? c.sourceAudio?.path else {
            ToolCall.append(c.log, "reactive-vcr: the source has no audio track; choose an Audio file\n")
            return 1
        }
        let map = c.fileParam("map") ?? c.root.appending(path: "presets/reactive-vcr.toml").path
        return try await Effect.run(c, name: "reactive-vcr") { flag in
            try Self.render(c, audio: audio, map: map, flag: flag)
        }
    }

    static func render(_ c: NativeStepContext, audio: String, map: String, flag: CancelFlag) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: audio) else { throw EffectError("audio not found: \(audio)") }
        guard fm.fileExists(atPath: map) else { throw EffectError("map not found: \(map)") }
        let mapping = try String(contentsOfFile: map, encoding: .utf8)
        let baseDir = URL(filePath: map).deletingLastPathComponent().path

        let samples = try MediaAudio.decodeMono(url: URL(filePath: audio), sampleRate: 48_000)
        try Effect.check(flag)

        let probe = try MediaDecoder(url: c.input, pixelFormat: "rgb24")
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

        let stride = w * 3
        var previous = [UInt8](repeating: 0, count: stride * h)
        var current = previous
        var effected = previous
        var previousNs: Int64 = 0
        var retimer = Retimer(rate: rate)
        var have = false, done = false, written: Int64 = 0

        func emit(_ src: [UInt8], slot: Int64) throws {
            guard !done else { return }
            try Effect.check(flag)
            let t = UInt64(max(retimer.slotNs(slot), 0))
            let index = gbfx_reactive_frame_index(t, rate.num, rate.den)
            let rc = try src.withUnsafeBufferPointer { s in
                try effected.withUnsafeMutableBufferPointer { d in
                    try Effect.fx("reactive-vcr frame \(index)", {
                        gbfx_reactive_apply(reactive, s.baseAddress, stride, d.baseAddress, stride,
                                            UInt32(w), UInt32(h), UInt64(max(index, 0)), $0)
                    }, failed: { $0 == GBFX_ERROR })
                }
            }
            if rc == GBFX_DROPPED { done = true; return }
            let yuv = try effected.withUnsafeBytes { try converter.run(packed: $0.baseAddress!, stride: stride) }
            try encoder.write(yuv, index: written)
            written += 1
        }

        var counter: Int64 = 0
        while !done, let time = try source.next({ pixels, ns in
            current.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: pixels, count: stride * h)) }
            return ns
        }) {
            try Effect.check(flag)
            let ns = time ?? retimer.slotNs(counter)
            counter += 1
            if have {
                for k in retimer.advance(previousNs: previousNs, ns: ns) { try emit(previous, slot: k) }
            }
            swap(&previous, &current)
            previousNs = ns
            have = true
        }
        guard have else { throw EffectError("\(c.input.lastPathComponent) has no video frames") }
        if !done { for k in retimer.finish(lastNs: previousNs) { try emit(previous, slot: k) } }
        guard written > 0 || frameCount == 0 else { throw EffectError("reactive-vcr rendered no frames") }
        try encoder.finish()
    }
}
