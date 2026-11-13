import Foundation
import GlitchboxKit
import Testing
@testable import GlitchboxInProcess

/// The Rust-backed native steps against the macOS CLIs they replace, run through the plugin
/// scripts' and pipelines' exact flags: ntsc-rs-cli, bender, reactive-vcr, and burns from this
/// checkout's build/Glitchbox.app (see EffectsFixture).
/// Outputs are compared decoded (frame count, size, pix_fmt, colour tags, PSNR).
@Suite(.serialized)
struct EffectsTests {
    @Test func analogPassMatchesNtscRsCli() async throws {
        let f = try await EffectsFixture.get()
        let r = try await f.compare(plugin: "analog-pass", input: f.clip, params: [:])
        #expect(r.ours.frames == 30)       // ffvhuff layer: no trailing frame
        try r.expectMatch(minPSNR: 50)
    }

    @Test func analogPassScaledFFV1InputMatchesNtscRsCli() async throws {
        let f = try await EffectsFixture.get()
        let r = try await f.compare(plugin: "analog-pass", input: f.ffv1Clip,
                                    params: ["scale": .int(120), "seed": .int(7)])
        #expect(r.ours.frames == 31)       // FFV1 layer: ntsc-rs-cli's trailing N + 1 frame
        #expect(r.ours.height == 120)
        try r.expectMatch(minPSNR: 50)
    }

    @Test func benderMatchesBenderCli() async throws {
        let f = try await EffectsFixture.get()
        let r = try await f.compare(plugin: "bender", input: f.clip, params: [:])
        #expect(r.ours.frames == 30)
        try r.expectMatch(minPSNR: 50)
    }

    @Test func benderScanlinesAndOrderMatchBenderCli() async throws {
        let f = try await EffectsFixture.get()
        let r = try await f.compare(plugin: "bender", input: f.ffv1Clip, params: [
            "scanlines": .int(120), "order": .string("tape, sync, clock"), "tape__enabled": .bool(true),
            "seed": .int(5),
        ])
        #expect(r.ours.frames == 30 && r.ours.height == 120)
        try r.expectMatch(minPSNR: 50)
    }

    @Test func reactiveVCRMatchesCli() async throws {
        let f = try await EffectsFixture.get()
        let r = try await f.compare(plugin: "reactive-vcr", input: f.clip, params: [:], sourceAudio: f.audio)
        #expect(r.ours.frames == 30)
        try r.expectMatch(minPSNR: 50)
    }

    @Test func reactiveVCRWithoutAudioFails() async throws {
        let f = try await EffectsFixture.get()
        let c = try f.context(plugin: "reactive-vcr", input: f.clip, params: [:], sourceAudio: nil, name: "rvcr-noaudio")
        let code = try await ReactiveVCRStep().run(c)
        #expect(code == 1)
        #expect(EffectsFixture.log(c.log).contains("reactive-vcr: the source has no audio track; choose an Audio file"))
    }

    /// With no Map file the mapping comes from the sliders: the macOS script builds it with jq,
    /// iOS with `ReactiveVCRStep.mapping`. Same text, or the two platforms render different effects.
    @Test func reactiveMappingIsThePluginsJq() async throws {
        let f = try await EffectsFixture.get()
        let cases: [[String: ParamValue]] = [
            [:],
            ["bass": .float(0.75), "hits": .float(0), "level": .float(0), "highs": .float(0), "response": .float(0.65)],
            ["bass": .float(0), "hits": .float(1), "level": .float(0.3), "highs": .float(0)],
            ["bass": .float(0.33), "hits": .float(0.07), "level": .float(0.99), "highs": .float(0.01), "response": .float(0.03),
             "sensitivity": .float(2.37)],
            ["bass": .float(1), "hits": .float(1), "level": .float(1), "highs": .float(1), "response": .float(1), "sensitivity": .float(3)],
            ["bass": .float(0), "hits": .float(0), "level": .float(0), "highs": .float(0)],
        ]
        for given in cases {
            let params = f.params("reactive-vcr", given)
            #expect(ReactiveVCRStep.mapping(params) == (try f.jqReactiveMapping(params)), "\(given)")
        }
    }

    @Test func stillMotionKenBurnsMatchesBurns() async throws {
        let f = try await EffectsFixture.get()
        let r = try await f.compare(plugin: "still-motion", input: f.still, params: [:])
        #expect(r.ours.frames == 30 && r.ours.width == 320 && r.ours.height == 180)
        try r.expectMatch(minPSNR: 50)
    }

    @Test func stillMotionAutoDepthMatchesBurns() async throws {
        let f = try await EffectsFixture.get()
        let r = try await f.compare(plugin: "still-motion", input: f.still, params: ["motion": .string("depth")])
        #expect(r.ours.frames == 30)
        try r.expectMatch(minPSNR: 50)
        let maps = try FileManager.default.contentsOfDirectory(atPath: f.burnsCache.appending(path: "depth").path)
        #expect(!maps.isEmpty, "auto-depth did not cache a depth map")
    }

    @Test func stillMotionProjectIsThePluginsJq() async throws {
        let f = try await EffectsFixture.get()
        for motion in ["still", "transform", "tilt", "breathing", "figure-eight", "depth"] {
            for warp in ["ripple", "heat-shimmer"] {
                let params = f.params("still-motion", ["motion": .string(motion), "warp_type": .string(warp)])
                let ours = try JSONSerialization.jsonObject(with: Data(StillMotionStep.project(params).utf8)) as! NSDictionary
                let theirs = try f.jqStillMotionProject(params) as! NSDictionary
                #expect(ours == theirs, "\(motion)/\(warp)")
            }
        }
    }

    @Test(arguments: ["analog-pass", "bender", "reactive-vcr", "still-motion"])
    func cancellationStopsMidRender(plugin: String) async throws {
        let f = try await EffectsFixture.get()
        let input = plugin == "still-motion" ? f.still : f.longClip
        var c = try f.context(plugin: plugin, input: input, params: [:], sourceAudio: f.longAudio,
                              name: "cancel-\(plugin)")
        if plugin == "still-motion" {
            c.environment["GB_DURATION"] = "20"; c.environment["GB_WIDTH"] = "1920"; c.environment["GB_HEIGHT"] = "1080"
        }
        let step = try #require(InProcessRunner().native(plugin))
        let context = c
        let task = Task { try await step.run(context) }
        // Cancel once the step is writing frames (its output exists), well before it can finish.
        let deadline = ContinuousClock.now + .seconds(60)
        while !FileManager.default.fileExists(atPath: c.output.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        let cancelled = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let stopped = ContinuousClock.now - cancelled
        print("cancel \(plugin): stopped \(stopped) after cancel")
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(stopped < .seconds(3), "\(plugin) took \(stopped) to stop")
        #expect(!FileManager.default.fileExists(atPath: c.output.path), "partial output left behind")
    }
}

/// Decoded comparison of one plugin render.
struct EffectComparison {
    struct Shape: Equatable { var frames: Int; var width: Int; var height: Int; var pixelFormat: String; var tags: String }
    let plugin: String
    let ours: Shape, theirs: Shape
    let psnr: Double, minFramePSNR: Double, identical: Bool

    func expectMatch(minPSNR: Double) throws {
        let summary = "\(plugin): frames \(ours.frames)/\(theirs.frames), \(ours.width)x\(ours.height) "
            + "\(ours.pixelFormat), \(identical ? "identical" : String(format: "PSNR avg %.2f dB, min frame %.2f dB", psnr, minFramePSNR))"
        print("effects parity — \(summary); ours tags \(ours.tags) | macOS \(theirs.tags)")
        #expect(ours == theirs, "\(summary): ours \(ours) vs macOS \(theirs)")
        #expect(identical || minFramePSNR >= minPSNR, "\(summary)")
    }
}

struct EffectsFixture: Sendable {
    static let repo = URL(filePath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// This checkout's `packaging/build.sh all` output.
    static let mac = repo.appending(path: "build/Glitchbox.app/Contents", directoryHint: .isDirectory)
    static let helpers = mac.appending(path: "Helpers", directoryHint: .isDirectory)
    static let burns = helpers.appending(path: "burns")
    static let ort = mac.appending(path: "Frameworks/libonnxruntime.dylib")
    static let model = repo.appending(path: "build/downloads/depth-anything-v2-small-4472b736.onnx")
    static let modelSHA = "afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c"

    let dir: URL
    /// 1 s 320×240 @ 30 fps ffvhuff yuv420p (smpte170m), as source prep writes layers.
    let clip: URL
    /// The same as FFV1 (an ntsc-rs/bender layer's codec).
    let ffv1Clip: URL
    /// 1 s 48 kHz audio with level changes, as the source layer's audio.wav.
    let audio: URL
    /// 30 s 640×480 clip and audio for cancellation.
    let longClip: URL
    let longAudio: URL
    /// 640×480 testsrc2 PNG.
    let still: URL
    /// The model-seeded burns cache our steps use (BURNS_CACHE).
    let burnsCache: URL
    /// The model-seeded HOME the reference burns uses.
    let burnsHome: URL

    static let shared = Task<EffectsFixture, any Error> { try make() }
    static func get() async throws -> EffectsFixture { try await shared.value }

    private static func make() throws -> EffectsFixture {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "glitchbox-effects-tests", directoryHint: .isDirectory)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func ffmpeg(_ args: [String]) throws {
            try tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y"] + args)
        }
        let tags = ["-color_primaries", "smpte170m", "-color_trc", "smpte170m", "-colorspace", "smpte170m", "-color_range", "tv"]
        let clip = dir.appending(path: "clip.mkv"), ffv1 = dir.appending(path: "clip-ffv1.mkv")
        let long = dir.appending(path: "long.mkv")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "1", "-c:v", "ffvhuff", "-pix_fmt", "yuv420p"]
                   + tags + ["-fflags", "+bitexact", "-flags:v", "+bitexact", clip.path])
        try ffmpeg(["-i", clip.path, "-c:v", "ffv1", "-fflags", "+bitexact", "-flags:v", "+bitexact", ffv1.path])
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x480:rate=30", "-t", "30", "-c:v", "ffvhuff", "-pix_fmt", "yuv420p"]
                   + tags + [long.path])
        let audio = dir.appending(path: "audio.wav"), longAudio = dir.appending(path: "long.wav")
        for (url, seconds) in [(audio, 1), (longAudio, 30)] {
            try ffmpeg(["-f", "lavfi", "-i",
                        "aevalsrc=0.8*sin(2*PI*110*t)*(0.5+0.5*sin(2*PI*3*t))+0.3*sin(2*PI*5000*t)*gt(mod(t\\,0.25)\\,0.2):s=48000:d=\(seconds)",
                        "-ac", "2", "-c:a", "pcm_s16le", url.path])
        }
        let still = dir.appending(path: "still.png")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x480", "-frames:v", "1", still.path])

        // Depth model pre-seeded for both sides, so auto-depth runs offline.
        let burnsCache = dir.appending(path: "burns-cache", directoryHint: .isDirectory)
        let burnsHome = dir.appending(path: "burns-home", directoryHint: .isDirectory)
        for models in [burnsCache.appending(path: "models"), burnsHome.appending(path: "Library/Caches/burns/models")] {
            try fm.createDirectory(at: models, withIntermediateDirectories: true)
            try fm.copyItem(at: model, to: models.appending(path: "\(modelSHA).onnx"))
        }
        return EffectsFixture(dir: dir, clip: clip, ffv1Clip: ffv1, audio: audio, longClip: long, longAudio: longAudio,
                              still: still, burnsCache: burnsCache, burnsHome: burnsHome)
    }

    // MARK: Params

    /// The plugin's param defaults (typed as the engine resolves them) with `overrides`.
    func params(_ plugin: String, _ overrides: [String: ParamValue]) -> [String: ParamValue] {
        let url = Self.repo.appending(path: "plugins/\(plugin).json")
        let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var out: [String: ParamValue] = [:]
        for p in json["params"] as! [[String: Any]] {
            let key = p["key"] as! String, type = p["type"] as! String
            switch type {
            case "int": out[key] = .int((p["default"] as! NSNumber).intValue)
            case "float": out[key] = .float((p["default"] as! NSNumber).doubleValue)
            case "bool": out[key] = .bool(p["default"] as! Bool)
            case "file":
                let s = p["default"] as? String ?? ""
                out[key] = .string(s.isEmpty || s.hasPrefix("/") ? s : Self.repo.appending(path: s).path)
            default: out[key] = .string(p["default"] as? String ?? "")
            }
        }
        return out.merging(overrides) { $1 }
    }

    func context(plugin: String, input: URL, params overrides: [String: ParamValue], sourceAudio: URL?,
                 name: String) throws -> NativeStepContext {
        let work = dir.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let params = params(plugin, overrides)
        let paramsFile = work.appending(path: "params.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try encoder.encode(params).write(to: paramsFile)
        let env = ["GB_FPS": "30", "GB_DURATION": "1", "GB_WIDTH": "320", "GB_HEIGHT": "180",
                   "BURNS_CACHE": burnsCache.path]
        return NativeStepContext(plugin: plugin, step: "render", input: input, output: work.appending(path: "out.mkv"),
                                 work: work.appending(path: "work", directoryHint: .isDirectory), root: Self.repo,
                                 params: params, paramsFile: paramsFile, sourceAudio: sourceAudio,
                                 log: work.appending(path: "log.txt"), environment: env)
    }

    // MARK: Comparison

    func compare(plugin: String, input: URL, params: [String: ParamValue], sourceAudio: URL? = nil) async throws
        -> EffectComparison {
        let name = "\(plugin)-\(abs(params.description.hashValue) % 100_000)"
        let c = try context(plugin: plugin, input: input, params: params, sourceAudio: sourceAudio, name: name)
        let step = try #require(InProcessRunner().native(plugin))
        let started = ContinuousClock.now
        let code = try await step.run(c)
        let elapsed = ContinuousClock.now - started
        try #require(code == 0, "\(plugin) exited \(code): \(Self.log(c.log))")
        let reference = c.work.deletingLastPathComponent().appending(path: "reference.mkv")
        try renderReference(c, to: reference)
        print("\(plugin): in-process render \(elapsed)")
        let ours = try Self.shape(c.output), theirs = try Self.shape(reference)
        let fmt = theirs.pixelFormat
        let a = try Self.raw(c.output, fmt), b = try Self.raw(reference, fmt)
        let frameBytes = a.count / max(ours.frames, 1)
        var mse: [Double] = []
        if a.count == b.count, frameBytes > 0 {
            a.withUnsafeBytes { pa in
                b.withUnsafeBytes { pb in
                    for f in 0..<ours.frames {
                        var sum = 0.0
                        for i in (f * frameBytes)..<((f + 1) * frameBytes) {
                            let d = Double(Int(pa[i]) - Int(pb[i])); sum += d * d
                        }
                        mse.append(sum / Double(frameBytes))
                    }
                }
            }
        }
        func psnr(_ m: Double) -> Double { m == 0 ? 99 : 10 * log10(255 * 255 / m) }
        let avg = mse.isEmpty ? 0 : psnr(mse.reduce(0, +) / Double(mse.count))
        let minFrame = mse.map(psnr).min() ?? 0
        return EffectComparison(plugin: plugin, ours: ours, theirs: theirs, psnr: avg, minFramePSNR: minFrame,
                                identical: a == b)
    }

    /// The macOS plugin script → pipeline → CLI chain for `c`, with its exact flags.
    func renderReference(_ c: NativeStepContext, to out: URL) throws {
        let ref = c.work.deletingLastPathComponent().appending(path: "ref", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ref, withIntermediateDirectories: true)
        let rawOut = ref.appending(path: "stage1.mkv")
        let p = c.paramsFile.path
        switch c.plugin {
        case "analog-pass":
            let preset = try Self.tool("jq", ["-c", "del(.seed, .scale) | with_entries(if (.value | type) == \"string\" then .value |= tonumber else . end) | . + {version: 1}", p])
            let presetFile = ref.appending(path: "settings.json")
            try preset.write(to: presetFile, atomically: true, encoding: .utf8)
            let seed = c.params.rendered("seed"), scale = Int(c.params.rendered("scale")) ?? 0
            let settings = try Self.tool("jq", ["-cS", "--argjson", "seed", seed, ".random_seed = $seed", presetFile.path])
                .trimmingCharacters(in: .newlines)
            try Self.tool("ntsc-rs-cli", ["-i", c.input.path, "-o", rawOut.path, "-c", "ffv1", "--chroma-subsampling", "-y",
                                          "-j", settings] + (scale > 0 ? ["--scale", String(scale)] : []))
            try Self.remux(rawOut, out, ["-c:v", "copy"])
        case "bender":
            let seed = c.params.rendered("seed")
            let preset = try Self.tool("jq", ["-c", "--argjson", "seed", seed,
                "reduce (to_entries[] | select(.key | contains(\"__\"))) as $e ({version: 1, seed: $seed}; setpath($e.key | split(\"__\"); $e.value))", p])
            let presetFile = ref.appending(path: "bender.json")
            try preset.write(to: presetFile, atomically: true, encoding: .utf8)
            let order = c.params.rendered("order").replacingOccurrences(of: " ", with: "")
            let effect = try Self.tool("bender", ["--preset", presetFile.path] + (order.isEmpty ? [] : ["--set", "order=\(order)"])
                                       + ["--seed", seed, "--dump-preset"])
            let effectFile = ref.appending(path: "preset.json")
            try effect.write(to: effectFile, atomically: true, encoding: .utf8)
            try Self.tool("bender", ["-i", c.input.path, "-o", rawOut.path, "--codec", "ffv1", "--scanlines",
                                     c.params.rendered("scanlines"), "--preset", effectFile.path, "--overwrite"])
            try Self.remux(rawOut, out, ["-map", "0", "-c", "copy"])
        case "reactive-vcr":
            let audio = c.fileParam("audio") ?? c.sourceAudio!.path
            let map: String
            if let file = c.fileParam("map") {
                map = file
            } else {
                map = ref.appending(path: "map.toml").path
                try jqReactiveMapping(c.params).write(toFile: map, atomically: true, encoding: .utf8)
            }
            try Self.tool("reactive-vcr", ["render", "--video", c.input.path, "--audio", audio, "--map",
                                           map, "--audio-mode", "none", "--output", rawOut.path])
            try Self.remux(rawOut, out, ["-c:v", "copy", "-c:a", "copy"])
        case "still-motion":
            let project = ref.appending(path: "project.json")
            try JSONSerialization.data(withJSONObject: jqStillMotionProject(c.params)).write(to: project)
            var args = ["render", "-i", c.input.path, "-o", ref.appending(path: "motion.mkv").path, "--config", project.path,
                        "--fps", "30", "--duration", "1", "--width", "320", "--height", "180", "--codec", "ffv1"]
            if c.params.rendered("motion") == "depth" { args.append("--auto-depth") }
            try Self.run(Self.burns, args, environment: ["HOME": burnsHome.path, "ORT_DYLIB_PATH": Self.ort.path,
                                                          "PATH": "\(Self.helpers.path):/usr/bin:/bin"])
            try Self.remux(ref.appending(path: "motion.mkv"), out, ["-map", "0:v:0", "-c", "copy"])
        default:
            Issue.record("no reference for \(c.plugin)")
        }
    }

    /// still-motion's own jq project builder (extracted from the plugin script) over `params`.
    func jqStillMotionProject(_ params: [String: ParamValue]) throws -> Any {
        let plugin = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appending(path: "plugins/still-motion.json")))
            as! [String: Any]
        let script = ((plugin["steps"] as! [[String: Any]])[0]["script"] as! String)
        let start = try #require(script.range(of: "jq '{"))
        let end = try #require(script.range(of: "}' \"$GB_PARAMS\"", range: start.upperBound..<script.endIndex))
        let filter = String(script[script.index(start.lowerBound, offsetBy: 4)...end.lowerBound])
        let file = dir.appending(path: "sm-params-\(UUID().uuidString).json")
        try JSONEncoder().encode(params).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try JSONSerialization.jsonObject(with: Data(try Self.tool("jq", [filter, file.path]).utf8))
    }

    /// reactive-vcr's own jq mapping builder (extracted from the plugin script) over `params`.
    func jqReactiveMapping(_ params: [String: ParamValue]) throws -> String {
        let plugin = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appending(path: "plugins/reactive-vcr.json")))
            as! [String: Any]
        let script = ((plugin["steps"] as! [[String: Any]])[0]["script"] as! String)
        let start = try #require(script.range(of: "jq -r '\n"))
        let end = try #require(script.range(of: "\n  ' \"$GB_PARAMS\"", range: start.upperBound..<script.endIndex))
        let filter = String(script[start.upperBound..<end.lowerBound])
        let file = dir.appending(path: "rv-params-\(UUID().uuidString).json")
        try JSONEncoder().encode(params).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try Self.tool("jq", ["-r", filter, file.path])
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: Tools

    static func remux(_ input: URL, _ output: URL, _ codec: [String]) throws {
        try tool("ffmpeg", ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", input.path,
                            "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1", "-map_chapters", "-1"]
                 + codec + ["-y", output.path])
    }

    static func shape(_ url: URL) throws -> EffectComparison.Shape {
        let out = try tool("ffprobe", ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
            "stream=nb_read_frames,width,height,pix_fmt,codec_name,color_range,color_space,color_transfer,color_primaries,chroma_location,sample_aspect_ratio",
            "-of", "json", url.path])
        let s = ((try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any])["streams"] as! [[String: Any]])[0]
        let tags = ["codec_name", "color_range", "color_space", "color_transfer", "color_primaries", "chroma_location",
                    "sample_aspect_ratio"].map { "\($0)=\(s[$0] as? String ?? "-")" }.joined(separator: ",")
        return .init(frames: Int(s["nb_read_frames"] as? String ?? "") ?? -1, width: s["width"] as? Int ?? 0,
                     height: s["height"] as? Int ?? 0, pixelFormat: s["pix_fmt"] as? String ?? "", tags: tags)
    }

    static func raw(_ url: URL, _ pixelFormat: String) throws -> Data {
        let file = url.deletingPathExtension().appendingPathExtension("raw")
        try tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-map", "0:v:0",
                            "-f", "rawvideo", "-pix_fmt", pixelFormat, file.path])
        return try Data(contentsOf: file)
    }

    static func log(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Runs a Glitchbox.app helper in its toolchain environment; returns stdout.
    @discardableResult
    static func tool(_ name: String, _ args: [String]) throws -> String {
        let gst = mac.appending(path: "Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0").path
        let registry = FileManager.default.temporaryDirectory.appending(path: "glitchbox-effects-gst-registry.bin").path
        return try run(helpers.appending(path: name), args, environment: [
            "GST_PLUGIN_SYSTEM_PATH": gst, "GST_REGISTRY": registry, "PATH": "\(helpers.path):/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ])
    }

    @discardableResult
    static func run(_ exe: URL, _ args: [String], environment: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        let errURL = FileManager.default.temporaryDirectory.appending(path: "glitchbox-effects-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? err.close() }
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw EffectError("\(exe.lastPathComponent) \(args.joined(separator: " ")) exited \(p.terminationStatus): "
                              + String(errText.suffix(2000)))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
