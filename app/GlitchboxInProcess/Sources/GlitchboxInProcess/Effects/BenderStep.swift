import Foundation
import GBMedia
import GlitchboxFX
import GlitchboxKit

/// plugins/bender.json → pipelines/bend → `bender --preset P [--set order=…] --seed N
/// --dump-preset`, then `bender -i IN -o OUT --codec ffv1 --scanlines S --preset DUMP`,
/// in-process through GlitchboxFX's bender core (see glitchbox_fx.h, "bender"): decode to
/// RGBA (bilinear to the scanline size) → effect indexed by each frame's timestamp →
/// limited-range yuv420p → FFV1 in Matroska, one output frame per input frame.
public struct BenderStep: NativeStep {
    public init() {}

    /// The plugin's jq: `reduce` over the `group__field` params with `setpath`, starting from
    /// `{version: 1, seed: $seed}`. Keys are sorted (the parse ignores order).
    static func preset(_ params: [String: ParamValue]) -> String {
        final class Node { var leaf: String?; var children: [String: Node] = [:] }
        let root = Node()
        root.children["version"] = { let n = Node(); n.leaf = "1"; return n }()
        root.children["seed"] = { let n = Node(); n.leaf = JQ.value(params["seed"]); return n }()
        for key in params.keys.sorted() where key.contains("__") {
            var node = root
            let path = key.components(separatedBy: "__")
            for (i, part) in path.enumerated() {
                if i == path.count - 1 {
                    let leaf = Node(); leaf.leaf = JQ.value(params[key]); node.children[part] = leaf
                } else {
                    let next = node.children[part].flatMap { $0.leaf == nil ? $0 : nil } ?? Node()
                    node.children[part] = next
                    node = next
                }
            }
        }
        func render(_ n: Node) -> String {
            if let leaf = n.leaf { return leaf }
            return "{" + n.children.keys.sorted().map { "\(JQ.string($0)):\(render(n.children[$0]!))" }
                .joined(separator: ",") + "}"
        }
        return render(root)
    }

    /// `--set order=…` with every space removed, when the order param is not blank.
    static func sets(_ params: [String: ParamValue]) -> [String] {
        let order = params.rendered("order").replacingOccurrences(of: " ", with: "")
        return order.isEmpty ? [] : ["order=\(order)"]
    }

    public func run(_ c: NativeStepContext) async throws -> Int32 {
        let preset = Self.preset(c.params), sets = Self.sets(c.params)
        let scanlines = Int(c.params.rendered("scanlines", default: "0")) ?? 0
        guard let seed = Int32(c.params.rendered("seed")) else {
            ToolCall.append(c.log, "bender: seed must be an integer\n")
            return 1
        }
        return try await Effect.run(c, name: "bender") { flag in
            try Self.render(c, preset: preset, sets: sets, seed: seed, scanlines: scanlines, flag: flag)
        }
    }

    static func render(_ c: NativeStepContext, preset: String, sets: [String], seed: Int32, scanlines: Int,
                       flag: CancelFlag) throws {
        let cSets = sets.map { UnsafePointer(strdup($0)) }
        defer { cSets.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var seedValue = seed
        let handle = try cSets.withUnsafeBufferPointer { s in
            try Effect.fx("bender rejected the settings", {
                gbfx_bender_new(preset, s.baseAddress, s.count, &seedValue, 0, $0)
            }, failed: { $0 == nil })
        }
        guard let bender = handle else { throw EffectError("bender rejected the settings") }
        defer { gbfx_bender_free(bender) }

        let probe = try MediaDecoder(url: c.input, pixelFormat: "rgba")
        var sw: UInt32 = 0, sh: UInt32 = 0
        guard gbfx_bender_scaled_size(UInt32(probe.info.width), UInt32(probe.info.height), UInt32(max(scanlines, 0)),
                                      &sw, &sh) == GBFX_OK
        else { throw EffectError("cannot scale \(probe.info.width)x\(probe.info.height) to \(scanlines) lines") }
        let w = Int(sw), h = Int(sh)
        let source = try RGBSource(url: c.input, width: w, height: h, bytesPerPixel: 4)
        let rate = source.rate
        // bender 0.2.1 tags (and converts) BT.601 with centred chroma at every height (measured:
        // a 1280x720 render is smpte170m / chroma center), unlike ntsc-rs-cli.
        let colour = Colorimetry.bt601
        let converter = try MediaConverter(width: w, height: h, pixelFormat: "rgba", filters: colour.yuv420Filter())
        let encoder = try MediaEncoder(url: c.output, config: Effect.encoderConfig(
            codec: Int32(GBM_CODEC_FFV1.rawValue), width: w, height: h, pixelFormat: "yuv420p", rate: rate,
            sar: gbm_rational(num: 1, den: 1), space: colour.space, chromaLocation: colour.chromaLocation))

        var dst = [UInt8](repeating: 0, count: w * 4 * h)
        var count: Int64 = 0
        while try source.next({ (pixels, time) throws -> Bool in
            try Effect.check(flag)
            let index: Int64
            if let ns = time, ns >= 0 {
                index = gbfx_pts_frame_index(UInt64(ns), rate.num, rate.den)
            } else {
                index = count
            }
            try dst.withUnsafeMutableBufferPointer { d in
                _ = try Effect.fx("bender frame \(count)", {
                    gbfx_bender_apply(bender, pixels.assumingMemoryBound(to: UInt8.self), w * 4, d.baseAddress, w * 4,
                                      UInt32(w), UInt32(h), UInt64(max(index, 0)), $0)
                }, failed: { $0 != GBFX_OK })
            }
            let yuv = try dst.withUnsafeBytes { try converter.run(packed: $0.baseAddress!, stride: w * 4) }
            try encoder.write(yuv, index: count)
            count += 1
            return true
        }) != nil {}
        guard count > 0 else { throw EffectError("\(c.input.lastPathComponent) has no video frames") }
        try encoder.finish()
    }
}
