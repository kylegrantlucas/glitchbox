import Foundation
import GBMedia

/// GStreamer videoconvert's I420 → packed RGB fast path (`convert_I420_pack_ARGB`:
/// `video_orc_convert_I420_ARGB` then the RGB pack), bit for bit. The macOS CLIs feed their
/// effects through it, and the glitch effects amplify the ±1 differences any other
/// YUV → RGB conversion has into visibly different output, so 4:2:0 layers (every source-prep,
/// ffmpeg, ntsc-rs, bender, and still-motion layer) are converted here instead of by swscale.
///
/// Matrix: gst-plugins-base 1.28 `video_converter_compute_matrix` (offset/scale to [0, 1] with
/// float divisors, YCbCr → R'G'B' with the input's Kr/Kb, scale to 0–255, × 256, `rint`).
/// Chroma is nearest (`loadupdb`): pixel x of row y uses chroma (x / 2, y / 2).
struct GstI420ToRGB {
    let p1: Int32, p2: Int32, p3: Int32, p4: Int32, p5: Int32
    /// See `terms(_:)`.
    private let terms: [Int32]

    /// `colorSpace`/`colorRange`: the decoded stream's AVColorSpace/AVColorRange; unknown
    /// matrices take GStreamer's default for the frame height (BT.601 up to 576 lines).
    init(colorSpace: Int32, colorRange: Int32, height: Int) {
        let (kr, kb) = Self.kr_kb(colorSpace: colorSpace, height: height)
        var m = Matrix.identity
        Self.toRGB(&m, kr: kr, kb: kb, full: colorRange == 2)
        // compute_matrix_to_YUV for RGB output: full range 0–255.
        m.scale(255, 255, 255)
        m.offset(0, 0, 0)
        // prepare_matrix: × SCALE_F (256), rint.
        m.scale(256, 256, 256)
        func im(_ i: Int, _ j: Int) -> Int32 { Int32(m.d[i][j].rounded(.toNearestOrEven)) }
        p1 = im(0, 0); p2 = im(0, 2); p3 = im(2, 1); p4 = im(1, 1); p5 = im(1, 2)
        terms = Self.terms([p1, p2, p3, p4, p5])
    }

    /// `gst_video_color_matrix_get_Kr_Kb` for the stream's AVColorSpace; unknown matrices take
    /// GStreamer's default for the frame height (BT.601 up to 576 lines).
    static func kr_kb(colorSpace: Int32, height: Int) -> (Double, Double) {
        switch colorSpace {
        case 1: (0.2126, 0.0722)                       // bt709
        case 5, 6: (0.2990, 0.1140)                    // bt470bg, smpte170m
        case 7: (0.212, 0.087)                         // smpte240m
        case 9, 10: (0.2627, 0.0593)                   // bt2020
        case 4: (0.30, 0.11)                           // fcc
        default: height <= 576 ? (0.2990, 0.1140) : (0.2126, 0.0722)
        }
    }

    /// `compute_matrix_to_RGB` for 8-bit YUV input: the range's offsets and float divisors,
    /// then YCbCr → R'G'B'.
    static func toRGB(_ m: inout Matrix, kr: Double, kb: Double, full: Bool) {
        if full {
            m.offset(0, -128, -128)
            m.scale(Double(1 / Float(255)), Double(1 / Float(255)), Double(1 / Float(255)))
        } else {
            m.offset(-16, -128, -128)
            m.scale(Double(1 / Float(219)), Double(1 / Float(224)), Double(1 / Float(224)))
        }
        let kg = 1 - kr - kb
        m.multiply(left: [[1, 0, 2 * (1 - kr), 0],
                          [1, -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 0],
                          [1, 2 * (1 - kb), 0, 0],
                          [0, 0, 0, 1]])
    }
    /// Converts one yuv420p frame into packed RGB (`bytesPerPixel` 3) or RGBA (4, alpha 255).
    ///
    /// orc's per-pixel terms depend on one input byte each, so they come from `terms`
    /// (Y·p1, V·p2, U·p3, U·p4, V·p5 as `mulhs` of the splatted byte); each chroma pair's
    /// terms are looked up once for both of its pixels.
    func convert(_ f: gbm_frame, into dst: UnsafeMutablePointer<UInt8>, stride: Int, bytesPerPixel: Int) {
        let w = Int(f.width), h = Int(f.height)
        let ys = Int(f.linesize.0), us = Int(f.linesize.1), vs = Int(f.linesize.2)
        terms.withUnsafeBufferPointer { t in
            let tY = t.baseAddress!, tR = tY + 256, tB = tY + 512, tGU = tY + 768, tGV = tY + 1024
            @inline(__always) func wrap(_ v: Int32) -> Int32 { Int32(Int16(truncatingIfNeeded: v)) }
            @inline(__always) func sat(_ v: Int32) -> UInt8 { UInt8(truncatingIfNeeded: min(max(v, -128), 127) &+ 128) }
            @inline(__always) func pixel(_ o: UnsafeMutablePointer<UInt8>, _ wy: Int32, _ r: Int32, _ b: Int32,
                                         _ gu: Int32, _ gv: Int32) {
                o[0] = sat(wrap(wy &+ r))
                o[1] = sat(wrap(wrap(wy &+ gu) &+ gv))
                o[2] = sat(wrap(wy &+ b))
            }
            for y in 0..<h {
                let yr = f.data.0! + y &* ys, ur = f.data.1! + (y >> 1) &* us, vr = f.data.2! + (y >> 1) &* vs
                let out = dst + y &* stride
                let pairs = w >> 1
                if bytesPerPixel == 4 {
                    for x in 0..<pairs {
                        let u = Int(ur[x]), v = Int(vr[x])
                        let r = tR[v], b = tB[u], gu = tGU[u], gv = tGV[v]
                        let o = out + x &* 8
                        pixel(o, tY[Int(yr[2 &* x])], r, b, gu, gv); o[3] = 255
                        pixel(o + 4, tY[Int(yr[2 &* x &+ 1])], r, b, gu, gv); o[7] = 255
                    }
                } else {
                    for x in 0..<pairs {
                        let u = Int(ur[x]), v = Int(vr[x])
                        let r = tR[v], b = tB[u], gu = tGU[u], gv = tGV[v]
                        let o = out + x &* 6
                        pixel(o, tY[Int(yr[2 &* x])], r, b, gu, gv)
                        pixel(o + 3, tY[Int(yr[2 &* x &+ 1])], r, b, gu, gv)
                    }
                }
                if w & 1 == 1 {
                    let x = w - 1, u = Int(ur[x >> 1]), v = Int(vr[x >> 1])
                    let o = out + x &* bytesPerPixel
                    pixel(o, tY[Int(yr[x])], tR[v], tB[u], tGU[u], tGV[v])
                    if bytesPerPixel == 4 { o[3] = 255 }
                }
            }
        }
    }

    /// `mulhs(splat(v), p)` for every byte `v`, for p1…p5 in turn (5 × 256).
    static func terms(_ ps: [Int32]) -> [Int32] {
        ps.flatMap { p in
            (0..<256).map { (v: Int) -> Int32 in
                let r = UInt8(v) &- 128
                let s = Int32(Int16(bitPattern: UInt16(r) << 8 | UInt16(r)))
                return (s * Int32(Int16(truncatingIfNeeded: p))) >> 16
            }
        }
    }

    /// GStreamer's 4×4 colour matrix (row-major `dm`), double precision.
    struct Matrix {
        var d: [[Double]]
        static var identity: Matrix { Matrix(d: (0..<4).map { i in (0..<4).map { $0 == i ? 1 : 0 } }) }

        mutating func multiply(left a: [[Double]]) {
            var t = d
            for i in 0..<4 {
                for j in 0..<4 {
                    var x = 0.0
                    for k in 0..<4 { x += a[i][k] * d[k][j] }
                    t[i][j] = x
                }
            }
            d = t
        }

        mutating func offset(_ a1: Double, _ a2: Double, _ a3: Double) {
            var a = Matrix.identity.d
            a[0][3] = a1; a[1][3] = a2; a[2][3] = a3
            multiply(left: a)
        }

        mutating func scale(_ a1: Double, _ a2: Double, _ a3: Double) {
            var a = Matrix.identity.d
            a[0][0] = a1; a[1][1] = a2; a[2][2] = a3
            multiply(left: a)
        }
    }
}

/// Decoded frames as packed RGB24/RGBA at a target size, the way the macOS CLIs' GStreamer
/// graphs (`videoconvert ! videoscale`) produce them: yuv420p sources through `GstI420ToRGB`
/// (bit-exact), other formats through swscale; then, if the size changes,
/// `GstBilinearScaler` (bit-exact videoscale).
final class RGBSource {
    let decoder: MediaDecoder
    let width: Int, height: Int, bytesPerPixel: Int
    let timeBase: gbm_rational
    private let gst: GstI420ToRGB?
    private let resize: GstBilinearScaler?
    /// The frame at the source size; only used when resizing.
    private var native: [UInt8]

    /// `width`/`height` 0 keep the source size. `bytesPerPixel`: 3 (rgb24) or 4 (rgba).
    init(url: URL, width: Int = 0, height: Int = 0, bytesPerPixel: Int) throws {
        let fmt = bytesPerPixel == 4 ? "rgba" : "rgb24"
        let probe = try MediaDecoder(url: url, pixelFormat: fmt, threads: Effect.decodeThreads)
        let info = probe.info
        let sw = Int(info.width), sh = Int(info.height)
        let w = width > 0 ? width : sw, h = height > 0 ? height : sh
        self.width = w; self.height = h; self.bytesPerPixel = bytesPerPixel
        if info.pix_fmt == gbm_pix_fmt("yuv420p") {
            decoder = try MediaDecoder(url: url, pixelFormat: "yuv420p", threads: Effect.decodeThreads)
            gst = GstI420ToRGB(colorSpace: info.color_space, colorRange: info.color_range, height: sh)
        } else {
            decoder = probe
            gst = nil
        }
        resize = (w, h) == (sw, sh) ? nil
            : GstBilinearScaler(inWidth: sw, inHeight: sh, outWidth: w, outHeight: h, elems: bytesPerPixel)
        native = resize == nil ? [] : [UInt8](repeating: 0, count: sw * sh * bytesPerPixel)
        timeBase = decoder.output.timeBase
        rate = Effect.nominalRate(info.frame_rate)
        var name = info.codec_name
        exactTimes = withUnsafeBytes(of: &name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == "ffvhuff"
    }

    /// The stream's nominal rate (unknown → 30/1).
    let rate: gbm_rational
    /// Whether the CLIs' GStreamer decode times frames exactly (k · fps_d / fps_n) instead of by
    /// the demuxed Matroska timestamps (whole ms). Measured against bender 0.2.1 and
    /// ntsc-rs-cli 0.9.4: ffvhuff layers (source prep, ffmpeg layers) get exact times —
    /// bender's indices run 0,1,2,… and ntsc-rs-cli's videorate ends after N frames — while
    /// FFV1 and H.264 layers get millisecond times (bender 0,0,2,3,3,5,…; ntsc-rs N + 1).
    let exactTimes: Bool
    private var count: Int64 = 0

    var info: gbm_video_info { decoder.info }

    /// Decodes the next frame into `dst` (packed, `width` · `bytesPerPixel` per row) and returns
    /// its time in ns as the CLIs' GStreamer graphs see it (nil when the frame has no
    /// timestamp), or nil at the end (`.none`).
    func next(into dst: UnsafeMutableRawPointer) throws -> Int64?? {
        guard let frame = try decoder.next() else { return .none }
        let k = count
        count += 1
        let ns = exactTimes
            ? Int64(clamping: Int128(k) * Int128(rate.den) * 1_000_000_000 / Int128(rate.num))
            : Effect.timestampNs(frame, timeBase: timeBase)
        let bpp = bytesPerPixel, gst = gst
        func load(into d: UnsafeMutablePointer<UInt8>) {
            let nativeStride = Int(frame.width) * bpp
            if let gst {
                gst.convert(frame, into: d, stride: nativeStride, bytesPerPixel: bpp)
            } else {
                for y in 0..<Int(frame.height) {
                    (d + y * nativeStride).update(from: frame.data.0! + y * Int(frame.linesize.0), count: nativeStride)
                }
            }
        }
        let d = dst.assumingMemoryBound(to: UInt8.self)
        if let resize {
            native.withUnsafeMutableBufferPointer { n in
                load(into: n.baseAddress!)
                resize.scale(n.baseAddress!, into: d)
            }
        } else {
            load(into: d)
        }
        return .some(ns)
    }
}

/// GStreamer `videoscale method=bilinear` (the default) on packed 8-bit RGB/RGBA or ARGB64,
/// bit for bit: gst-plugins-base 1.28's video-converter scale chain with the LINEAR resampler
/// limited to 2 taps, the LQ u8 kernels (or the u16 ones), run as the same-format fast path
/// (`convert_scale_planes` → `gst_video_scaler_2d`) runs them. Taps, offsets, the pass order,
/// and the intermediate buffer are fixed per size, so they are computed once.
final class GstBilinearScaler {
    let inWidth: Int, inHeight: Int, outWidth: Int, outHeight: Int, elems: Int
    /// gst_video_scaler_2d: horizontal first when out_w · voffset[out_h - 1] <= out_w · out_h.
    private let horizontalFirst: Bool
    private let hTaps: Int, vTaps: Int
    /// Horizontal: the resampler's source pixel of each output column (the first tap), and
    /// the 4u8 fast path's own first and second pixels and 8-bit fraction.
    private let hOffset: [Int], hFast: [Int], hNext: [Int], hFrac: [Int32]
    /// Horizontal taps: 6-bit (u8) and 12-bit (u16) for tap 0 and tap 1.
    private let h8t0: [Int16], h8t1: [Int16], h16t0: [Int32], h16t1: [Int32]
    /// Vertical: first source row of each output row, its pair (clamped), and the second
    /// tap: 8-bit sign-extended (u8), 12-bit zero-extended (u16, convuwl).
    private let vOffset: [Int], vNext: [Int], v8p1: [Int16], v16p1: [Int32]
    private var mid8: [UInt8] = [], mid16: [UInt16] = []

    init(inWidth: Int, inHeight: Int, outWidth: Int, outHeight: Int, elems: Int) {
        self.inWidth = inWidth; self.inHeight = inHeight
        self.outWidth = outWidth; self.outHeight = outHeight; self.elems = elems
        let hr = Resampler(inSize: inWidth, outSize: outWidth)
        let vr = Resampler(inSize: inHeight, outSize: outHeight)
        horizontalFirst = inHeight == outHeight || outWidth * vr.offset[outHeight - 1] <= outWidth * outHeight
        hTaps = hr.maxTaps; vTaps = vr.maxTaps
        // video_scale_h_2tap_4u8: ldreslinl stepping by inc = ((in - 1) << 16) / (out - 1) - 1.
        let inc = outWidth == 1 ? 0 : ((inWidth - 1) << 16) / (outWidth - 1) - 1
        var next = [Int](), frac = [Int32]()
        if hr.maxTaps == 2 && elems == 4 {
            for i in 0..<outWidth {
                let tmp = i * inc
                next.append((tmp >> 16) + 1 < inWidth ? (tmp >> 16) + 1 : tmp >> 16)
                frac.append(Int32((tmp >> 8) & 0xff))
            }
        }
        hOffset = hr.offset
        hFast = hr.maxTaps == 2 && elems == 4 ? (0..<outWidth).map { ($0 * inc) >> 16 } : []
        hNext = next; hFrac = frac
        let h8 = hr.maxTaps == 2 ? hr.intTaps(precision: 6) : []
        let h16 = hr.maxTaps == 2 ? hr.intTaps(precision: 12) : []
        h8t0 = h8.map { Int16(truncatingIfNeeded: $0[0]) }; h8t1 = h8.map { Int16(truncatingIfNeeded: $0[1]) }
        h16t0 = h16.map { $0[0] }; h16t1 = h16.map { $0[1] }
        vOffset = vr.offset
        vNext = vr.offset.map { min($0 + 1, inHeight - 1) }
        let v8 = vr.maxTaps == 2 ? vr.intTaps(precision: 8) : []
        let v16 = vr.maxTaps == 2 ? vr.intTaps(precision: 12) : []
        v8p1 = v8.map { Int16(truncatingIfNeeded: $0[1]) }
        v16p1 = v16.map { Int32(UInt16(truncatingIfNeeded: $0[1])) }
    }

    /// The 2-tap linear resampler (`gst_video_resampler_init` + `resampler_calculate_taps`).
    struct Resampler {
        var offset: [Int] = []
        var taps: [[Double]] = []
        var maxTaps = 2

        init(inSize: Int, outSize: Int) {
            maxTaps = min(2, inSize)
            let fx = 2.0 / Double(maxTaps)   // params.fx = 2 · envelope / n_taps
            let tapOffs = (maxTaps - 1) / 2
            let corr = maxTaps == 1 ? 0.0 : 0.5
            for j in 0..<outSize {
                let ox = (0.5 + Double(j)) / Double(outSize)
                var x = ox * Double(inSize) - corr
                x = min(max(x, 0), Double(inSize - 1))
                let xi = Int((x - Double(tapOffs)).rounded(.down))
                var t = (0..<maxTaps).map { l -> Double in
                    let a = abs(x - Double(xi + l)) * fx
                    return a < 1 ? 1 - a : 0
                }
                let weight = t.reduce(0, +)
                t = t.map { $0 / weight }
                var off = xi
                if xi < 0 {
                    let sh = -xi
                    for l in 0..<sh { t[sh] += t[l] }
                    for l in 0..<(maxTaps - sh) { t[l] = t[sh + l] }
                    for l in (maxTaps - sh)..<maxTaps { t[l] = 0 }
                    off += sh
                }
                if xi > inSize - maxTaps {
                    let sh = xi - (inSize - maxTaps)
                    for l in 0..<sh { t[maxTaps - sh - 1] += t[maxTaps - sh + l] }
                    for l in 0..<(maxTaps - sh) { t[maxTaps - 1 - l] = t[maxTaps - 1 - sh - l] }
                    for l in 0..<sh { t[l] = 0 }
                    off -= sh
                }
                offset.append(off)
                taps.append(t)
            }
        }

        /// `resampler_convert_coeff`: rounding with a searched bias so each phase sums to 1 << precision.
        func intTaps(precision: Int) -> [[Int32]] {
            taps.map { src in
                let multiplier = Double(1 << precision)
                var lo = 0.0, hi = 1.0, bias = 0.5
                var out = [Int32](repeating: 0, count: src.count)
                for _ in 0..<64 {
                    var sum: Int32 = 0
                    for j in src.indices {
                        out[j] = Int32(Int16(truncatingIfNeeded: Int((bias + src[j] * multiplier).rounded(.down))))
                        sum += out[j]
                    }
                    if sum == 1 << precision || lo == hi { break }
                    if sum < 1 << precision {
                        if bias > lo { lo = bias }
                        bias += (hi - lo) / 2
                    } else {
                        if bias < hi { hi = bias }
                        bias -= (hi - lo) / 2
                    }
                }
                return out
            }
        }
    }

    /// Runs the two passes in GStreamer's order through the intermediate buffer.
    private func passes<T>(_ mid: inout [T], zero: T, src: UnsafePointer<T>, dst: UnsafeMutablePointer<T>,
                           h: (UnsafePointer<T>, UnsafeMutablePointer<T>, Int) -> Void,
                           v: (UnsafePointer<T>, UnsafeMutablePointer<T>, Int) -> Void) {
        let scaleH = inWidth != outWidth, scaleV = inHeight != outHeight
        guard scaleH && scaleV else {
            if scaleH { h(src, dst, inHeight) } else if scaleV { v(src, dst, inWidth) }
            else { dst.update(from: src, count: inWidth * inHeight * elems) }
            return
        }
        let count = (horizontalFirst ? outWidth * inHeight : inWidth * outHeight) * elems
        if mid.count != count { mid = [T](repeating: zero, count: count) }
        mid.withUnsafeMutableBufferPointer { m in
            let m = m.baseAddress!
            if horizontalFirst {
                h(src, m, inHeight); v(m, dst, outWidth)
            } else {
                v(src, m, inWidth); h(m, dst, outHeight)
            }
        }
    }

    /// Scales `src` (inWidth × inHeight, packed, `elems` bytes per pixel) into `dst`.
    func scale(_ src: UnsafePointer<UInt8>, into dst: UnsafeMutablePointer<UInt8>) {
        passes(&mid8, zero: 0, src: src, dst: dst, h: horizontal, v: vertical)
    }

    /// The same scale on ARGB64 (`elems` 4, uint16): `video_scale_h_ntap_u16`
    /// (`resample_h_2tap_u16`) and `video_scale_v_2tap_u16`, 12-bit taps.
    func scale16(_ src: UnsafePointer<UInt16>, into dst: UnsafeMutablePointer<UInt16>) {
        passes(&mid16, zero: 0, src: src, dst: dst, h: horizontal16, v: vertical16)
    }

    private func horizontal(_ src: UnsafePointer<UInt8>, _ out: UnsafeMutablePointer<UInt8>, _ height: Int) {
        let width = inWidth, ow = outWidth, e = elems
        hOffset.withUnsafeBufferPointer { offset in
            if hTaps == 2 && e == 4 {
                hFast.withUnsafeBufferPointer { first in hNext.withUnsafeBufferPointer { next in hFrac.withUnsafeBufferPointer { frac in
                    for y in 0..<height {
                        let s = src + y &* width &* 4, d = out + y &* ow &* 4
                        for i in 0..<ow {
                            let a = s + first[i] &* 4, b = s + next[i] &* 4, f = frac[i], g = 256 &- f
                            let o = d + i &* 4
                            for c in 0..<4 {
                                o[c] = UInt8(truncatingIfNeeded: (Int32(a[c]) &* g &+ Int32(b[c]) &* f) >> 8)
                            }
                        }
                    }
                } } }
            } else if hTaps == 1 {
                for y in 0..<height {
                    let s = src + y &* width &* e, d = out + y &* ow &* e
                    for i in 0..<ow { (d + i &* e).update(from: s + offset[i] &* e, count: e) }
                }
            } else {
                // video_scale_h_ntap_u8 (2 taps): h_2tap_u8_lq, 6-bit taps, 16-bit wrapping.
                h8t0.withUnsafeBufferPointer { t0 in h8t1.withUnsafeBufferPointer { t1 in
                    for y in 0..<height {
                        let s = src + y &* width &* e, d = out + y &* ow &* e
                        for i in 0..<ow {
                            let a = s + offset[i] &* e, p0 = t0[i], p1 = t1[i], o = d + i &* e
                            for c in 0..<e {
                                let acc = Int16(a[c]) &* p0 &+ Int16(a[c &+ e]) &* p1
                                o[c] = UInt8(truncatingIfNeeded: min(max((acc &+ 32) >> 6, 0), 255))
                            }
                        }
                    }
                } }
            }
        }
    }

    private func vertical(_ src: UnsafePointer<UInt8>, _ out: UnsafeMutablePointer<UInt8>, _ width: Int) {
        let row = width * elems
        if vTaps == 1 {
            for j in 0..<outHeight { (out + j * row).update(from: src + vOffset[j] * row, count: row) }
            return
        }
        // video_scale_v_2tap_u8 (LQ): 8-bit taps; d = s1 + hi8((s2 - s1) · p1 + 128), 16-bit wrapping.
        for j in 0..<outHeight {
            let p1 = v8p1[j], s1 = src + vOffset[j] * row, s2 = src + vNext[j] * row, d = out + j * row
            for k in 0..<row {
                let a = Int16(s1[k]), b = Int16(s2[k])
                let w = (b &- a) &* p1 &+ 128
                d[k] = UInt8(truncatingIfNeeded: w >> 8) &+ UInt8(truncatingIfNeeded: a)
            }
        }
    }

    private func horizontal16(_ src: UnsafePointer<UInt16>, _ out: UnsafeMutablePointer<UInt16>, _ height: Int) {
        let width = inWidth, ow = outWidth
        hOffset.withUnsafeBufferPointer { offset in
            if hTaps == 1 {
                for y in 0..<height {
                    let s = src + y &* width &* 4, d = out + y &* ow &* 4
                    for i in 0..<ow { (d + i &* 4).update(from: s + offset[i] &* 4, count: 4) }
                }
                return
            }
            h16t0.withUnsafeBufferPointer { t0 in h16t1.withUnsafeBufferPointer { t1 in
                for y in 0..<height {
                    let s = src + y &* width &* 4, d = out + y &* ow &* 4
                    for i in 0..<ow {
                        let a = s + offset[i] &* 4, p0 = t0[i], p1 = t1[i], o = d + i &* 4
                        for c in 0..<4 {
                            let acc = Int32(a[c]) &* p0 &+ Int32(a[c &+ 4]) &* p1
                            o[c] = UInt16(truncatingIfNeeded: min(max((acc &+ 4096) >> 12, 0), 65535))
                        }
                    }
                }
            } }
        }
    }

    private func vertical16(_ src: UnsafePointer<UInt16>, _ out: UnsafeMutablePointer<UInt16>, _ width: Int) {
        let row = width * 4
        if vTaps == 1 {
            for j in 0..<outHeight { (out + j * row).update(from: src + vOffset[j] * row, count: row) }
            return
        }
        for j in 0..<outHeight {
            let p1 = v16p1[j], s1 = src + vOffset[j] * row, s2 = src + vNext[j] * row, d = out + j * row
            for k in 0..<row {
                let a = Int32(s1[k]), b = Int32(s2[k])
                let v = a &+ (((b &- a) &* p1 &+ 4096) >> 12)
                d[k] = UInt16(truncatingIfNeeded: min(max(v, 0), 65535))
            }
        }
    }
}

/// GStreamer videoconvert's generic path from 8-bit planar YUV (I420 / Y444) to ARGB64, bit
/// for bit (what ntsc-rs-cli's `videoconvert` feeds its ARGB64 filter): unpack to AYUV
/// (chroma repeated), chroma upsampling (`video_chroma_up_h2`/`_v2`, linear 3:1 taps; H
/// cosited sources average neighbours instead), widening to 16 bits (`v << 8 | v`), then
/// the 16-bit integer matrix (`video_converter_matrix16`).
///
/// The matrix runs as per-byte tables (`m[c][k] · v · 257`, the offset folded into Y's), and
/// the upsampled chroma lives in two reusable full-size planes.
final class GstYUVToARGB64 {
    let hCosited: Bool, vCosited: Bool
    /// For each output channel c: Y, U, V tables of 256 (Y's includes m[c][3]).
    private let terms: [Int64]
    private var u: [UInt8] = [], v: [UInt8] = []

    /// `chromaLocation`: AVChromaLocation of the stream (left → H cosited, topleft → both).
    init(colorSpace: Int32, colorRange: Int32, chromaLocation: Int32, height: Int) {
        let (kr, kb) = GstI420ToRGB.kr_kb(colorSpace: colorSpace, height: height)
        var m = GstI420ToRGB.Matrix.identity
        // in_bits 8 < out_bits 16: the matrix first scales the widened input back by 1/256.
        let inv256 = Double(1 / Float(256))
        m.scale(inv256, inv256, inv256)
        GstI420ToRGB.toRGB(&m, kr: kr, kb: kb, full: colorRange == 2)
        m.scale(65535, 65535, 65535)
        m.offset(0, 0, 0)
        m.scale(256, 256, 256)
        let im = m.d.map { $0.map { Int64($0.rounded(.toNearestOrEven)) } }
        var terms: [Int64] = []
        for c in 0..<3 {
            for k in 0..<3 {
                terms += (0..<256).map { im[c][k] * Int64($0) * 257 + (k == 0 ? im[c][3] : 0) }
            }
        }
        self.terms = terms
        hCosited = chromaLocation == 1 || chromaLocation == 3
        vCosited = chromaLocation == 3
    }

    /// Converts a yuv420p (`subsampled`) or yuv444p frame into XRGB16 (X = 0xFFFF), w · h · 4 values.
    func convert(_ f: gbm_frame, subsampled: Bool, into dst: UnsafeMutablePointer<UInt16>) {
        let w = Int(f.width), h = Int(f.height)
        if subsampled {
            if u.count != w * h { u = [UInt8](repeating: 0, count: w * h); v = u }
            u.withUnsafeMutableBufferPointer { up in v.withUnsafeMutableBufferPointer { vp in
                upsample(w, h, f.data.1!, Int(f.linesize.1), up.baseAddress!)
                upsample(w, h, f.data.2!, Int(f.linesize.2), vp.baseAddress!)
                matrix(f, w, h, UnsafePointer(up.baseAddress!), w, UnsafePointer(vp.baseAddress!), w, dst)
            } }
        } else {
            matrix(f, w, h, f.data.1!, Int(f.linesize.1), f.data.2!, Int(f.linesize.2), dst)
        }
    }

    /// One chroma plane at full size: repeated, then `video_chroma_up_h2`, then (unless V
    /// cosited) `video_chroma_up_v2` on lines paired as (2m - 1, 2m) (offset -1); the first
    /// and an unpaired last line only get the horizontal pass.
    private func upsample(_ w: Int, _ h: Int, _ plane: UnsafePointer<UInt8>, _ stride: Int,
                          _ out: UnsafeMutablePointer<UInt8>) {
        let hCosited = hCosited
        for y in 0..<h {
            let s = plane + (y >> 1) &* stride, p = out + y &* w
            for x in 0..<w { p[x] = s[x >> 1] }
            if hCosited {
                var i = 1
                while i < w - 1 {
                    p[i] = UInt8(truncatingIfNeeded: (Int32(p[i - 1]) &+ Int32(p[i + 1]) &+ 1) >> 1)
                    i += 2
                }
            } else {
                var t1 = Int32(p[0])
                var i = 1
                while i < w - 1 {
                    let t0 = t1
                    t1 = Int32(p[i + 1])
                    p[i] = UInt8(truncatingIfNeeded: (3 &* t0 &+ t1 &+ 2) >> 2)
                    p[i + 1] = UInt8(truncatingIfNeeded: (t0 &+ 3 &* t1 &+ 2) >> 2)
                    i += 2
                }
            }
        }
        if vCosited { return }
        var a = 1
        while a + 1 < h {
            let r1 = out + a &* w, r2 = r1 + w
            for x in 0..<w {
                let u1 = Int32(r1[x]), u2 = Int32(r2[x])
                r1[x] = UInt8(truncatingIfNeeded: min((3 &* u1 &+ u2 &+ 2) >> 2, 255))
                r2[x] = UInt8(truncatingIfNeeded: min((u1 &+ 3 &* u2 &+ 2) >> 2, 255))
            }
            a += 2
        }
    }

    private func matrix(_ f: gbm_frame, _ w: Int, _ h: Int, _ up: UnsafePointer<UInt8>, _ us: Int,
                        _ vp: UnsafePointer<UInt8>, _ vs: Int, _ dst: UnsafeMutablePointer<UInt16>) {
        let ys = Int(f.linesize.0), yp = UnsafePointer(f.data.0!)
        terms.withUnsafeBufferPointer { t in
            let t = t.baseAddress!
            @inline(__always) func channel(_ c: Int, _ y: Int, _ u: Int, _ v: Int) -> UInt16 {
                let base = t + c &* 768
                let s = (base[y] &+ base[256 &+ u] &+ base[512 &+ v]) >> 8
                return UInt16(truncatingIfNeeded: min(max(s, 0), 65535))
            }
            for row in 0..<h {
                let yr = yp + row &* ys, ur = up + row &* us, vr = vp + row &* vs
                let o = dst + row &* w &* 4
                for x in 0..<w {
                    let y = Int(yr[x]), u = Int(ur[x]), v = Int(vr[x]), d = o + x &* 4
                    d[0] = 0xFFFF
                    d[1] = channel(0, y, u, v)
                    d[2] = channel(1, y, u, v)
                    d[3] = channel(2, y, u, v)
                }
            }
        }
    }
}

/// Decoded frames as XRGB16 (GStreamer ARGB64) at a target size, the way ntsc-rs-cli's
/// `videoconvert ! videorate ! videoscale` produces them: yuv420p/yuv444p through
/// `GstYUVToARGB64` (bit-exact), other formats as swscale RGB24 widened by replication
/// (videoconvert's 8-bit RGB → ARGB64); then `GstBilinearScaler.scale16` if the size changes.
/// Frame times follow `RGBSource`'s rule.
final class ARGB64Source {
    let decoder: MediaDecoder
    let width: Int, height: Int
    let rate: gbm_rational
    let timeBase: gbm_rational
    let exactTimes: Bool
    private let yuv: GstYUVToARGB64?
    private let subsampled: Bool
    private let resize: GstBilinearScaler?
    /// The frame at the source size; only used when resizing.
    private var native: [UInt16]
    private var count: Int64 = 0

    init(url: URL, width: Int = 0, height: Int = 0) throws {
        let probe = try MediaDecoder(url: url, pixelFormat: "rgb24", threads: Effect.decodeThreads)
        let info = probe.info
        let sw = Int(info.width), sh = Int(info.height)
        let w = width > 0 ? width : sw, h = height > 0 ? height : sh
        self.width = w; self.height = h
        let fmt420 = gbm_pix_fmt("yuv420p"), fmt444 = gbm_pix_fmt("yuv444p")
        if info.pix_fmt == fmt420 || info.pix_fmt == fmt444 {
            subsampled = info.pix_fmt == fmt420
            decoder = try MediaDecoder(url: url, pixelFormat: subsampled ? "yuv420p" : "yuv444p", threads: Effect.decodeThreads)
            // Chroma siting comes from the frames (GBMedia reports none per stream), so take
            // GStreamer's own rule for Matroska: FFV1/ffvhuff/H.264 layers written by the CLIs
            // and ffmpeg carry it in the codec; the probe's colour fields give matrix/range.
            yuv = GstYUVToARGB64(colorSpace: info.color_space, colorRange: info.color_range,
                                 chromaLocation: info.chroma_location, height: sh)
        } else {
            subsampled = false
            decoder = probe
            yuv = nil
        }
        resize = (w, h) == (sw, sh) ? nil
            : GstBilinearScaler(inWidth: sw, inHeight: sh, outWidth: w, outHeight: h, elems: 4)
        native = resize == nil ? [] : [UInt16](repeating: 0, count: sw * sh * 4)
        timeBase = decoder.output.timeBase
        rate = Effect.nominalRate(info.frame_rate)
        var name = info.codec_name
        exactTimes = withUnsafeBytes(of: &name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == "ffvhuff"
    }

    var info: gbm_video_info { decoder.info }

    /// Decodes the next frame into `dst` (width · height · 4 values); returns its time in ns
    /// as the CLI sees it (nil without a timestamp), or nil at the end (`.none`).
    func next(into dst: UnsafeMutablePointer<UInt16>) throws -> Int64?? {
        guard let frame = try decoder.next() else { return .none }
        let k = count
        count += 1
        let ns = exactTimes
            ? Int64(clamping: Int128(k) * Int128(rate.den) * 1_000_000_000 / Int128(rate.num))
            : Effect.timestampNs(frame, timeBase: timeBase)
        let yuv = yuv, subsampled = subsampled
        func load(into d: UnsafeMutablePointer<UInt16>) {
            if let yuv {
                yuv.convert(frame, subsampled: subsampled, into: d)
                return
            }
            let w = Int(frame.width)
            for y in 0..<Int(frame.height) {
                let row = frame.data.0! + y * Int(frame.linesize.0), o = d + y &* w &* 4
                for x in 0..<w {
                    o[x &* 4] = 0xFFFF
                    o[x &* 4 &+ 1] = UInt16(row[x &* 3]) &* 257
                    o[x &* 4 &+ 2] = UInt16(row[x &* 3 &+ 1]) &* 257
                    o[x &* 4 &+ 3] = UInt16(row[x &* 3 &+ 2]) &* 257
                }
            }
        }
        if let resize {
            native.withUnsafeMutableBufferPointer { n in
                load(into: n.baseAddress!)
                resize.scale16(n.baseAddress!, into: dst)
            }
        } else {
            load(into: dst)
        }
        return .some(ns)
    }
}
