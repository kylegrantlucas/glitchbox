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
             "-c:v", "ffvhuff", "-y", output]
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
/// MPEG-4 forced-MV encode → `ffedit -t` with `scripts/mv-shuffle.js` → lossless re-encode,
/// through files in the step's work directory.
struct MVMangleStep: NativeStep {
    func run(_ c: NativeStepContext) async throws -> Int32 {
        let fm = FileManager.default
        let quiet = !(c.environment["GB_QUIET"] ?? "").isEmpty
        func say(_ s: String) { if !quiet { ToolCall.append(c.log, "  \(s)\n") } }
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
        let outDir = c.environment["GB_OUT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? c.work.appending(path: "gb", directoryHint: .isDirectory)
        let runDir = outDir.appending(path: "mv-mangle", directoryHint: .isDirectory)
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        let enc = runDir.appending(path: "stage1-mpeg4.avi").path
        let glitched = runDir.appending(path: "stage2-glitched.avi").path

        say("ffgac: mpeg4 q=\(qscale) gop=\(gop) +forcemv+nopimb")
        var code = try await ToolCall.cancellable("ffgac") { [log = c.log.path, input = c.input.path] flag in
            ToolCall.call(.ffgac, ["ffgac", "-hide_banner", "-nostdin", "-loglevel", level,
                                   "-i", input, "-an",
                                   "-flags", "+bitexact", "-fflags", "+bitexact",
                                   "-mpv_flags", "+forcemv+nopimb", "-qscale:v", qscale, "-g", gop,
                                   "-vcodec", "mpeg4", "-f", "avi", "-y", enc], log: log, flag: flag)
        }
        guard code == 0 else { return code }

        say("ffedit: mv script seed=\(seed) amount=\(amount)")
        // jq -cn --argjson seed "$SEED" --argjson amount "$AMOUNT" '{seed:$seed,amount:$amount}';
        // ffedit's stderr goes to /dev/null in the pipeline.
        let sp = JQ.object([("seed", c.params["seed"] ?? .int(1)), ("amount", c.params["amount"] ?? .int(8))])
        code = try await ToolCall.cancellable("ffedit") { [script = script.path] flag in
            ToolCall.call(.ffedit, ["ffedit", "-t", "-i", enc, "-f", "mv", "-s", script, "-sp", sp, "-o", glitched],
                          log: nil, flag: flag)
        }
        guard code == 0 else { return code }

        say("ffmpeg: lossless re-encode")
        // gb_ffmpeg -i "$GLITCHED" -- -c:v ffvhuff -y "$OUTPUT"
        return try await ToolCall.cancellable("ffmpeg") { [log = c.log.path, output = c.output.path] flag in
            ToolCall.call(.ffmpeg, ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", level,
                                    "-i", glitched,
                                    "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1",
                                    "-map_chapters", "-1",
                                    "-c:v", "ffvhuff", "-y", output], log: log, flag: flag)
        }
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
