import Foundation
import GlitchboxKit

enum CLI {
    static let usage = """
    usage: glitchbox [--root DIR] [--toolchain DIR] COMMAND
      list                         plugins and tool availability
      validate [FILE...]           validate plugin manifests (default: every library plugin)
      render --chain NAME|FILE [RENDER] INPUT
                                   render a chain; prints the final out.mkv path
      export --chain NAME|FILE [RENDER] [EXPORT] -o OUT INPUT
                                   render a chain, then encode it; prints OUT
      clean                        remove the layer cache (<cache>/layers)
      env                          print the tool environment for eval "$(glitchbox env)"

    RENDER (render defaults: whole clip, native size, source frame rate snapped to a standard rate)
      --start S --duration D       seconds
      --height H|native            short side in pixels
      --fps N|29.97|30000/1001|source

    EXPORT
      --format h264|hevc|prores|ffv1|gif|png   (default h264; png writes a folder of frames)
      --settings FILE              start from an export.json; later flags override it
      --quality good|high|max      --encoder vt|x264   --crf N   --x264-preset P   --vt-quality 1-100
      --prores lt|422|hq|4444      --container mp4|mov (HEVC; default from OUT's extension)
      --size native|H|WxH          H is the short side; WxH uses --fit fit|fill|stretch (default fit)
      --no-upscale (default)       --upscale
      --audio none|source|FILE     --audio-codec aac|alac|pcm16|pcm24|flac   --audio-bitrate KBPS
      --gif-width N|native  --gif-fps N  --dither none|bayer|floyd_steinberg|sierra2_4a
      --bayer-scale 0-5     --palette global|frame  --loop N (plays N times; 0 loops forever)

    base library: --root, $GLITCHBOX_ROOT, the checkout around the cwd, <exe>/../../Resources/library
    toolchain:    --toolchain, $GLITCHBOX_TOOLCHAIN, <exe>/../.., <root>/build/Glitchbox.app/Contents
    user library: $GLITCHBOX_DATA_DIR, default ~/Library/Application Support/Glitchbox
    cache:        $GLITCHBOX_CACHE_DIR, default ~/Library/Caches/Glitchbox
    """

    static func main(_ args: [String]) async -> Int32 {
        var args = args
        let rootArg: String?
        let toolchainArg: String?
        do {
            rootArg = try take("--root", from: &args)
            toolchainArg = try take("--toolchain", from: &args)
        } catch {
            StandardError.print("error: \(error.localizedDescription)")
            return 1
        }
        guard let command = args.first else { StandardError.print(usage); return 1 }
        if ["-h", "--help", "help"].contains(command) { print(usage); return 0 }
        let rest = Array(args.dropFirst())
        do {
            let process = ProcessInfo.processInfo.environment
            let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
            let executable = Bundle.main.executableURL
            let root = try RootLocator.locate(explicit: rootArg, environment: process, cwd: cwd, executable: executable)
            let ws = Workspace.standard(base: root, environment: process)
            let toolEnvironment = {
                let explicit = toolchainArg.map { URL(filePath: $0, directoryHint: .isDirectory, relativeTo: cwd) }
                let contents = Toolchain.locate(explicit: explicit, environment: process, executable: executable, root: root)
                return try Toolchain.load(contents: contents, cacheDir: ws.cache).toolEnvironment(base: root, parent: process)
            }
            switch command {
            case "list": return list(ws, env: try toolEnvironment())
            case "validate": return validate(ws, files: rest, cwd: cwd)
            case "render": return try await render(ws, args: rest, cwd: cwd, environment: toolEnvironment)
            case "export": return try await export(ws, args: rest, cwd: cwd, environment: toolEnvironment)
            case "clean":
                try ws.clearLayerCache()
                return 0
            case "env":
                guard rest.isEmpty else { throw CLIError("env takes no arguments") }
                print(try toolEnvironment().shellExports(), terminator: "")
                return 0
            default:
                StandardError.print("error: unknown command '\(command)'\n\(usage)")
                return 1
            }
        } catch {
            StandardError.print("error: \(error.localizedDescription)")
            return 1
        }
    }

    /// Removes `flag VALUE` from `args`; nil when absent.
    static func take(_ flag: String, from args: inout [String]) throws -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count else { throw CLIError("\(flag) needs a value") }
        let value = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return value
    }

    static func list(_ ws: Workspace, env: ToolEnvironment) -> Int32 {
        let (plugins, issues) = ws.loadPlugins()
        let width = plugins.map(\.id.count).max() ?? 0
        for p in plugins {
            let missing = env.missing(p.requires)
            let status = missing.isEmpty ? "ok" : "missing: " + missing.joined(separator: ",")
            print("\(p.id.padding(toLength: width, withPad: " ", startingAt: 0))  \(p.name)  \(status)")
        }
        for (file, list) in issues.sorted(by: { $0.key < $1.key }) {
            print("invalid \(file)")
            for i in list { print("  \(i.message)") }
        }
        return 0
    }

    static func validate(_ ws: Workspace, files: [String], cwd: URL) -> Int32 {
        let urls = files.isEmpty
            ? ws.pluginFiles()
            : files.map { URL(filePath: $0, relativeTo: cwd).standardizedFileURL }
        var failed = false
        for url in urls {
            // Base files print library-relative; user and ad-hoc files print absolute.
            let basePrefix = ws.base.path + "/"
            let label = url.path.hasPrefix(basePrefix) ? String(url.path.dropFirst(basePrefix.count)) : url.path
            let issues: [ValidationIssue]
            do {
                let m = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
                issues = ManifestValidator.validate(m, fileName: url.lastPathComponent, roots: [ws.user, ws.base])
            } catch {
                issues = [ValidationIssue("cannot read: \(error.localizedDescription)")]
            }
            if issues.isEmpty {
                print("ok \(label)")
            } else {
                failed = true
                print("invalid \(label)")
                for i in issues { print("  \(i.message)") }
            }
        }
        return failed ? 1 : 0
    }

    /// Flags shared by `render` and `export`, parsed from `args`.
    struct Arguments {
        let args: [String]
        var i = 0
        var chain: String?
        var input: String?
        var settings = RenderSettings()

        init(_ args: [String]) { self.args = args }

        var flag: String { args[i] }

        mutating func value() throws -> String {
            guard i + 1 < args.count else { throw CLIError("\(args[i]) needs a value") }
            i += 1
            return args[i]
        }

        mutating func number(_ flag: String) throws -> Double {
            let s = try value()
            guard let d = Double(s), d >= 0 else { throw CLIError("\(flag): expected a non-negative number, got '\(s)'") }
            return d
        }

        mutating func integer(_ flag: String, in range: ClosedRange<Int> = 1...Int.max) throws -> Int {
            let s = try value()
            guard let n = Int(s), range.contains(n) else { throw CLIError("\(flag): expected an integer in \(range), got '\(s)'") }
            return n
        }

        /// Consumes a render flag or the input path; false for anything else.
        mutating func parseCommon() throws -> Bool {
            let a = flag
            switch a {
            case "--chain": chain = try value()
            case "--start": settings.start = try number(a)
            case "--duration": settings.duration = try number(a)
            case "--height":
                let v = try value()
                if v == "native" { settings.height = nil }
                else if let h = Int(v), h > 0 { settings.height = h }
                else { throw CLIError("--height: expected a positive integer or 'native', got '\(v)'") }
            case "--fps":
                let v = try value()
                if v == "source" { settings.fps = nil }
                else if let r = FrameRate(parsing: v) { settings.fps = r }
                else { throw CLIError("--fps: expected 'source', an integer, a rational like 30000/1001, or a standard rate like 29.97; got '\(v)'") }
            default:
                if a.hasPrefix("-") { return false }
                guard input == nil else { throw CLIError("unexpected argument: \(a)") }
                input = a
            }
            return true
        }
    }

    static func loadChain(_ ws: Workspace, _ chainArg: String?, cwd: URL) throws -> ChainPreset {
        guard let chainArg else { throw CLIError("--chain is required") }
        let chainURL: URL
        if chainArg.contains("/") || chainArg.hasSuffix(".json") {
            chainURL = URL(filePath: chainArg, relativeTo: cwd).standardizedFileURL
        } else if let url = ws.libraryFile("presets/chains/\(chainArg).json") {
            chainURL = url
        } else {
            throw CLIError("no chain preset '\(chainArg)' in \(ws.user.path)/presets/chains or \(ws.base.path)/presets/chains")
        }
        let chain: ChainPreset
        do {
            chain = try JSONDecoder().decode(ChainPreset.self, from: Data(contentsOf: chainURL))
        } catch {
            throw CLIError("cannot read chain \(chainURL.path): \(error.localizedDescription)")
        }
        let plugins = Dictionary(ws.loadPlugins().plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for layer in chain.layers where layer.enabled {
            if let m = plugins[layer.plugin] {
                for w in ws.resolveParams(layer.params, for: m).warnings { StandardError.print("warning: \(w)") }
            }
        }
        return chain
    }

    static func render(_ ws: Workspace, args: [String], cwd: URL,
                       environment: () throws -> ToolEnvironment) async throws -> Int32 {
        var p = Arguments(args)
        while p.i < args.count {
            guard try p.parseCommon() else { throw CLIError("unknown flag: \(p.flag)") }
            p.i += 1
        }
        let chain = try loadChain(ws, p.chain, cwd: cwd)
        guard let input = p.input else { throw CLIError("INPUT is required") }

        let env = try environment()
        let source = URL(filePath: input, relativeTo: cwd).standardizedFileURL
        let enabled = chain.layers.enumerated().filter { $0.element.enabled }.map(\.offset)
        let n = enabled.count
        func label(_ index: Int, _ plugin: String) -> String {
            let ordinal = index < 0 ? 0 : (enabled.firstIndex(of: index) ?? 0) + 1
            return "[\(ordinal)/\(n)] \(plugin)"
        }

        var announced = Set<Int>()
        var names: [Int: String] = [:]
        let renderer = Renderer(env: env, workspace: ws)
        for try await event in renderer.render(source: source, layers: chain.layers, settings: p.settings) {
            switch event {
            case .layerStarted(let index, let plugin):
                names[index] = plugin
            case .step(let index, let k, let m, let name, _):
                if announced.insert(index).inserted { StandardError.print("\(label(index, names[index] ?? "?")) rendering") }
                StandardError.print("  step \(k)/\(m) \(name)")
            case .layerFinished(let index, let out):
                if out.cached { StandardError.print("\(label(index, names[index] ?? "?")) cached") }
            case .finished(let out, _):
                print(out.output.path)
            }
        }
        return 0
    }
}
