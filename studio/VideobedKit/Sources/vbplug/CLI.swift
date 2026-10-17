import Foundation
import VideobedKit

enum CLI {
    static let usage = """
    usage: vbplug [--root DIR] COMMAND
      list                         plugins and tool availability
      validate [FILE...]           validate plugin manifests (default: plugins/*.json)
      render --chain NAME|FILE [--start S] [--duration D] [--height H|native] [--fps N] INPUT
                                   render a chain; prints the final out.mkv path
      clean                        remove the layer cache (out/studio/layers)
    """

    static func main(_ args: [String]) async -> Int32 {
        var args = args
        var rootArg: String?
        if let i = args.firstIndex(of: "--root") {
            guard i + 1 < args.count else { StandardError.print("error: --root needs a value"); return 1 }
            rootArg = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        guard let command = args.first else { StandardError.print(usage); return 1 }
        if ["-h", "--help", "help"].contains(command) { print(usage); return 0 }
        let rest = Array(args.dropFirst())
        do {
            let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
            let root = try RootLocator.locate(explicit: rootArg, environment: ProcessInfo.processInfo.environment, cwd: cwd)
            let ws = Workspace(root: root)
            switch command {
            case "list": return try await list(ws)
            case "validate": return validate(ws, files: rest, cwd: cwd)
            case "render": return try await render(ws, args: rest, cwd: cwd)
            case "clean":
                try CacheCleaner.clear(root: root)
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

    static func environment(_ ws: Workspace) async throws -> ToolEnvironment {
        try await DevShellResolver.resolve(root: ws.root, forceRefresh: false,
                                           progressLog: DevShellResolver.progressLog(root: ws.root))
    }

    static func list(_ ws: Workspace) async throws -> Int32 {
        let env = try await environment(ws)
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
        let urls: [URL]
        if files.isEmpty {
            let all = (try? FileManager.default.contentsOfDirectory(at: ws.pluginsDir, includingPropertiesForKeys: nil)) ?? []
            urls = all.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            urls = files.map { URL(filePath: $0, relativeTo: cwd).standardizedFileURL }
        }
        var failed = false
        for url in urls {
            let label = ws.storedFileValue(url)
            let issues: [ValidationIssue]
            do {
                let m = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
                issues = ManifestValidator.validate(m, fileName: url.lastPathComponent, root: ws.root)
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

    static func render(_ ws: Workspace, args: [String], cwd: URL) async throws -> Int32 {
        var chainArg: String?
        var settings = RenderSettings()
        var input: String?
        var i = 0
        func value() throws -> String {
            guard i + 1 < args.count else { throw CLIError("\(args[i]) needs a value") }
            i += 1
            return args[i]
        }
        func number(_ s: String, _ flag: String) throws -> Double {
            guard let d = Double(s), d >= 0 else { throw CLIError("\(flag): expected a non-negative number, got '\(s)'") }
            return d
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--chain": chainArg = try value()
            case "--start": settings.start = try number(try value(), a)
            case "--duration": settings.duration = try number(try value(), a)
            case "--height":
                let v = try value()
                if v == "native" { settings.height = nil }
                else if let h = Int(v), h > 0 { settings.height = h }
                else { throw CLIError("--height: expected a positive integer or 'native', got '\(v)'") }
            case "--fps":
                let v = try value()
                guard let f = Int(v), f > 0 else { throw CLIError("--fps: expected a positive integer, got '\(v)'") }
                settings.fps = f
            default:
                if a.hasPrefix("-") { throw CLIError("unknown flag: \(a)") }
                guard input == nil else { throw CLIError("unexpected argument: \(a)") }
                input = a
            }
            i += 1
        }
        guard let chainArg else { throw CLIError("--chain is required") }
        guard let input else { throw CLIError("INPUT is required") }

        let chainURL = chainArg.contains("/") || chainArg.hasSuffix(".json")
            ? URL(filePath: chainArg, relativeTo: cwd).standardizedFileURL
            : ws.chainPresetsDir.appending(path: "\(chainArg).json")
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

        let env = try await environment(ws)
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
        for try await event in renderer.render(source: source, layers: chain.layers, settings: settings) {
            switch event {
            case .layerStarted(let index, let plugin):
                names[index] = plugin
            case .step(let index, let k, let m, let name, _):
                if announced.insert(index).inserted { StandardError.print("\(label(index, names[index] ?? "?")) rendering") }
                StandardError.print("  step \(k)/\(m) \(name)")
            case .layerFinished(let index, let out):
                if out.cached { StandardError.print("\(label(index, names[index] ?? "?")) cached") }
            case .finished(let out):
                print(out.output.path)
            }
        }
        return 0
    }
}
