import Foundation
import GlitchboxKit
import Synchronization
import Testing
@testable import GlitchboxInProcess

extension InProcessTests {
    @Test func probeThroughRunner() async throws {
        let f = try await Fixture.get()
        let p = try await MediaProbe.probe(f.clip, env: f.env)
        let v = try #require(p.video)
        #expect(v.width == 320 && v.height == 240 && v.pixelFormat == "yuv420p")
        #expect(p.audio?.codec == "aac")
        #expect(abs((p.duration ?? 0) - 2) < 0.1)
    }

    @Test func proxyThroughRunner() async throws {
        let f = try await Fixture.get()
        let (out, _) = try await f.render([LayerSpec(plugin: "rgb-split")])
        let proxy = try await ProxyMaker.proxy(for: out, env: f.env)
        let v = try #require(try await MediaProbe.probe(proxy, env: f.env).video)
        #expect(v.width == 320 && v.height == 240)
    }

    @Test(arguments: [ExportFormat.h264, .gif, .pngSequence])
    func exportThroughRunner(format: ExportFormat) async throws {
        let f = try await Fixture.get()
        let exporter = Exporter(env: f.env, workspace: f.workspace)
        let name = switch format { case .gif: "out.gif"; case .pngSequence: "frames"; default: "out.mp4" }
        let dest = f.dir.appending(path: "export-\(format)").appending(path: name)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings = ExportSettings(format: format, audio: format.hasAudio ? .source : .none)
        try await exporter.export(source: f.clip, layers: [LayerSpec(plugin: "block-glitch")], render: RenderSettings(),
                                  settings: settings, to: dest, events: { _ in })
        switch format {
        case .pngSequence:
            let frames = try FileManager.default.contentsOfDirectory(atPath: dest.path).filter { $0.hasSuffix(".png") }
            #expect(frames.count == 60)
        case .gif:
            let p = try await MediaProbe.probe(dest, env: f.env)
            #expect(p.video != nil)
        default:
            let p = try await MediaProbe.probe(dest, env: f.env)
            #expect(p.video?.width == 320)
            #expect(p.audio != nil, "h264 export lost the source audio")
        }
        let still = f.dir.appending(path: "export-\(format)/frame.png")
        let (out, _) = try await f.render([LayerSpec(plugin: "block-glitch")])
        try await exporter.exportFrame(of: out.output, at: 1, sourceTags: ColorTags.resolve(#require(
            try await MediaProbe.probe(f.clip, env: f.env).video)), to: still)
        #expect(FileManager.default.fileExists(atPath: still.path))
    }

    /// Cancels a render once `plugin`'s step is running; it must stop promptly, throw
    /// `CancellationError`, and leave no partial layer behind.
    func cancelMidStep(plugin: String, params: [String: ParamValue] = [:]) async throws {
        let f = try await Fixture.get()
        let started = Mutex<ContinuousClock.Instant?>(nil)
        let task = Task {
            try await f.render([LayerSpec(plugin: plugin, params: params)], source: f.longClip) { event in
                if case .step(let index, _, _, _, _) = event, index >= 0 {
                    started.withLock { $0 = $0 ?? .now }
                }
            }
        }
        while started.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        let cancelled = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let elapsed = ContinuousClock.now - cancelled
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(elapsed < .seconds(3), "\(plugin) took \(elapsed) to stop")
        #expect(try f.leftovers().isEmpty)
    }

    @Test func cancelNativeStep() async throws {
        try await cancelMidStep(plugin: "mpeg2-mosh", params: ["gop": .int(0)])
    }

    @Test func cancelFileNativeStep() async throws {
        try await cancelMidStep(plugin: "mv-mangle", params: ["seed": .int(7)])
    }

    @Test func cancelFFmpegStep() async throws {
        try await cancelMidStep(plugin: "plasma-distort")
    }

    /// An export (probe + encode) running beside a render completes, waiting its turn for the
    /// serialized ffmpeg where it must.
    @Test func probeAndExportBesideRender() async throws {
        let f = try await Fixture.get()
        let (ready, _) = try await f.render([LayerSpec(plugin: "rgb-split")])
        async let render = f.render([LayerSpec(plugin: "mpeg2-mosh", params: ["tail": .int(4)])], source: f.longClip)
        async let probe = MediaProbe.probe(f.longClip, env: f.env)
        let dest = f.dir.appending(path: "concurrent.mp4")
        let tags = ColorTags.resolve(try #require(try await MediaProbe.probe(f.clip, env: f.env).video))
        async let export = Exporter(env: f.env, workspace: f.workspace)
            .encode(input: ready.output, sourceTags: tags, audio: nil, settings: ExportSettings(audio: .none),
                    to: dest, progress: { _ in })
        let (r, p, e) = try await (render, probe, export)
        #expect(p.video?.width == 1280)
        #expect(FileManager.default.fileExists(atPath: e.path))
        #expect(try Fixture.shape(r.output.output).frames == 600)
    }
}
