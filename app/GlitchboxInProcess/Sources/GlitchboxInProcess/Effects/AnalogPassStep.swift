import Foundation
import GBMedia
import GlitchboxFX
import GlitchboxKit

/// plugins/analog-pass.json → pipelines/analog-pass → `ntsc-rs-cli -c ffv1 --chroma-subsampling
/// -j SETTINGS [--scale N]`, in-process through GlitchboxFX's ntsc-rs core (see glitchbox_fx.h,
/// "ntsc-rs"): decode → 8-bit RGB widened to ARGB64 → videorate → effect → RGB narrowed and
/// converted to limited-range yuv420p → FFV1 in Matroska.
public struct AnalogPassStep: NativeStep {
    public init() {}

    /// The plugin's jq preset (`del(.seed, .scale)`, strings → numbers, `version: 1`) with the
    /// pipeline's `.random_seed = $seed`, compact with sorted keys (`jq -cS`).
    static func settings(_ params: [String: ParamValue]) throws -> String {
        var fields: [(String, String)] = []
        for (key, value) in params where key != "seed" && key != "scale" {
            if case .string(let s) = value {
                let t = s.trimmingCharacters(in: .whitespaces)
                if let i = Int(t) { fields.append((key, String(i))) }
                else if let d = Double(t), d.isFinite { fields.append((key, JQ.value(.float(d)))) }
                else { throw EffectError("\(key): cannot parse \(JQ.string(s)) as a number") }
            } else {
                fields.append((key, JQ.value(value)))
            }
        }
        fields.append(("version", "1"))
        fields.append(("random_seed", JQ.value(params["seed"] ?? .int(0))))
        fields.sort { $0.0 < $1.0 }
        return "{" + fields.map { "\(JQ.string($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    public func run(_ c: NativeStepContext) async throws -> Int32 {
        let settings = try Self.settings(c.params)
        let scale = Int(c.params.rendered("scale", default: "0")) ?? 0
        return try await Effect.run(c, name: "analog-pass") { flag in
            try Self.render(c, settings: settings, scale: scale, flag: flag)
        }
    }

    static func render(_ c: NativeStepContext, settings: String, scale: Int, flag: CancelFlag) throws {
        guard let ntsc = try Effect.fx("ntsc-rs settings", { gbfx_ntsc_new(settings, $0) }, failed: { $0 == nil }) else {
            throw EffectError("ntsc-rs settings rejected")
        }
        defer { gbfx_ntsc_free(ntsc) }

        // Probe the source size first: --scale sizes the decoder's output.
        var width = 0, height = 0
        if scale > 0 {
            let probe = try MediaDecoder(url: c.input, pixelFormat: "rgb24", threads: Effect.decodeThreads)
            var w: UInt32 = 0, h: UInt32 = 0
            guard gbfx_ntsc_scaled_size(UInt32(probe.info.width), UInt32(probe.info.height), UInt32(scale), &w, &h) == GBFX_OK
            else { throw EffectError("cannot scale \(probe.info.width)x\(probe.info.height) to \(scale) lines") }
            width = Int(w); height = Int(h)
        }
        let source = try ARGB64Source(url: c.input, width: width, height: height)
        let rate = source.rate
        let w = source.width, h = source.height
        let colour = Colorimetry.forHeight(h)
        let converter = try MediaConverter(width: w, height: h, pixelFormat: "rgb24", filters: colour.yuv420Filter())
        let encoder = try MediaEncoder(url: c.output, config: Effect.encoderConfig(
            codec: Int32(GBM_CODEC_FFV1.rawValue), width: w, height: h, pixelFormat: "yuv420p", rate: rate,
            sar: gbm_rational(num: 1, den: 1), space: colour.space, chromaLocation: colour.chromaLocation))

        // Decode + ARGB64 conversion and yuv420p conversion + encode run on their own threads;
        // the effect keeps the previous frame for retiming, hence three input buffers. The
        // effect output stays here and only the narrowed RGB travels, to save memory.
        let stride16 = w * 4  // uint16 per row
        var effected = [UInt16](repeating: 0, count: stride16 * h)
        var previous: FrameBuffer?
        var previousNs: Int64 = 0
        var retimer = Retimer(rate: rate)
        var written: Int64 = 0

        func emit(_ src: FrameBuffer, index: Int64, _ out: ((FrameBuffer) throws -> Void) throws -> Void) throws {
            try Effect.check(flag)
            try effected.withUnsafeMutableBufferPointer { d in
                _ = try Effect.fx("ntsc-rs frame \(index)", {
                    gbfx_ntsc_apply(ntsc, src.base.assumingMemoryBound(to: UInt16.self), stride16 * 2, d.baseAddress,
                                    stride16 * 2, UInt32(w), UInt32(h), UInt64(index), $0)
                }, failed: { $0 != GBFX_OK })
            }
            try out { o in
                // videoconvert narrows 16-bit RGB by truncation.
                effected.withUnsafeBufferPointer { e in
                    let n = o.base.assumingMemoryBound(to: UInt8.self)
                    for p in 0..<(w * h) {
                        n[p &* 3] = UInt8(truncatingIfNeeded: e[p &* 4 &+ 1] >> 8)
                        n[p &* 3 &+ 1] = UInt8(truncatingIfNeeded: e[p &* 4 &+ 2] >> 8)
                        n[p &* 3 &+ 2] = UInt8(truncatingIfNeeded: e[p &* 4 &+ 3] >> 8)
                    }
                }
                o.index = written
                written += 1
            }
        }

        var counter: Int64 = 0
        try FramePipeline.run(inBytes: stride16 * 2 * h, outBytes: w * 3 * h, inDepth: 3, name: "analog-pass", produce: { b in
            guard let time = try source.next(into: b.base.assumingMemoryBound(to: UInt16.self)) else { return false }
            b.time = time
            return true
        }, transform: { current, out in
            try Effect.check(flag)
            let ns = current.time ?? retimer.slotNs(counter)
            counter += 1
            let done = previous
            if let previous {
                for k in retimer.advance(previousNs: previousNs, ns: ns) { try emit(previous, index: k, out) }
            }
            previous = current
            previousNs = ns
            return done
        }, finish: { out in
            guard let previous else { throw EffectError("\(c.input.lastPathComponent) has no video frames") }
            // At end of stream videorate repeats the last frame to the end of its duration: one
            // more frame (index N) for millisecond-timed FFV1/H.264 layers, none for ffvhuff.
            for k in retimer.finish(lastNs: previousNs) { try emit(previous, index: k, out) }
        }, consume: { o in
            let yuv = try converter.run(packed: o.base, stride: w * 3)
            try encoder.write(yuv, index: o.index)
        })
        try encoder.finish()
    }
}
