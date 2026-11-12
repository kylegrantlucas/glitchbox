import Foundation
import GBMedia
import GlitchboxBurns
import GlitchboxKit

/// plugins/still-motion.json: `burns render -i STILL --config PROJECT --fps $GB_FPS --duration
/// $GB_DURATION --width $GB_WIDTH --height $GB_HEIGHT --crf 0 [--auto-depth | --depth FILE]`,
/// then a remux of its lossless H.264 into Matroska. In-process: GlitchboxBurns renders the
/// RGBA frames and libx264 (GBMedia) encodes them with burns's encoder settings straight into
/// the MKV layer.
///
/// Auto-depth keeps burns's cache layout (`models/`, `depth/`) under `$BURNS_CACHE`
/// (toolchain.json: `"BURNS_CACHE": "@cache/burns"`, the Workspace cache dir); a depth render
/// without it fails. `$ORT_DYLIB_PATH` overrides the
/// ONNX Runtime library; by default the onnxruntime.framework beside GlitchboxBurns loads.
public struct StillMotionStep: NativeStep {
    public init() {}

    /// The plugin's jq project builder, field for field (burns rejects missing or unknown
    /// fields, so a param missing here becomes `null` and fails just as jq's would).
    static func project(_ p: [String: ParamValue]) -> String {
        func v(_ key: String) -> String { JQ.value(p[key]) }
        func obj(_ fields: [(String, String)]) -> String {
            "{" + fields.map { "\(JQ.string($0.0)):\($0.1)" }.joined(separator: ",") + "}"
        }
        func view(_ prefix: String) -> String {
            obj([("zoom", v("\(prefix)_zoom")), ("x", v("\(prefix)_x")), ("y", v("\(prefix)_y")),
                 ("roll_degrees", v("\(prefix)_roll"))])
        }
        let camera: String
        switch p["motion"] {
        case .string("still")?:
            camera = obj([("type", JQ.string("still")), ("view", view("view"))])
        case .string("transform")?:
            camera = obj([("type", JQ.string("transform")), ("start", view("start")), ("end", view("end")),
                          ("easing", v("easing"))])
        case .string("tilt")?:
            camera = obj([("type", JQ.string("tilt")), ("amount", v("tilt_amount")), ("easing", v("easing"))])
        case .string("breathing")?:
            camera = obj([("type", JQ.string("breathing")), ("base_zoom", v("breath_zoom")),
                          ("amplitude", v("breath_swing")), ("cycles", v("breath_cycles"))])
        case .string("figure-eight")?:
            camera = obj([("type", JQ.string("figure-eight")), ("zoom", v("eight_zoom")),
                          ("amplitude", "[\(v("eight_x")),\(v("eight_y"))]"), ("cycles", v("eight_cycles"))])
        default:
            camera = obj([("type", JQ.string("depth")), ("motion", v("depth_motion")), ("height", v("depth_height")),
                          ("steady", v("depth_steady")), ("focus", v("depth_focus")), ("zoom", v("depth_zoom")),
                          ("amount", v("depth_amount")), ("cycles", v("depth_cycles"))])
        }
        let warp: String
        if case .string("ripple")? = p["warp_type"] {
            warp = obj([("type", JQ.string("ripple")), ("enabled", v("warp")), ("amplitude", v("warp_amplitude")),
                        ("wavelength", v("warp_wavelength")),
                        ("center", "[\(v("warp_center_x")),\(v("warp_center_y"))]"), ("cycles", v("warp_cycles"))])
        } else {
            warp = obj([("type", JQ.string("heat-shimmer")), ("enabled", v("warp")), ("amplitude", v("warp_amplitude")),
                        ("spatial_scale", v("warp_scale")), ("cycles", v("warp_cycles"))])
        }
        return obj([
            ("version", "1"),
            ("output", obj([("width", "1920"), ("height", "1080")])),
            ("timeline", obj([("fps", obj([("num", "30"), ("den", "1")])), ("frames", "30")])),
            ("seed", v("seed")),
            ("camera", camera),
            ("depth", obj([("invert", v("depth_invert"))])),
            ("shake", obj([("enabled", v("shake")), ("profile", v("shake_profile")), ("amount", v("shake_amount")),
                           ("speed", v("shake_speed"))])),
            ("warp", warp),
        ])
    }

    /// The render flags from the step environment (`GB_FPS` is "N" or "N/D").
    struct Target {
        var fpsNum: UInt32, fpsDen: UInt32, duration: Double, width: UInt32, height: UInt32

        init(_ env: [String: String]) throws {
            func need(_ key: String) throws -> String {
                guard let s = env[key], !s.isEmpty else {
                    throw EffectError("\(key) is not set (still-motion renders only as the first layer over a still)")
                }
                return s
            }
            let fps = try need("GB_FPS").split(separator: "/").map(String.init)
            guard let n = UInt32(fps[0]), n > 0 else { throw EffectError("bad GB_FPS \(env["GB_FPS"]!)") }
            let d = fps.count > 1 ? UInt32(fps[1]) : 1
            guard let d, d > 0, fps.count <= 2 else { throw EffectError("bad GB_FPS \(env["GB_FPS"]!)") }
            guard let duration = Double(try need("GB_DURATION")), duration > 0 else { throw EffectError("bad GB_DURATION") }
            guard let w = UInt32(try need("GB_WIDTH")), let h = UInt32(try need("GB_HEIGHT")) else {
                throw EffectError("bad GB_WIDTH/GB_HEIGHT")
            }
            fpsNum = n; fpsDen = d; self.duration = duration; width = w; height = h
        }
    }

    /// `$BURNS_CACHE` (required for auto-depth).
    static func cacheDir(_ env: [String: String]) throws -> URL {
        guard let dir = env["BURNS_CACHE"], !dir.isEmpty else {
            throw EffectError("BURNS_CACHE is not set by the toolchain (needed for depth estimation)")
        }
        return URL(filePath: dir, directoryHint: .isDirectory)
    }

    public func run(_ c: NativeStepContext) async throws -> Int32 {
        let project = Self.project(c.params)
        let depthMode: gb_burns_depth_mode
        var depthFile: String?
        if case .string("depth")? = c.params["motion"] {
            depthFile = c.fileParam("depth")
            depthMode = depthFile == nil ? GB_BURNS_DEPTH_AUTO : GB_BURNS_DEPTH_FILE
        } else {
            depthMode = GB_BURNS_DEPTH_NONE
        }
        return try await Effect.run(c, name: "still-motion") { [depthFile] flag in
            try Self.render(c, project: project, depthMode: depthMode, depthFile: depthFile, flag: flag)
        }
    }

    final class ProgressSink {
        let log: URL
        var lastPhase = ""
        init(log: URL) { self.log = log }
    }

    static func render(_ c: NativeStepContext, project: String, depthMode: gb_burns_depth_mode, depthFile: String?,
                       flag: CancelFlag) throws {
        let target = try Target(c.environment)
        try FileManager.default.createDirectory(at: c.work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: c.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(project.utf8).write(to: c.work.appending(path: "project.json"))

        // burns reads PNG, JPEG, and WebP; other stills go through a PNG.
        let image: String
        switch c.input.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp": image = c.input.path
        default:
            image = c.work.appending(path: "still.png").path
            let code = ToolCall.call(.ffmpeg, ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
                                               "-i", c.input.path, "-frames:v", "1", "-y", image],
                                     log: c.log.path, flag: flag)
            try Effect.check(flag)
            guard code == 0 else { throw EffectError("ffmpeg could not convert the still to PNG (exit \(code))") }
        }

        var cachePath = ""
        if depthMode == GB_BURNS_DEPTH_AUTO {
            let cache = try cacheDir(c.environment)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            cachePath = cache.path
        }
        let ort = c.environment["ORT_DYLIB_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        let strings = [image, project, depthFile ?? "", cachePath, ort ?? ""].map { strdup($0)! }
        defer { strings.forEach { free($0) } }

        let sink = ProgressSink(log: c.log)
        let sinkRef = Unmanaged.passRetained(sink)
        defer { sinkRef.release() }
        let progress: gb_burns_progress_fn = { context, phase, _, _, message in
            guard let context, let phase else { return }
            let sink = Unmanaged<ProgressSink>.fromOpaque(context).takeUnretainedValue()
            let name = String(cString: phase)
            if let message {
                ToolCall.append(sink.log, "burns: \(name): \(String(cString: message))\n")
            } else if name != sink.lastPhase {
                ToolCall.append(sink.log, "burns: depth \(name)\n")
            }
            sink.lastPhase = name
        }

        var options = gb_burns_options()
        options.image_path = UnsafePointer(strings[0])
        options.project_json = UnsafePointer(strings[1])
        options.fps_num = target.fpsNum
        options.fps_den = target.fpsDen
        options.duration = target.duration
        options.width = target.width
        options.height = target.height
        options.depth_mode = depthMode
        if depthMode == GB_BURNS_DEPTH_FILE { options.depth_path = UnsafePointer(strings[2]) }
        if depthMode == GB_BURNS_DEPTH_AUTO {
            options.cache_dir = UnsafePointer(strings[3])
            if ort != nil { options.ort_library = UnsafePointer(strings[4]) }
            options.progress = progress
            options.progress_context = sinkRef.toOpaque()
        }

        var err: UnsafeMutablePointer<CChar>?
        let created = withUnsafePointer(to: &options) { o in
            // A gbr_flag is a struct whose only member is the atomic_int burns polls.
            gb_burns_create(o, flag.raw, &err)
        }
        guard let renderer = created else {
            try Effect.check(flag)
            let message = err.map { String(cString: $0) } ?? "burns could not start"
            gb_burns_string_free(err)
            throw EffectError(message)
        }
        defer { gb_burns_free(renderer) }
        try Effect.check(flag)

        let w = Int(gb_burns_width(renderer)), h = Int(gb_burns_height(renderer))
        let frames = gb_burns_frame_count(renderer)
        var num: UInt32 = 0, den: UInt32 = 0
        gb_burns_fps(renderer, &num, &den)
        let rate = gbm_rational(num: Int32(num), den: Int32(max(den, 1)))
        ToolCall.append(c.log, "burns: \(frames) frames at \(w)x\(h) @ \(num)/\(den)\n")

        // burns's encoder: `-vf scale=in_range=full:out_range=tv:out_color_matrix=bt709,format=yuv420p,
        // setparams=…` → libx264 -preset medium -crf 0 -pix_fmt yuv420p, all tags BT.709, limited.
        let converter = try MediaConverter(
            width: w, height: h, pixelFormat: "rgba",
            filters: "scale=in_range=full:out_range=tv:out_color_matrix=bt709,format=yuv420p,"
                + "setparams=color_primaries=bt709:color_trc=bt709")
        let encoder = try MediaEncoder(
            url: c.output,
            config: Effect.encoderConfig(codec: Int32(GBM_CODEC_LIBX264.rawValue), width: w, height: h,
                                         pixelFormat: "yuv420p", rate: rate, space: AVColor.bt709,
                                         primaries: AVColor.bt709, transfer: AVColor.bt709,
                                         chromaLocation: AVColor.chromaLeft),
            codecOptions: "preset=medium:crf=0")

        let stride = w * 4
        var rgba = [UInt8](repeating: 0, count: stride * h)
        for i in 0..<frames {
            try Effect.check(flag)
            var frameErr: UnsafeMutablePointer<CChar>?
            let rc = rgba.withUnsafeMutableBufferPointer { gb_burns_render_frame(renderer, i, $0.baseAddress, stride, &frameErr) }
            if rc != 0 {
                let message = frameErr.map { String(cString: $0) } ?? "render failed"
                gb_burns_string_free(frameErr)
                throw EffectError("frame \(i): \(message)")
            }
            let yuv = try rgba.withUnsafeBytes { try converter.run(packed: $0.baseAddress!, stride: stride) }
            try encoder.write(yuv, index: Int64(i))
        }
        try encoder.finish()
    }
}
