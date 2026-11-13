import Foundation
import GBMedia

/// A GBMedia failure: the operation and libav's message.
public struct MediaError: Error, LocalizedError {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { message }

    static func take(_ code: Int32, _ err: UnsafeMutablePointer<CChar>?, _ what: String) -> MediaError {
        defer { gbm_string_free(err) }
        if let err { return MediaError(code: code, message: String(cString: err)) }
        let s = gbm_error_string(code)
        defer { gbm_string_free(s) }
        return MediaError(code: code, message: "\(what): \(s.map { String(cString: $0) } ?? "error \(code)")")
    }
}

/// Decodes a file's first video stream to one pixel format and size (see `gbm_decoder_open`).
/// Not shareable across threads; every decoder is independent.
public final class MediaDecoder {
    let raw: OpaquePointer

    /// `width`/`height` 0 keep the source size; `scaleFlags` nil = bicubic+accurate_rnd+full_chroma_int.
    public init(url: URL, width: Int = 0, height: Int = 0, pixelFormat: String,
                scaleFlags: String? = nil, filters: String? = nil, threads: Int = 0) throws {
        let fmt = gbm_pix_fmt(pixelFormat)
        guard fmt >= 0 else { throw MediaError(code: -22, message: "unknown pixel format \(pixelFormat)") }
        var d: OpaquePointer?
        var err: UnsafeMutablePointer<CChar>?
        let rc = gbm_decoder_open(&d, url.path, Int32(width), Int32(height), fmt, scaleFlags, filters, Int32(threads), &err)
        guard rc >= 0, let d else { throw MediaError.take(rc, err, "open \(url.lastPathComponent)") }
        raw = d
    }

    deinit {
        var d: OpaquePointer? = raw
        gbm_decoder_free(&d)
    }

    public var info: gbm_video_info { gbm_decoder_info(raw).pointee }

    /// Output width, height, pixel format, time base, and frame rate after conversion.
    public var output: (width: Int, height: Int, pixelFormat: Int32, timeBase: gbm_rational, frameRate: gbm_rational) {
        var w: Int32 = 0, h: Int32 = 0, f: Int32 = 0
        var tb = gbm_rational(), rate = gbm_rational()
        gbm_decoder_output(raw, &w, &h, &f, &tb, &rate)
        return (Int(w), Int(h), f, tb, rate)
    }

    /// The next frame (planes valid until the next call), or nil at the end.
    public func next() throws -> gbm_frame? {
        var frame = gbm_frame()
        let rc = gbm_decoder_next(raw, &frame)
        if rc < 0 { throw MediaError.take(rc, nil, "decode") }
        return rc == 0 ? nil : frame
    }
}

/// Writes lossless (FFV1 or ffvhuff) video into Matroska with bit-exact flags (see `gbm_encoder_open`).
public final class MediaEncoder {
    let raw: OpaquePointer

    public init(url: URL, config: gbm_encoder_config, codecOptions: String? = nil) throws {
        var config = config
        var e: OpaquePointer?
        var err: UnsafeMutablePointer<CChar>?
        let rc = codecOptions.withOptionalCString { opts in
            config.codec_options = opts
            return gbm_encoder_open(&e, url.path, &config, &err)
        }
        guard rc >= 0, let e else { throw MediaError.take(rc, err, "open encoder") }
        raw = e
    }

    deinit {
        var e: OpaquePointer? = raw
        gbm_encoder_free(&e)
    }

    /// Encodes one frame whose planes match the configured format and size.
    public func write(data: [UnsafePointer<UInt8>?], linesize: [Int32], index: Int64) throws {
        precondition(data.count == 4 && linesize.count == 4)
        let rc = data.withUnsafeBufferPointer { d in
            linesize.withUnsafeBufferPointer { l in gbm_encoder_write(raw, d.baseAddress, l.baseAddress, index) }
        }
        if rc < 0 { throw MediaError.take(rc, nil, "encode") }
    }

    /// Encodes a decoded frame (same format and size as configured).
    public func write(_ frame: gbm_frame, index: Int64) throws {
        var f = frame
        let data = withUnsafeBytes(of: &f.data) { Array($0.bindMemory(to: UnsafeMutablePointer<UInt8>?.self)) }
            .map { $0.map { UnsafePointer($0) } }
        let linesize = withUnsafeBytes(of: &f.linesize) { Array($0.bindMemory(to: Int32.self)) }
        try write(data: data, linesize: linesize, index: index)
    }

    public func finish() throws {
        let rc = gbm_encoder_finish(raw)
        if rc < 0 { throw MediaError.take(rc, nil, "finish") }
    }
}

public enum MediaAudio {
    /// The first audio stream of `url` as mono float samples at `sampleRate`.
    public static func decodeMono(url: URL, sampleRate: Int) throws -> [Float] {
        var samples: UnsafeMutablePointer<Float>?
        var count: Int64 = 0
        var err: UnsafeMutablePointer<CChar>?
        let rc = gbm_decode_audio_mono(url.path, Int32(sampleRate), &samples, &count, &err)
        guard rc >= 0 else { throw MediaError.take(rc, err, "decode audio") }
        defer { gbm_samples_free(samples) }
        guard let samples else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(count)))
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let s): s.withCString { body($0) }
        case .none: body(nil)
        }
    }
}
