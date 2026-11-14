import Foundation
import GlitchboxKit

// Native versions of the FFglitch plugin steps. Each reproduces its macOS script's tool calls
// exactly (argv, flags, -sp JSON); only the shell plumbing is replaced.

/// Shared pieces of the forced-MV MPEG-2 encode | ffedit | lossless decode chain.
enum MoshChain {
    /// `ffgac … -vcodec mpeg2video -f rawvideo -` (scripts: `[ "$gop" -gt 0 ] || gop=max`).
    static func encode(_ c: NativeStepContext) -> PipeChain.Stage {
        let gop = Int(c.params.rendered("gop")).map { $0 > 0 ? String($0) : "max" } ?? "max"
        let input = c.input.path, qscale = c.params.rendered("qscale")
        return PipeChain.Stage(tool: .ffgac, argv: { _, out in
            ["ffgac", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", input, "-an",
             "-mpv_flags", "+nopimb+forcemv", "-qscale:v", qscale, "-g", gop, "-bf", "0", "-sc_threshold", "max",
             "-vcodec", "mpeg2video", "-f", "rawvideo", out!]
        }, log: c.log)
    }

    /// `ffedit -i - -f mv -s SCRIPT [-sp P] -o -`.
    static func edit(_ c: NativeStepContext, script: String, scriptParams: String?) -> PipeChain.Stage {
        PipeChain.Stage(tool: .ffedit, argv: { input, out in
            ["ffedit", "-i", input!, "-f", "mv", "-s", script] + (scriptParams.map { ["-sp", $0] } ?? []) + ["-o", out!]
        }, log: c.log)
    }

    /// `ffmpeg … -f mpegvideo -i - … -c:v ffvhuff -y OUT`.
    static func decode(_ c: NativeStepContext) -> PipeChain.Stage {
        let output = c.output.path
        return PipeChain.Stage(tool: .ffmpeg, argv: { input, _ in
            ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "mpegvideo", "-i", input!,
             "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1", "-map_chapters", "-1",
             "-c:v", "ffvhuff", "-threads:v", "2", "-y", output]
        }, log: c.log)
    }
}

/// plugins/mpeg2-mosh.json: ffgac | ffedit `scripts/mosh.js` | ffmpeg.
struct MPEG2MoshStep: NativeStep {
    func run(_ c: NativeStepContext) async throws -> Int32 {
        // jq -c '{tail, h_scale, v_scale, pan_x, pan_y}' "$GB_PARAMS"
        let sp = JQ.object(["tail", "h_scale", "v_scale", "pan_x", "pan_y"].map { ($0, c.params[$0]) })
        let script = c.root.appending(path: "scripts/mosh.js").path
        return try await PipeChain.run([MoshChain.encode(c), MoshChain.edit(c, script: script, scriptParams: sp),
                                        MoshChain.decode(c)], log: c.log)
    }
}

/// plugins/mv-script.json: ffgac | ffedit `$FFGLITCH_SCRIPTS/…/instant_damage/<script>` | ffmpeg.
struct MVScriptStep: NativeStep {
    static let scriptDir = "free-for-all/dd-glitch-assist-scriptsv10/instant_damage"

    func run(_ c: NativeStepContext) async throws -> Int32 {
        guard let scripts = c.environment["FFGLITCH_SCRIPTS"], !scripts.isEmpty else {
            ToolCall.append(c.log, "error: FFGLITCH_SCRIPTS is not set by the toolchain\n")
            return 1
        }
        let script = URL(filePath: scripts, directoryHint: .isDirectory)
            .appending(path: Self.scriptDir).appending(path: c.params.rendered("script")).path
        let amount = c.params.rendered("amount")
        let sp = (Int(amount) ?? 0) != 0 ? amount : nil
        return try await PipeChain.run([MoshChain.encode(c), MoshChain.edit(c, script: script, scriptParams: sp),
                                        MoshChain.decode(c)], log: c.log)
    }
}

/// pipelines/mv-mangle with the plugin's argv (`--qscale --gop --amount --seed -o OUT IN`):
/// MPEG-4 forced-MV encode | `ffedit -t` with `scripts/mv-shuffle.js` | lossless re-encode,
/// streamed as raw m4v with the input's probed `r_frame_rate` as the decoder's `-r`.
struct MVMangleStep: NativeStep {
    func run(_ c: NativeStepContext) async throws -> Int32 {
        let fm = FileManager.default
        let quiet = !(c.environment["GB_QUIET"] ?? "").isEmpty
        let level = c.environment["GB_LOGLEVEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "error"
        let qscale = c.params.rendered("qscale", default: "8"), gop = c.params.rendered("gop", default: "1000")
        let amount = c.params.rendered("amount", default: "8"), seed = c.params.rendered("seed", default: "1")

        let script = c.root.appending(path: "scripts/mv-shuffle.js")
        guard fm.fileExists(atPath: script.path) else {
            ToolCall.append(c.log, "error: ffedit script not found: \(script.path)\n")
            return 1
        }
        guard fm.fileExists(atPath: c.input.path) else {
            ToolCall.append(c.log, "error: input not found: \(c.input.path)\n")
            return 1
        }

        // RATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 IN)
        try fm.createDirectory(at: c.work, withIntermediateDirectories: true)
        let probeOut = c.work.appending(path: "mv-mangle-rate.txt")
        try? fm.removeItem(at: probeOut)
        let probe = try await ToolCall.cancellable("ffprobe") { [input = c.input.path, out = probeOut.path] flag in
            ToolCall.call(.ffprobe, ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                     "stream=r_frame_rate", "-of", "default=nw=1:nk=1", input], log: out, flag: flag)
        }
        let rate = ((try? String(contentsOf: probeOut, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard probe == 0, rate.contains("/") else {
            ToolCall.append(c.log, "error: no video stream: \(c.input.path)\n")
            return 1
        }

        if !quiet {
            ToolCall.append(c.log, "  ffgac: mpeg4 q=\(qscale) gop=\(gop) +forcemv+nopimb | ffedit: mv script seed=\(seed) "
                            + "amount=\(amount) | ffmpeg: lossless re-encode\n")
        }
        // jq -cn --argjson seed "$SEED" --argjson amount "$AMOUNT" '{seed:$seed,amount:$amount}'
        let sp = JQ.object([("seed", c.params["seed"] ?? .int(1)), ("amount", c.params["amount"] ?? .int(8))])
        let input = c.input.path, output = c.output.path, scriptPath = script.path
        return try await PipeChain.run([
            PipeChain.Stage(tool: .ffgac, argv: { _, out in
                ["ffgac", "-hide_banner", "-nostdin", "-loglevel", level, "-i", input, "-an",
                 "-flags", "+bitexact", "-fflags", "+bitexact",
                 "-mpv_flags", "+forcemv+nopimb", "-qscale:v", qscale, "-g", gop,
                 "-vcodec", "mpeg4", "-f", "m4v", out!]
            }, log: c.log),
            // -t is ffedit's bitexact/test mode; its stderr goes to /dev/null in the pipeline.
            PipeChain.Stage(tool: .ffedit, argv: { inp, out in
                ["ffedit", "-t", "-i", inp!, "-f", "mv", "-s", scriptPath, "-sp", sp, "-o", out!]
            }, log: nil),
            // gb_ffmpeg -f m4v -r "$RATE" -i - -- -c:v ffvhuff -y "$OUTPUT"
            PipeChain.Stage(tool: .ffmpeg, argv: { inp, _ in
                ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", level, "-f", "m4v", "-r", rate, "-i", inp!,
                 "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1", "-map_chapters", "-1",
                 "-c:v", "ffvhuff", "-threads:v", "2", "-y", output]
            }, log: c.log),
        ], log: c.log)
    }
}

extension [String: ParamValue] {
    /// The value as the step's `GB_P_*` variable renders it.
    func rendered(_ key: String, default fallback: String = "") -> String {
        self[key]?.rendered ?? fallback
    }
}

/// The compact JSON jq prints for scalar params.
enum JQ {
    static func object(_ fields: [(String, ParamValue?)]) -> String {
        "{" + fields.map { "\(string($0.0)):\(value($0.1))" }.joined(separator: ",") + "}"
    }

    static func value(_ v: ParamValue?) -> String {
        switch v {
        case nil: "null"
        case .int(let i): String(i)
        case .float(let d):
            d.isFinite && d == d.rounded() && abs(d) < 1e17 ? String(Int64(d)) : String(d)
        case .bool(let b): b ? "true" : "false"
        case .string(let s): string(s)
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20 || u.value == 0x7f: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
