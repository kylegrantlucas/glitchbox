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
            let probe = try MediaDecoder(url: c.input, pixelFormat: "rgb24")
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

        let stride16 = w * 4  // uint16 per row
        var previous = [UInt16](repeating: 0, count: stride16 * h)
        var current = previous
        var effected = previous
        var narrow = [UInt8](repeating: 0, count: w * 3 * h)
        var previousNs: Int64 = 0
        var retimer = Retimer(rate: rate)
        var have = false, written: Int64 = 0

        func emit(_ src: [UInt16], index: Int64) throws {
            try Effect.check(flag)
            try src.withUnsafeBufferPointer { s in
                try effected.withUnsafeMutableBufferPointer { d in
                    _ = try Effect.fx("ntsc-rs frame \(index)", {
                        gbfx_ntsc_apply(ntsc, s.baseAddress, stride16 * 2, d.baseAddress, stride16 * 2,
                                        UInt32(w), UInt32(h), UInt64(index), $0)
                    }, failed: { $0 != GBFX_OK })
                }
            }
            // videoconvert narrows 16-bit RGB by truncation.
            effected.withUnsafeBufferPointer { e in
                narrow.withUnsafeMutableBufferPointer { n in
                    for p in 0..<(w * h) {
                        n[p * 3] = UInt8(e[p * 4 + 1] >> 8)
                        n[p * 3 + 1] = UInt8(e[p * 4 + 2] >> 8)
                        n[p * 3 + 2] = UInt8(e[p * 4 + 3] >> 8)
                    }
                }
            }
            let yuv = try narrow.withUnsafeBytes { try converter.run(packed: $0.baseAddress!, stride: w * 3) }
            try encoder.write(yuv, index: written)
            written += 1
        }

        var counter: Int64 = 0
        while let time = try source.next(into: &current) {
            try Effect.check(flag)
            let ns = time ?? retimer.slotNs(counter)
            counter += 1
            if have {
                for k in retimer.advance(previousNs: previousNs, ns: ns) { try emit(previous, index: k) }
            }
            swap(&previous, &current)
            previousNs = ns
            have = true
        }
        guard have else { throw EffectError("\(c.input.lastPathComponent) has no video frames") }
        // At end of stream videorate repeats the last frame to the end of its duration: one
        // more frame (index N) for millisecond-timed FFV1/H.264 layers, none for ffvhuff.
        for k in retimer.finish(lastNs: previousNs) { try emit(previous, index: k) }
        try encoder.finish()
    }
}
