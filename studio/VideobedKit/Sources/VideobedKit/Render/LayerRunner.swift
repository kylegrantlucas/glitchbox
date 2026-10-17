import Foundation

/// Runs one plugin layer into the content-addressed layer cache.
public struct LayerRunner: Sendable {
    public let env: ToolEnvironment
    /// `root/out/studio/layers`.
    public let cacheDir: URL

    public init(env: ToolEnvironment, cacheDir: URL) {
        self.env = env; self.cacheDir = cacheDir
    }

    var root: URL { env.root }

    func resolveFile(_ value: String) -> URL {
        value.hasPrefix("/") ? URL(filePath: value) : root.appending(path: value)
    }

    /// `params` must already be resolved (see `Workspace.resolveParams`).
    /// `sourceAudio` is the source layer's trimmed audio track, when it has one.
    public func run(manifest: PluginManifest, params: [String: ParamValue], input: URL, parentKey: String,
                    sourceAudio: URL? = nil,
                    onStep: @Sendable (_ step: Int, _ of: Int, _ name: String, _ log: URL) -> Void) async throws -> LayerOutput {
        let fm = FileManager.default
        let missing = env.missing(manifest.requires)
        guard missing.isEmpty else { throw RenderError.unavailable(plugin: manifest.id, missing: missing) }

        var rendered: [String: String] = [:]
        var typed: [String: ParamValue] = [:]
        var files: [String: String] = [:]
        for spec in manifest.params {
            let value = params[spec.key] ?? spec.default
            if spec.type == .file {
                let s = value.stringValue ?? ""
                if s.isEmpty, spec.isOptional {
                    rendered[spec.key] = ""
                    typed[spec.key] = .string("")
                    continue
                }
                let url = resolveFile(s)
                guard !s.isEmpty, fm.fileExists(atPath: url.path) else {
                    throw RenderError.missingFile(plugin: manifest.id, param: spec.key)
                }
                files[spec.key] = try Hashing.sha256Hex(fileAt: url)
                rendered[spec.key] = url.path
                typed[spec.key] = .string(url.path)
            } else {
                rendered[spec.key] = value.rendered
                typed[spec.key] = value
            }
        }
        var assets: [String: String] = [:]
        for a in manifest.assets {
            let url = root.appending(path: a)
            guard fm.fileExists(atPath: url.path) else { throw RenderError.missingAsset(plugin: manifest.id, path: a) }
            assets[a] = try Hashing.sha256Hex(fileAt: url)
        }
        let lock = root.appending(path: "flake.lock")
        let envHash = fm.fileExists(atPath: lock.path) ? try Hashing.sha256Hex(fileAt: lock) : "none"

        let components = KeyComponents(parent: parentKey, plugin: manifest, params: params,
                                       files: files, assets: assets, env: envHash)
        let key = Hashing.sha256Hex(CanonicalJSON.data(components))
        let dirName = "\(manifest.id)-\(key.prefix(12))"
        let finalDir = cacheDir.appending(path: dirName, directoryHint: .isDirectory)
        let finalOut = finalDir.appending(path: "out.mkv")
        if fm.fileExists(atPath: finalOut.path), fm.fileExists(atPath: finalDir.appending(path: "manifest.json").path) {
            return LayerOutput(key: key, dir: finalDir, output: finalOut, cached: true)
        }

        let partial = cacheDir.appending(path: "\(dirName).partial-\(String(format: "%08x", UInt32.random(in: .min ... .max)))",
                                         directoryHint: .isDirectory)
        let work = partial.appending(path: "work", directoryHint: .isDirectory)
        let out = partial.appending(path: "out.mkv")
        let log = partial.appending(path: "log.txt")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        fm.createFile(atPath: log.path, contents: nil)
        // Typed resolved params for scripts that build config files (jq-friendly).
        let paramsFile = partial.appending(path: "params.json")
        try CanonicalJSON.data(typed).write(to: paramsFile)
        let audioPath = sourceAudio?.path ?? ""

        var values = ["in": input.path, "out": out.path, "work": work.path, "root": root.path,
                      "params": paramsFile.path, "source_audio": audioPath]
        var stepEnv = env.variables
        stepEnv["VB_IN"] = input.path
        stepEnv["VB_OUT"] = out.path
        stepEnv["VB_WORK"] = work.path
        stepEnv["VB_ROOT"] = root.path
        stepEnv["VB_PARAMS"] = paramsFile.path
        stepEnv["VB_SOURCE_AUDIO"] = audioPath
        stepEnv["VB_OUT_DIR"] = work.appending(path: "vb").path
        for (k, v) in rendered {
            values["p.\(k)"] = v
            stepEnv["VB_P_\(k.uppercased())"] = v
        }

        let started = Date()
        var resolvedSteps: [PluginStep] = []
        do {
            for (i, step) in manifest.steps.enumerated() {
                onStep(i + 1, manifest.steps.count, step.name, log)
                let executable: URL
                let arguments: [String]
                if let argv = step.argv, !argv.isEmpty {
                    let expanded = try argv.map { try TemplateExpander.expand($0, values: values) }
                    guard let exe = env.which(expanded[0]) else {
                        throw RenderError.commandNotFound(plugin: manifest.id, command: expanded[0])
                    }
                    executable = exe
                    arguments = Array(expanded.dropFirst())
                    resolvedSteps.append(PluginStep(name: step.name, argv: expanded))
                    Self.append(log, "== step \(i + 1)/\(manifest.steps.count): \(step.name) ==\n\(expanded.map(Self.shellQuote).joined(separator: " "))\n")
                } else {
                    let script = step.script ?? ""
                    executable = env.which("bash") ?? URL(filePath: "/bin/bash")
                    arguments = ["-euo", "pipefail", "-c", script]
                    resolvedSteps.append(PluginStep(name: step.name, script: script))
                    Self.append(log, "== step \(i + 1)/\(manifest.steps.count): \(step.name) ==\nbash script:\n\(script)\n")
                }
                let code = try await Spawner.run(executable: executable, arguments: arguments,
                                                 environment: stepEnv, cwd: work, log: log)
                if code != 0 {
                    let failedLog = try fail(partial: partial, dirName: dirName)
                    throw RenderError.stepFailed(plugin: manifest.id, step: step.name, code: code,
                                                 log: failedLog, tail: Self.tail(failedLog, lines: 20))
                }
            }
            let size = (try? fm.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
            if size == 0 {
                Self.append(log, "== no output: \(out.path) missing or empty ==\n")
                throw RenderError.noOutput(plugin: manifest.id, log: try fail(partial: partial, dirName: dirName))
            }
        } catch let e as RenderError {
            if case .stepFailed = e {} else if case .noOutput = e {} else { try? fm.removeItem(at: partial) }
            throw e
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        try? fm.removeItem(at: work)
        try? fm.removeItem(at: cacheDir.appending(path: "\(dirName).failed", directoryHint: .isDirectory))
        let iso = ISO8601DateFormatter()
        let record = LayerRecord(components, key: key, output: "out.mkv",
                                 outputSHA256: try Hashing.sha256Hex(fileAt: out), steps: resolvedSteps,
                                 generatedAt: iso.string(from: Date()),
                                 elapsedS: (Date().timeIntervalSince(started) * 1000).rounded() / 1000)
        try Workspace.write(record, to: partial.appending(path: "manifest.json"))
        if fm.fileExists(atPath: finalDir.path) {
            try? fm.removeItem(at: partial)
        } else {
            do {
                try fm.moveItem(at: partial, to: finalDir)
            } catch where fm.fileExists(atPath: finalDir.path) {
                try? fm.removeItem(at: partial)
            }
        }
        return LayerOutput(key: key, dir: finalDir, output: finalOut, cached: false)
    }

    /// Moves `partial` to `<dirName>.failed`, replacing an older failure; returns its log.
    private func fail(partial: URL, dirName: String) throws -> URL {
        let fm = FileManager.default
        let failed = cacheDir.appending(path: "\(dirName).failed", directoryHint: .isDirectory)
        try? fm.removeItem(at: failed)
        try fm.moveItem(at: partial, to: failed)
        return failed.appending(path: "log.txt")
    }

    static func append(_ url: URL, _ text: String) {
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(text.utf8))
    }

    static func tail(_ url: URL, lines: Int) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while all.last == "" { all.removeLast() }
        return Array(all.suffix(lines))
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:+,@%".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
