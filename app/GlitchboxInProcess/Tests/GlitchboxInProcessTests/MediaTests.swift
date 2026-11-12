import Foundation
import GBMedia
import GlitchboxKit
import Testing
@testable import GlitchboxInProcess

/// GBMedia: what native steps build on (decode → effect → encode).
extension InProcessTests {
    @Test(arguments: [GBM_CODEC_FFV1, GBM_CODEC_FFVHUFF])
    func decodeEncodeRoundTripIsLossless(codec: gbm_codec) async throws {
        let f = try await Fixture.get()
        let (source, _) = try await f.render([])
        let dec = try MediaDecoder(url: source.output, pixelFormat: "bgra")
        let info = dec.info
        #expect(info.width == 320 && info.height == 240)
        #expect(info.frame_rate.num == 30 && info.frame_rate.den == 1)
        let out = f.dir.appending(path: "roundtrip-\(codec.rawValue).mkv")
        var config = gbm_encoder_config()
        config.codec = Int32(codec.rawValue)
        config.width = 320; config.height = 240
        config.pix_fmt = gbm_pix_fmt("bgra")
        config.frame_rate = info.frame_rate
        config.color_space = info.color_space; config.color_range = info.color_range
        config.color_primaries = info.color_primaries; config.color_trc = info.color_trc
        var originals: [[UInt8]] = []
        do {
            let enc = try MediaEncoder(url: out, config: config)
            while let frame = try dec.next() {
                originals.append(Array(UnsafeBufferPointer(start: frame.data.0, count: Int(frame.linesize.0) * 240)))
                try enc.write(frame, index: frame.index)
            }
            try enc.finish()
        }
        #expect(originals.count == 60)

        let back = try MediaDecoder(url: out, pixelFormat: "bgra")
        var i = 0
        while let frame = try back.next() {
            let bytes = Array(UnsafeBufferPointer(start: frame.data.0, count: Int(frame.linesize.0) * 240))
            #expect(bytes == originals[i], "frame \(i) changed")
            #expect(frame.index == Int64(i))
            i += 1
        }
        #expect(i == 60)
        let p = try #require(try await MediaProbe.probe(out, env: f.env).video)
        #expect(p.frameRate == 30)

        // Bit-exact container: the same frames give the same bytes.
        let again = f.dir.appending(path: "roundtrip-\(codec.rawValue)-again.mkv")
        let dec2 = try MediaDecoder(url: source.output, pixelFormat: "bgra")
        let enc2 = try MediaEncoder(url: again, config: config)
        while let frame = try dec2.next() { try enc2.write(frame, index: frame.index) }
        try enc2.finish()
        #expect(try Data(contentsOf: out) == Data(contentsOf: again))
    }

    @Test func decoderScalesAndFilters() async throws {
        let f = try await Fixture.get()
        let dec = try MediaDecoder(url: f.clip, width: 160, height: 120, pixelFormat: "rgb48le",
                                   scaleFlags: "lanczos+accurate_rnd", filters: "fps=15")
        let out = dec.output
        #expect(out.width == 160 && out.height == 120 && out.pixelFormat == gbm_pix_fmt("rgb48le"))
        var n = 0
        while try dec.next() != nil { n += 1 }
        #expect(n == 30)
    }

    @Test func audioDecodesToMono() async throws {
        let f = try await Fixture.get()
        let samples = try MediaAudio.decodeMono(url: f.clip, sampleRate: 44100)
        #expect(abs(samples.count - 88200) < 2048)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.05 && peak <= 1.0)
        #expect(throws: MediaError.self) { try MediaAudio.decodeMono(url: f.dir.appending(path: "missing.wav"), sampleRate: 8000) }
    }
}
