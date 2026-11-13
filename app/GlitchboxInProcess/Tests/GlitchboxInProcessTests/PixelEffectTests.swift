import Foundation
import GBMedia
import GlitchboxKit
import Testing
@testable import GlitchboxInProcess

/// The five frei0r plugins' native steps (GlitchboxFX pixel effects) over the fixture clip's
/// source layer, with the plugins' default params: one ffvhuff yuv420p frame per input frame,
/// the input's size and colour tags, and a visible effect.
extension InProcessTests {
    @Test(arguments: ["block-glitch", "row-shift", "plasma-distort", "kaleidoscope", "vertigo"])
    func pixelEffectKeepsTheInputsShapeAndTags(plugin: String) async throws {
        let f = try await Fixture.get()
        let (source, _) = try await f.render([])
        let manifest = try f.workspace.builtinPlugin(id: plugin)
        let params = f.workspace.resolveParams([:], for: manifest).values

        let work = f.dir.appending(path: "pixel-\(plugin)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let paramsFile = work.appending(path: "params.json")
        try CanonicalJSON.data(params).write(to: paramsFile)
        let out = work.appending(path: "out.mkv"), log = work.appending(path: "log.txt")
        let context = NativeStepContext(
            plugin: plugin, step: "filter", input: source.output, output: out, work: work, root: Fixture.repo,
            params: params, paramsFile: paramsFile, sourceAudio: nil, log: log, environment: f.env.variables)

        let code = try await #require(InProcessRunner().native(plugin)).run(context)
        try #require(code == 0, "\(plugin): \(Fixture.log(log))")

        let input = try Fixture.shape(source.output), output = try Fixture.shape(out)
        #expect(output.frames == input.frames && output.frames > 0)
        #expect(output.width == input.width && output.height == input.height)
        #expect(output.pixelFormat == gbm_pix_fmt("yuv420p"))

        let a = try MediaDecoder(url: source.output, pixelFormat: "rgba").info
        let b = try MediaDecoder(url: out, pixelFormat: "rgba").info
        var name = b.codec_name
        #expect(withUnsafeBytes(of: &name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == "ffvhuff")
        #expect(b.color_space == a.color_space && b.color_range == a.color_range)
        #expect(b.color_primaries == a.color_primaries && b.color_trc == a.color_trc)
        #expect(b.chroma_location == a.chroma_location)
        #expect(a.color_space != 2, "the source layer should carry explicit tags")
        // A no-op would still differ by the RGB → yuv420p round trip (about one level), so
        // ask for at least one frame that changed far more than that.
        let mine = try Self.frames(out), theirs = try Self.frames(source.output)
        let change = zip(mine, theirs).map { a, b in
            Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        }.max() ?? 0
        #expect(change > 5, "\(plugin): largest mean frame change \(change) levels")
    }

    /// Every decoded RGBA frame, packed.
    static func frames(_ url: URL) throws -> [Data] {
        let d = try MediaDecoder(url: url, pixelFormat: "rgba")
        var frames: [Data] = []
        while let frame = try d.next() {
            let row = Int(frame.width) * 4, stride = Int(frame.linesize.0)
            var data = Data(capacity: row * Int(frame.height))
            for y in 0..<Int(frame.height) {
                data.append(frame.data.0! + y * stride, count: row)
            }
            frames.append(data)
        }
        return frames
    }
}
