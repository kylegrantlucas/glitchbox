import Foundation
import GBMedia
@testable import GlitchboxInProcess

// The original (pre-optimisation) GStreamer-equivalent conversions, kept verbatim as the
// golden reference the optimised implementations must match bit for bit.

struct RefI420ToRGB {
    let g: GstI420ToRGB
    func convert(_ f: gbm_frame, into dst: UnsafeMutablePointer<UInt8>, stride: Int, bytesPerPixel: Int) {
        let w = Int(f.width), h = Int(f.height)
        let ys = Int(f.linesize.0), us = Int(f.linesize.1), vs = Int(f.linesize.2)
        let p1 = g.p1, p2 = g.p2, p3 = g.p3, p4 = g.p4, p5 = g.p5
        @inline(__always) func splat(_ v: UInt8) -> Int32 {
            let r = v &- 128
            return Int32(Int16(bitPattern: UInt16(r) << 8 | UInt16(r)))
        }
        @inline(__always) func mulhs(_ a: Int32, _ p: Int32) -> Int32 { (a * Int32(Int16(truncatingIfNeeded: p))) >> 16 }
        @inline(__always) func wrap(_ v: Int32) -> Int32 { Int32(Int16(truncatingIfNeeded: v)) }
        @inline(__always) func sat(_ v: Int32) -> UInt8 { UInt8(min(max(v, -128), 127) + 128) }
        for y in 0..<h {
            let yr = f.data.0! + y * ys, ur = f.data.1! + (y >> 1) * us, vr = f.data.2! + (y >> 1) * vs
            let out = dst + y * stride
            for x in 0..<w {
                let wy = mulhs(splat(yr[x]), p1)
                let wu = splat(ur[x >> 1]), wv = splat(vr[x >> 1])
                let r = sat(wrap(wy + mulhs(wv, p2)))
                let b = sat(wrap(wy + mulhs(wu, p3)))
                let g = sat(wrap(wrap(wy + mulhs(wu, p4)) + mulhs(wv, p5)))
                let o = out + x * bytesPerPixel
                o[0] = r; o[1] = g; o[2] = b
                if bytesPerPixel == 4 { o[3] = 255 }
            }
        }
    }
}

struct RefBilinearScaler {
    let inWidth: Int, inHeight: Int, outWidth: Int, outHeight: Int, elems: Int

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

    /// Scales `src` (inWidth × inHeight, packed, `elems` bytes per pixel) into `dst`.
    func scale(_ src: [UInt8], into dst: inout [UInt8]) {
        var current = src, w = inWidth, h = inHeight
        func hscale() {
            current = horizontal(current, width: w, height: h); w = outWidth
        }
        func vscale() {
            current = vertical(current, width: w, height: h); h = outHeight
        }
        // gst_video_scaler_2d: horizontal first when out_w · voffset[out_h - 1] <= out_w · out_h.
        let vOffsetLast = Resampler(inSize: inHeight, outSize: outHeight).offset[outHeight - 1]
        if inHeight == outHeight || outWidth * vOffsetLast <= outWidth * outHeight {
            if w != outWidth { hscale() }
            if h != outHeight { vscale() }
        } else {
            if h != outHeight { vscale() }
            if w != outWidth { hscale() }
        }
        dst = current
    }

    private func horizontal(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
        let r = Resampler(inSize: width, outSize: outWidth)
        var out = [UInt8](repeating: 0, count: outWidth * height * elems)
        if r.maxTaps == 2 && elems == 4 {
            // video_scale_h_2tap_4u8: ldreslinl stepping by inc = ((in - 1) << 16) / (out - 1) - 1.
            let inc = outWidth == 1 ? 0 : ((width - 1) << 16) / (outWidth - 1) - 1
            for y in 0..<height {
                let s = y * width * 4, d = y * outWidth * 4
                for i in 0..<outWidth {
                    let tmp = i * inc, a = s + (tmp >> 16) * 4, frac = (tmp >> 8) & 0xff
                    let b = (tmp >> 16) + 1 < width ? a + 4 : a
                    for c in 0..<4 {
                        out[d + i * 4 + c] = UInt8((Int(src[a + c]) * (256 - frac) + Int(src[b + c]) * frac) >> 8)
                    }
                }
            }
            return out
        }
        if r.maxTaps == 1 {
            for y in 0..<height {
                for i in 0..<outWidth {
                    for c in 0..<elems { out[(y * outWidth + i) * elems + c] = src[(y * width + r.offset[i]) * elems + c] }
                }
            }
            return out
        }
        // video_scale_h_ntap_u8 (2 taps): h_2tap_u8_lq, 6-bit taps.
        let taps = r.intTaps(precision: 6)
        for y in 0..<height {
            for i in 0..<outWidth {
                let t = taps[i], o = r.offset[i]
                for c in 0..<elems {
                    var acc: Int32 = 0
                    for l in 0..<r.maxTaps {
                        acc = Int32(Int16(truncatingIfNeeded: acc + Int32(src[(y * width + o + l) * elems + c]) * t[l]))
                    }
                    out[(y * outWidth + i) * elems + c] = Self.lq(acc)
                }
            }
        }
        return out
    }

    private func vertical(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
        let r = Resampler(inSize: height, outSize: outHeight)
        let row = width * elems
        var out = [UInt8](repeating: 0, count: row * outHeight)
        if r.maxTaps == 1 {
            for j in 0..<outHeight { out.replaceSubrange(j * row..<(j + 1) * row, with: src[r.offset[j] * row..<(r.offset[j] + 1) * row]) }
            return out
        }
        // video_scale_v_2tap_u8 (LQ): 8-bit taps; d = s1 + hi8((s2 - s1) · p1 + 128).
        let taps = r.intTaps(precision: 8)
        for j in 0..<outHeight {
            let p1 = Int32(Int16(truncatingIfNeeded: taps[j][1]))
            let s1 = r.offset[j] * row, s2 = min(r.offset[j] + 1, height - 1) * row
            for k in 0..<row {
                let a = Int32(src[s1 + k]), b = Int32(src[s2 + k])
                let w = Int16(truncatingIfNeeded: (b - a) * p1 + 128)
                let hi = UInt8(truncatingIfNeeded: Int32(w) >> 8)
                out[j * row + k] = hi &+ UInt8(a)
            }
        }
        return out
    }

    /// `(acc + 32) >> 6` saturated to u8, in 16-bit arithmetic.
    private static func lq(_ acc: Int32) -> UInt8 {
        let w = Int32(Int16(truncatingIfNeeded: acc + 32)) >> 6
        return UInt8(min(max(w, 0), 255))
    }
}

struct RefYUVToARGB64 {
    let im: [[Int64]]
    let hCosited: Bool, vCosited: Bool

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
        im = m.d.map { $0.map { Int64($0.rounded(.toNearestOrEven)) } }
        hCosited = chromaLocation == 1 || chromaLocation == 3
        vCosited = chromaLocation == 3
    }

    /// Converts a yuv420p (`subsampled`) or yuv444p frame into XRGB16 (X = 0xFFFF).
    func convert(_ f: gbm_frame, subsampled: Bool, into dst: inout [UInt16]) {
        let w = Int(f.width), h = Int(f.height)
        // AYUV lines: [A, Y, U, V] per pixel.
        var lines = [[UInt8]](repeating: [], count: h)
        for y in 0..<h {
            var line = [UInt8](repeating: 255, count: w * 4)
            let yr = f.data.0! + y * Int(f.linesize.0)
            let cy = subsampled ? y >> 1 : y
            let ur = f.data.1! + cy * Int(f.linesize.1), vr = f.data.2! + cy * Int(f.linesize.2)
            for x in 0..<w {
                let cx = subsampled ? x >> 1 : x
                line[x * 4 + 1] = yr[x]; line[x * 4 + 2] = ur[cx]; line[x * 4 + 3] = vr[cx]
            }
            lines[y] = line
        }
        if subsampled {
            func hUp(_ p: inout [UInt8]) {
                if hCosited {
                    var i = 1
                    while i < w - 1 {
                        for k in 2...3 { p[4 * i + k] = UInt8((Int(p[4 * (i - 1) + k]) + Int(p[4 * (i + 1) + k]) + 1) >> 1) }
                        i += 2
                    }
                } else {
                    var t1 = (Int(p[2]), Int(p[3]))
                    var i = 1
                    while i < w - 1 {
                        let t0 = t1
                        t1 = (Int(p[4 * (i + 1) + 2]), Int(p[4 * (i + 1) + 3]))
                        p[4 * i + 2] = UInt8((3 * t0.0 + t1.0 + 2) >> 2)
                        p[4 * i + 3] = UInt8((3 * t0.1 + t1.1 + 2) >> 2)
                        p[4 * (i + 1) + 2] = UInt8((t0.0 + 3 * t1.0 + 2) >> 2)
                        p[4 * (i + 1) + 3] = UInt8((t0.1 + 3 * t1.1 + 2) >> 2)
                        i += 2
                    }
                }
            }
            if vCosited {
                for y in 0..<h { hUp(&lines[y]) }
            } else {
                // Lines pair as (2m - 1, 2m) (up_v2 offset -1); the first and an unpaired last
                // line only get the horizontal pass.
                hUp(&lines[0])
                var a = 1
                while a + 1 < h {
                    hUp(&lines[a]); hUp(&lines[a + 1])
                    for x in 0..<w {
                        for k in 2...3 {
                            let u1 = Int(lines[a][4 * x + k]), u2 = Int(lines[a + 1][4 * x + k])
                            lines[a][4 * x + k] = UInt8(min((3 * u1 + u2 + 2) >> 2, 255))
                            lines[a + 1][4 * x + k] = UInt8(min((u1 + 3 * u2 + 2) >> 2, 255))
                        }
                    }
                    a += 2
                }
                if a < h { hUp(&lines[a]) }
            }
        }
        let m = im
        for y in 0..<h {
            let line = lines[y]
            for x in 0..<w {
                let yy = Int64(line[x * 4 + 1]) * 257, u = Int64(line[x * 4 + 2]) * 257, v = Int64(line[x * 4 + 3]) * 257
                let o = (y * w + x) * 4
                dst[o] = 0xFFFF
                for c in 0..<3 {
                    let t = (m[c][0] * yy + m[c][1] * u + m[c][2] * v + m[c][3]) >> 8
                    dst[o + 1 + c] = UInt16(min(max(t, 0), 65535))
                }
            }
        }
    }
}

extension RefBilinearScaler {
    /// The same scale on ARGB64 (`elems` 4, uint16): `video_scale_h_ntap_u16`
    /// (`resample_h_2tap_u16`) and `video_scale_v_2tap_u16`, 12-bit taps.
    func scale16(_ src: [UInt16], into dst: inout [UInt16]) {
        var current = src, w = inWidth, h = inHeight
        let vOffsetLast = Resampler(inSize: inHeight, outSize: outHeight).offset[outHeight - 1]
        func hscale() { current = horizontal16(current, width: w, height: h); w = outWidth }
        func vscale() { current = vertical16(current, width: w, height: h); h = outHeight }
        if inHeight == outHeight || outWidth * vOffsetLast <= outWidth * outHeight {
            if w != outWidth { hscale() }
            if h != outHeight { vscale() }
        } else {
            if h != outHeight { vscale() }
            if w != outWidth { hscale() }
        }
        dst = current
    }

    private static func sat16(_ v: Int64) -> UInt16 { UInt16(min(max(v, 0), 65535)) }

    private func horizontal16(_ src: [UInt16], width: Int, height: Int) -> [UInt16] {
        let r = Resampler(inSize: width, outSize: outWidth)
        let taps = r.intTaps(precision: 12)
        var out = [UInt16](repeating: 0, count: outWidth * height * 4)
        for y in 0..<height {
            for i in 0..<outWidth {
                let o = r.offset[i]
                for c in 0..<4 {
                    if r.maxTaps == 1 {
                        out[(y * outWidth + i) * 4 + c] = src[(y * width + o) * 4 + c]
                        continue
                    }
                    var acc: Int64 = 0
                    for l in 0..<r.maxTaps {
                        acc += Int64(src[(y * width + o + l) * 4 + c]) * Int64(taps[i][l])
                    }
                    let v = Int64(Int32(truncatingIfNeeded: acc + 4096)) >> 12
                    out[(y * outWidth + i) * 4 + c] = Self.sat16(v)
                }
            }
        }
        return out
    }

    private func vertical16(_ src: [UInt16], width: Int, height: Int) -> [UInt16] {
        let r = Resampler(inSize: height, outSize: outHeight)
        let row = width * 4
        var out = [UInt16](repeating: 0, count: row * outHeight)
        if r.maxTaps == 1 {
            for j in 0..<outHeight { out.replaceSubrange(j * row..<(j + 1) * row, with: src[r.offset[j] * row..<(r.offset[j] + 1) * row]) }
            return out
        }
        let taps = r.intTaps(precision: 12)
        for j in 0..<outHeight {
            let p1 = Int64(UInt16(truncatingIfNeeded: taps[j][1]))  // convuwl: zero-extended
            let s1 = r.offset[j] * row, s2 = min(r.offset[j] + 1, height - 1) * row
            for k in 0..<row {
                let a = Int64(src[s1 + k]), b = Int64(src[s2 + k])
                let d = Int64(Int32(truncatingIfNeeded: (b - a) * p1 + 4096)) >> 12
                out[j * row + k] = Self.sat16(a + d)
            }
        }
        return out
    }
}
