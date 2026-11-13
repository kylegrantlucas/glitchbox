import Foundation
import GBMedia
import GlitchboxFX
import GlitchboxKit

// Shared plumbing of the Rust-backed native steps (analog-pass, bender, reactive-vcr,
// still-motion): a raw-frame converter, the GStreamer colorimetry rules the macOS CLIs
// encode with, videorate-style retiming, and the run wrapper (dedicated thread, log,
// cancellation).

/// Runs raw frames through a one-in/one-out libavfilter chain (see `gbm_converter_open`).
final class MediaConverter {
    let raw: OpaquePointer
    let width: Int, height: Int, pixelFormat: Int32

    init(width: Int, height: Int, pixelFormat: String, filters: String,
         colorSpace: Int32 = AVColor.unspecified, colorRange: Int32 = AVColor.rangeUnspecified) throws {
        let fmt = gbm_pix_fmt(pixelFormat)
        guard fmt >= 0 else { throw EffectError("unknown pixel format \(pixelFormat)") }
        var c: OpaquePointer?
        var err: UnsafeMutablePointer<CChar>?
        let rc = gbm_converter_open(&c, Int32(width), Int32(height), fmt, colorSpace, colorRange, filters, &err)
        guard rc >= 0, let c else { throw MediaError.take(rc, err, "open converter") }
        raw = c
        var w: Int32 = 0, h: Int32 = 0, f: Int32 = 0
        gbm_converter_output(c, &w, &h, &f)
        self.width = Int(w); self.height = Int(h); self.pixelFormat = f
    }

    deinit {
        var c: OpaquePointer? = raw
        gbm_converter_free(&c)
    }

    /// Converts one packed single-plane frame; the result's planes live until the next call.
    func run(packed: UnsafeRawPointer, stride: Int) throws -> gbm_frame {
        var frame = gbm_frame()
        let data: [UnsafePointer<UInt8>?] = [packed.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
        let linesize: [Int32] = [Int32(stride), 0, 0, 0]
        let rc = data.withUnsafeBufferPointer { d in
            linesize.withUnsafeBufferPointer { l in gbm_converter_run(raw, d.baseAddress, l.baseAddress, &frame) }
        }
        if rc < 0 { throw MediaError.take(rc, nil, "convert") }
        return frame
    }
}

/// libavutil colour enum values (AVColorSpace/Primaries/Transfer/Range, AVChromaLocation).
enum AVColor {
    static let bt709: Int32 = 1
    static let unspecified: Int32 = 2
    static let smpte170m: Int32 = 6
    static let rangeUnspecified: Int32 = 0
    static let rangeLimited: Int32 = 1   // AVCOL_RANGE_MPEG
    static let chromaUnspecified: Int32 = 0 // AVCHROMA_LOC_UNSPECIFIED
    static let chromaLeft: Int32 = 1     // AVCHROMA_LOC_LEFT
    static let chromaCenter: Int32 = 2   // AVCHROMA_LOC_CENTER
}

/// GStreamer's default video colorimetry for a frame height, as the CLIs' videoconvert
/// applies it: BT.601 (smpte170m, chroma centred) up to 576 lines, BT.709 (chroma left) above.
struct Colorimetry {
    var matrix: String          // swscale out_color_matrix
    var space: Int32
    var chromaLocation: Int32
    var chromaLocationName: String

    static let bt601 = Colorimetry(matrix: "bt601", space: AVColor.smpte170m,
                                   chromaLocation: AVColor.chromaCenter, chromaLocationName: "center")
    static let bt709 = Colorimetry(matrix: "bt709", space: AVColor.bt709,
                                   chromaLocation: AVColor.chromaLeft, chromaLocationName: "left")

    static func forHeight(_ height: Int) -> Colorimetry { height <= 576 ? .bt601 : .bt709 }

    /// RGB → limited-range yuv420p as the CLIs' videoconvert does it (2×2 box chroma).
    func yuv420Filter() -> String {
        "scale=out_range=tv:out_color_matrix=\(matrix):out_chroma_loc=\(chromaLocationName)"
            + ":flags=area+accurate_rnd+full_chroma_int,format=yuv420p"
    }
}

struct EffectError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Thrown inside a step body when its cancel flag is set.
struct EffectCancelled: Error {}

enum Effect {
    /// Runs `body` on a dedicated thread; the flag it gets is set when the task is cancelled.
    /// Errors are logged as `<name>: <message>` and become exit code 1; a cancelled body
    /// returns 255. Returns only after `body` has returned (and then throws
    /// `CancellationError` if the task was cancelled), so nothing keeps running past it.
    /// A failed or cancelled run removes its partial output.
    static func run(_ c: NativeStepContext, name: String,
                    _ body: @escaping @Sendable (CancelFlag) throws -> Void) async throws -> Int32 {
        try FileManager.default.createDirectory(at: c.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let log = c.log, output = c.output
        let code = try await ToolCall.cancellable(name) { flag in
            let code: Int32
            do {
                try body(flag)
                code = 0
            } catch is EffectCancelled {
                code = 255
            } catch {
                ToolCall.append(log, "\(name): \(error.localizedDescription)\n")
                code = 1
            }
            if code != 0 { try? FileManager.default.removeItem(at: output) }
            return code
        }
        return code
    }

    static func check(_ flag: CancelFlag) throws {
        if flag.isSet { throw EffectCancelled() }
    }

    /// Calls a GlitchboxFX function taking `char **error`, turning a reported error into a throw.
    static func fx<T>(_ what: String, _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T,
                      failed: (T) -> Bool) throws -> T {
        var err: UnsafeMutablePointer<CChar>?
        let result = body(&err)
        if let err {
            let message = String(cString: err)
            gbfx_string_free(err)
            if failed(result) { throw EffectError("\(what): \(message)") }
        } else if failed(result) {
            throw EffectError("\(what) failed")
        }
        return result
    }

    /// A frame rate usable as the stream's nominal rate (unknown → 30/1, as the CLIs do).
    static func nominalRate(_ r: gbm_rational) -> gbm_rational {
        r.num > 0 && r.den > 0 ? r : gbm_rational(num: 30, den: 1)
    }

    /// A decoded frame's timestamp in nanoseconds, or nil when it has none.
    static func timestampNs(_ frame: gbm_frame, timeBase tb: gbm_rational) -> Int64? {
        guard frame.pts != Int64.min, tb.den > 0 else { return nil }
        let ns = (Int128(frame.pts) * Int128(tb.num) * 1_000_000_000) / Int128(tb.den)
        return Int64(clamping: ns)
    }

    /// Encoder settings shared by the FFV1 layers.
    static func encoderConfig(codec: Int32, width: Int, height: Int, pixelFormat: String, rate: gbm_rational,
                              sar: gbm_rational = gbm_rational(num: 0, den: 1),
                              space: Int32, primaries: Int32 = AVColor.unspecified,
                              transfer: Int32 = AVColor.unspecified, chromaLocation: Int32) throws -> gbm_encoder_config {
        let fmt = gbm_pix_fmt(pixelFormat)
        guard fmt >= 0 else { throw EffectError("unknown pixel format \(pixelFormat)") }
        var config = gbm_encoder_config()
        config.codec = codec
        config.width = Int32(width)
        config.height = Int32(height)
        config.pix_fmt = fmt
        config.frame_rate = rate
        config.sar = sar
        config.color_space = space
        config.color_range = AVColor.rangeLimited
        config.color_primaries = primaries
        config.color_trc = transfer
        config.chroma_location = chromaLocation
        config.threads = 0
        return config
    }
}

/// GStreamer `videorate` over decoded frames: output slot k sits at k · fps_d / fps_n s and
/// takes the input frame nearest to it (ties to the earlier one); after the last input,
/// slots continue until that frame's nominal duration ends.
struct Retimer {
    let rate: gbm_rational
    private(set) var next: Int64 = 0

    init(rate: gbm_rational) { self.rate = rate }

    func slotNs(_ k: Int64) -> Int64 {
        Int64(clamping: Int128(k) * Int128(rate.den) * 1_000_000_000 / Int128(rate.num))
    }

    var frameNs: Int64 { slotNs(1) }

    /// The slots the previous frame (at `previousNs`) fills now that a frame at `ns` arrived.
    mutating func advance(previousNs: Int64, ns: Int64) -> Range<Int64> {
        let start = next
        while 2 * Int128(slotNs(next)) <= Int128(previousNs) + Int128(ns) { next += 1 }
        return start..<next
    }

    /// The slots the last frame (at `lastNs`) fills at end of stream: until its nominal
    /// duration ends. With millisecond timestamps a 30 fps stream's last frame (967 ms) lasts
    /// to 1000.33 ms, so slot N (1000 ms) is filled too: ntsc-rs-cli's N + 1 frames.
    mutating func finish(lastNs: Int64) -> Range<Int64> {
        let start = next
        while slotNs(next) < lastNs + frameNs { next += 1 }
        return start..<next
    }
}

extension NativeStepContext {
    /// A file param's path ("" = unset); relative paths resolve against the library root.
    func fileParam(_ key: String) -> String? {
        guard case .string(let s)? = params[key], !s.isEmpty else { return nil }
        return s.hasPrefix("/") ? s : root.appending(path: s).path
    }
}
