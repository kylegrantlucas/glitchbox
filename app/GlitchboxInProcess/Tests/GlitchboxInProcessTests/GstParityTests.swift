import Foundation
import GBMedia
import Testing
@testable import GlitchboxInProcess

/// The optimised GStreamer-equivalent conversions against the original implementations
/// (`GstReference.swift`), bit for bit, over odd sizes, every chroma siting, matrices and
/// ranges, and up/down/one-axis scales in 8 and 16 bits.
struct GstParityTests {
    /// Deterministic pseudo-random bytes (xorshift).
    static func bytes(_ n: Int, seed: UInt64) -> [UInt8] {
        var s = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<n).map { _ in
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return UInt8(truncatingIfNeeded: s >> 24)
        }
    }

    /// A planar YUV frame with padded strides (plus extreme values in the first row).
    final class Planes {
        var y: [UInt8], u: [UInt8], v: [UInt8]
        let w: Int, h: Int, ys: Int, cs: Int, ch: Int

        init(w: Int, h: Int, subsampled: Bool, seed: UInt64) {
            self.w = w; self.h = h
            ys = w + 7
            let cw = subsampled ? (w + 1) / 2 : w
            ch = subsampled ? (h + 1) / 2 : h
            cs = cw + 5
            y = GstParityTests.bytes(ys * h, seed: seed)
            u = GstParityTests.bytes(cs * ch, seed: seed + 1)
            v = GstParityTests.bytes(cs * ch, seed: seed + 2)
            for (i, b) in ([0, 255, 16, 235, 128, 1, 254] as [UInt8]).enumerated() where i < w { y[i] = b; u[i % cw] = 255 - b; v[i % cw] = b }
        }

        func with<R>(_ body: (gbm_frame) -> R) -> R {
            y.withUnsafeMutableBufferPointer { yp in u.withUnsafeMutableBufferPointer { up in v.withUnsafeMutableBufferPointer { vp in
                var f = gbm_frame()
                f.data = (yp.baseAddress, up.baseAddress, vp.baseAddress, nil)
                f.linesize = (Int32(ys), Int32(cs), Int32(cs), 0)
                f.width = Int32(w); f.height = Int32(h)
                return body(f)
            } } }
        }
    }

    static let sizes = [(1, 1), (2, 2), (3, 5), (7, 3), (33, 17), (64, 48), (321, 241)]

    @Test func i420ToRGB() {
        var n = 0
        for (w, h) in Self.sizes {
            let p = Planes(w: w, h: h, subsampled: true, seed: UInt64(w * 1000 + h))
            for (space, range) in [(1, 1), (5, 2), (2, 1), (9, 2), (7, 1), (4, 2)] {
                let g = GstI420ToRGB(colorSpace: Int32(space), colorRange: Int32(range), height: h)
                let ref = RefI420ToRGB(g: g)
                for bpp in [3, 4] {
                    let stride = w * bpp + 3
                    var a = [UInt8](repeating: 7, count: stride * h), b = a
                    p.with { f in
                        a.withUnsafeMutableBufferPointer { ref.convert(f, into: $0.baseAddress!, stride: stride, bytesPerPixel: bpp) }
                        b.withUnsafeMutableBufferPointer { g.convert(f, into: $0.baseAddress!, stride: stride, bytesPerPixel: bpp) }
                    }
                    #expect(a == b, "I420→RGB \(w)x\(h) space \(space) range \(range) bpp \(bpp)")
                    n += 1
                }
            }
        }
        #expect(n == Self.sizes.count * 12)
    }

    @Test func yuvToARGB64() {
        for (w, h) in Self.sizes {
            for subsampled in [true, false] {
                let p = Planes(w: w, h: h, subsampled: subsampled, seed: UInt64(w * 31 + h))
                for (space, range) in [(1, 1), (5, 2), (2, 1), (9, 1)] {
                    for loc in Int32(0)...5 {
                        let ref = RefYUVToARGB64(colorSpace: Int32(space), colorRange: Int32(range), chromaLocation: loc, height: h)
                        let new = GstYUVToARGB64(colorSpace: Int32(space), colorRange: Int32(range), chromaLocation: loc, height: h)
                        var a = [UInt16](repeating: 0, count: w * h * 4), b = a
                        p.with { f in
                            ref.convert(f, subsampled: subsampled, into: &a)
                            b.withUnsafeMutableBufferPointer { new.convert(f, subsampled: subsampled, into: $0.baseAddress!) }
                            // Twice through the reused scratch planes.
                            b.withUnsafeMutableBufferPointer { new.convert(f, subsampled: subsampled, into: $0.baseAddress!) }
                        }
                        #expect(a == b, "YUV→ARGB64 \(w)x\(h) 420 \(subsampled) space \(space) range \(range) loc \(loc)")
                    }
                }
            }
        }
    }

    static let scales: [(Int, Int, Int, Int)] = [
        (320, 240, 160, 120), (320, 240, 640, 480), (321, 241, 100, 77), (33, 17, 64, 9), (64, 48, 64, 31),
        (64, 48, 17, 48), (7, 3, 1, 1), (1, 1, 5, 4), (1, 9, 3, 9), (9, 1, 9, 6), (2, 2, 3, 3), (720, 480, 352, 240),
        (100, 30, 333, 31), (640, 360, 641, 359),
    ]

    @Test func bilinear8() {
        for (iw, ih, ow, oh) in Self.scales {
            for elems in [3, 4] {
                let src = Self.bytes(iw * ih * elems, seed: UInt64(iw * 7 + ih + elems))
                var a: [UInt8] = []
                RefBilinearScaler(inWidth: iw, inHeight: ih, outWidth: ow, outHeight: oh, elems: elems).scale(src, into: &a)
                let s = GstBilinearScaler(inWidth: iw, inHeight: ih, outWidth: ow, outHeight: oh, elems: elems)
                var b = [UInt8](repeating: 0, count: ow * oh * elems)
                for _ in 0..<2 {
                    src.withUnsafeBufferPointer { sp in b.withUnsafeMutableBufferPointer { s.scale(sp.baseAddress!, into: $0.baseAddress!) } }
                }
                #expect(a == b, "u8 \(iw)x\(ih)→\(ow)x\(oh) elems \(elems)")
            }
        }
    }

    @Test func bilinear16() {
        for (iw, ih, ow, oh) in Self.scales {
            let bytes = Self.bytes(iw * ih * 8, seed: UInt64(iw * 13 + ih))
            var src = (0..<(iw * ih * 4)).map { UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]) }
            for i in 0..<min(src.count, 8) { src[i] = i.isMultiple(of: 2) ? 0xFFFF : 0 }
            var a: [UInt16] = []
            RefBilinearScaler(inWidth: iw, inHeight: ih, outWidth: ow, outHeight: oh, elems: 4).scale16(src, into: &a)
            let s = GstBilinearScaler(inWidth: iw, inHeight: ih, outWidth: ow, outHeight: oh, elems: 4)
            var b = [UInt16](repeating: 0, count: ow * oh * 4)
            for _ in 0..<2 {
                src.withUnsafeBufferPointer { sp in b.withUnsafeMutableBufferPointer { s.scale16(sp.baseAddress!, into: $0.baseAddress!) } }
            }
            #expect(a == b, "u16 \(iw)x\(ih)→\(ow)x\(oh)")
        }
    }

    /// Per-frame times of the reference and optimised paths at 1080p (set GB_GST_TIMING=1;
    /// meaningful in release: `swift test -c release -Xswiftc -enable-testing`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GB_GST_TIMING"] != nil))
    func timing() {
        let w = 1920, h = 1080, frames = 20
        func ms(_ body: () -> Void) -> Double {
            body()
            let t0 = ContinuousClock.now
            for _ in 0..<frames { body() }
            let d = (ContinuousClock.now - t0).components
            return (Double(d.seconds) * 1e3 + Double(d.attoseconds) / 1e15) / Double(frames)
        }
        let p = Planes(w: w, h: h, subsampled: true, seed: 1)
        let g = GstI420ToRGB(colorSpace: 1, colorRange: 1, height: h), rg = RefI420ToRGB(g: g)
        var rgb = [UInt8](repeating: 0, count: w * h * 4)
        let i420Ref = ms { p.with { f in rgb.withUnsafeMutableBufferPointer { rg.convert(f, into: $0.baseAddress!, stride: w * 4, bytesPerPixel: 4) } } }
        let i420New = ms { p.with { f in rgb.withUnsafeMutableBufferPointer { g.convert(f, into: $0.baseAddress!, stride: w * 4, bytesPerPixel: 4) } } }
        let ry = RefYUVToARGB64(colorSpace: 1, colorRange: 1, chromaLocation: 1, height: h)
        let ny = GstYUVToARGB64(colorSpace: 1, colorRange: 1, chromaLocation: 1, height: h)
        var argb = [UInt16](repeating: 0, count: w * h * 4)
        let yuvRef = ms { p.with { f in ry.convert(f, subsampled: true, into: &argb) } }
        let yuvNew = ms { p.with { f in argb.withUnsafeMutableBufferPointer { ny.convert(f, subsampled: true, into: $0.baseAddress!) } } }
        let (ow, oh) = (1280, 720)
        let rs = RefBilinearScaler(inWidth: w, inHeight: h, outWidth: ow, outHeight: oh, elems: 4)
        let ns = GstBilinearScaler(inWidth: w, inHeight: h, outWidth: ow, outHeight: oh, elems: 4)
        var o8 = [UInt8](repeating: 0, count: ow * oh * 4), o16 = [UInt16](repeating: 0, count: ow * oh * 4)
        let s8Ref = ms { rs.scale(rgb, into: &o8) }
        let s8New = ms { rgb.withUnsafeBufferPointer { s in o8.withUnsafeMutableBufferPointer { ns.scale(s.baseAddress!, into: $0.baseAddress!) } } }
        let s16Ref = ms { rs.scale16(argb, into: &o16) }
        let s16New = ms { argb.withUnsafeBufferPointer { s in o16.withUnsafeMutableBufferPointer { ns.scale16(s.baseAddress!, into: $0.baseAddress!) } } }
        print(String(format: """
            gst timing ms/frame (1920x1080, ref → new):
              I420→RGBA        %.2f → %.2f
              YUV420→ARGB64    %.2f → %.2f
              scale u8 →720p   %.2f → %.2f
              scale u16 →720p  %.2f → %.2f
            """, i420Ref, i420New, yuvRef, yuvNew, s8Ref, s8New, s16Ref, s16New))
    }
}
