import Foundation
import GlitchboxKit
import Testing
@testable import GlitchboxInProcess

/// In-process renders against the macOS CLI with its spawned, prebuilt toolchain.
extension InProcessTests {
    @Test func runnerOffersOnlyLibraryTools() {
        let r = InProcessRunner()
        for tool in ["ffmpeg", "ffprobe", "ffgac", "ffedit"] { #expect(r.has(tool)) }
        for tool in ["bash", "jq", "sox", "mv-mangle", "ntsc-rs-cli", "/usr/bin/ffmpeg"] { #expect(!r.has(tool)) }
        for id in ["mpeg2-mosh", "mv-script", "mv-mangle"] { #expect(r.native(id) != nil) }
    }

    @Test func sourcePrepAndAudioMatchMacOS() async throws {
        let f = try await Fixture.get()
        let (out, audio) = try await f.render([])
        let mac = try f.renderOnMac([], name: "source")
        #expect(try Data(contentsOf: out.output) == Data(contentsOf: mac.output), "source out.mkv differs")
        let audioURL = try #require(audio, "no source audio extracted")
        let macAudio = try Fixture.sourceLayer(in: mac.cache).appending(path: SourcePrep.audioFileName)
        #expect(try Data(contentsOf: audioURL) == Data(contentsOf: macAudio), "audio.wav differs")
    }

    @Test(arguments: ["rgb-split", "mv-mangle"])
    func deterministicPluginMatchesMacOS(plugin: String) async throws {
        let f = try await Fixture.get()
        let layers = [LayerSpec(plugin: plugin)]
        let (out, _) = try await f.render(layers)
        let mac = try f.renderOnMac(layers, name: plugin)
        let mine = try Data(contentsOf: out.output), theirs = try Data(contentsOf: mac.output)
        #expect(mine.count > 0)
        #expect(mine == theirs, "\(plugin): \(mine.count) bytes in-process vs \(theirs.count) on macOS")
    }

    /// MPEG-2 decode diverges between runs past ~frame 17 even on macOS, and frei0r glitch0r
    /// draws from an unseeded PRNG (two macOS runs differ), so these are compared by shape.
    @Test(arguments: [("mpeg2-mosh", [String: ParamValue]()),
                      ("mv-script", ["script": .string("dd_gravity.js"), "amount": .int(3)]),
                      ("block-glitch", [:])])
    func nondeterministicPluginMatchesMacOSShape(plugin: String, params: [String: ParamValue]) async throws {
        let f = try await Fixture.get()
        let layers = [LayerSpec(plugin: plugin, params: params)]
        let (out, _) = try await f.render(layers)
        let mac = try f.renderOnMac(layers, name: plugin)
        let mine = try Fixture.shape(out.output), theirs = try Fixture.shape(mac.output)
        #expect(mine.frames == 60)
        #expect(mine.frames == theirs.frames)
        #expect(mine.width == theirs.width && mine.height == theirs.height)
        #expect(mine.pixelFormat == theirs.pixelFormat)
    }

    @Test func failingChainStageFailsTheStep() async throws {
        let f = try await Fixture.get()
        // A script that does not exist: ffedit fails, which must stop ffgac and ffmpeg too.
        let (source, _) = try await f.render([])
        let work = f.dir.appending(path: "bad-chain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let log = work.appending(path: "log.txt")
        let context = NativeStepContext(
            plugin: "mv-script", step: "mosh", input: source.output, output: work.appending(path: "out.mkv"),
            work: work, root: Fixture.repo,
            params: ["script": .string("no-such-script.js"), "amount": .int(0), "qscale": .int(0), "gop": .int(0)],
            paramsFile: work.appending(path: "params.json"), sourceAudio: nil, log: log,
            environment: f.env.variables)
        let started = ContinuousClock.now
        let code = try await #require(InProcessRunner().native("mv-script")).run(context)
        #expect(code != 0)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(Fixture.log(log).contains("no-such-script.js"))
    }

    @Test func chainedLayersRenderInProcess() async throws {
        let f = try await Fixture.get()
        let (out, _) = try await f.render([LayerSpec(plugin: "rgb-split"), LayerSpec(plugin: "mv-mangle"),
                                           LayerSpec(plugin: "mpeg2-mosh")])
        let shape = try Fixture.shape(out.output)
        #expect(shape.frames == 60 && shape.width == 320 && shape.height == 240)
    }
}
