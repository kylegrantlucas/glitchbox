import Foundation
import GBMedia
import GlitchboxFX
import GlitchboxKit

/// The five frei0r plugins (block-glitch, row-shift, plasma-distort, kaleidoscope, vertigo)
/// in-process through GlitchboxFX's original pixel effects (see glitchbox_fx.h, "pixel
/// effects"): decode to RGBA → effect → yuv420p with the source's matrix and range →
/// ffvhuff with the source's colour tags, one output frame per input frame. The effects are
/// not frei0r's, so these layers look different from the macOS renders.
struct PixelEffectStep: NativeStep {
    let id: String

    func run(_ c: NativeStepContext) async throws -> Int32 {
        guard let params = try? String(contentsOf: c.paramsFile, encoding: .utf8) else {
            ToolCall.append(c.log, "\(id): cannot read \(c.paramsFile.path)\n")
            return 1
        }
        let id = id
        return try await Effect.run(c, name: id) { flag in
            try Self.render(c, id: id, params: params, flag: flag)
        }
    }

    static func render(_ c: NativeStepContext, id: String, params: String, flag: CancelFlag) throws {
        let decoder = try MediaDecoder(url: c.input, pixelFormat: "rgba")
        let handle = try Effect.fx("\(id) rejected the settings", { gbfx_pixel_new(id, params, $0) },
                                   failed: { $0 == nil })
        guard let pixel = handle else { throw EffectError("\(id) rejected the settings") }
        defer { gbfx_pixel_free(pixel) }

        let info = decoder.info, output = decoder.output
        let w = output.width, h = output.height
        let matrix = switch info.color_space {
        case 1: "bt709"
        case 5, 6: "bt601"
        case 9: "bt2020"
        default: "bt709"
        }
        let range = info.color_range == 2 ? "pc" : "tv"
        let converter = try MediaConverter(width: w, height: h, pixelFormat: "rgba",
                                           filters: "scale=out_color_matrix=\(matrix):out_range=\(range),format=yuv420p")
        var config = try Effect.encoderConfig(
            codec: Int32(GBM_CODEC_FFVHUFF.rawValue), width: w, height: h, pixelFormat: "yuv420p",
            rate: Effect.nominalRate(output.frameRate), sar: info.sar, space: info.color_space,
            primaries: info.color_primaries, transfer: info.color_trc, chromaLocation: info.chroma_location)
        config.color_range = Int32(info.color_range)
        let encoder = try MediaEncoder(url: c.output, config: config)

        var dst = [UInt8](repeating: 0, count: w * 4 * h)
        var count = 0
        while let frame = try decoder.next() {
            try Effect.check(flag)
            guard frame.width == w, frame.height == h, let src = frame.data.0 else {
                throw EffectError("\(c.input.lastPathComponent): frame \(frame.index) is not \(w)x\(h) RGBA")
            }
            try dst.withUnsafeMutableBufferPointer { d in
                _ = try Effect.fx("\(id) frame \(frame.index)", {
                    gbfx_pixel_apply(pixel, src, Int(frame.linesize.0), d.baseAddress, w * 4, UInt32(w), UInt32(h),
                                     UInt64(max(frame.index, 0)), frame.time, $0)
                }, failed: { $0 != GBFX_OK })
            }
            let yuv = try dst.withUnsafeBytes { try converter.run(packed: $0.baseAddress!, stride: w * 4) }
            try encoder.write(yuv, index: frame.index)
            count += 1
        }
        guard count > 0 else { throw EffectError("\(c.input.lastPathComponent) has no video frames") }
        try encoder.finish()
    }
}
