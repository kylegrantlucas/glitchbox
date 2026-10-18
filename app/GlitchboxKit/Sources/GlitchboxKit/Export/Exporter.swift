import Foundation

/// Renders a chain (a cache hit when it already exists), then encodes and muxes the final
/// layer with ffmpeg.
///
/// Output goes to a hidden partial next to the destination and replaces it on success.
/// Everything runs in the calling task: cancelling it kills ffmpeg's process group, and the
/// call returns (throwing `CancellationError`) only once the partial is deleted.
/// Logs live in `<cache>/exports/<id>/`, kept only when ffmpeg fails.
public struct Exporter: Sendable {
    public let env: ToolEnvironment
    public let workspace: Workspace

    public init(env: ToolEnvironment, workspace: Workspace) {
        self.env = env; self.workspace = workspace
    }

    public var exportsDir: URL { workspace.cache.appending(path: "exports", directoryHint: .isDirectory) }

    /// Renders `layers` over `source` with `render`, then encodes to `destination`.
    @discardableResult
    public func export(source: URL, layers: [LayerSpec], render: RenderSettings, settings: ExportSettings,
                       to destination: URL, events: @escaping @Sendable (ExportEvent) -> Void) async throws -> URL {
        let enabled = layers.indices.filter { layers[$0].enabled }
        // Resolve a chosen audio file before the (possibly long) render, and only when the
        // format carries audio.
        var audioFile: URL?
        if settings.format.hasAudio, case .file(let path) = settings.audio {
            guard FileManager.default.fileExists(atPath: path) else { throw ExportError.missingAudioFile(path) }
            audioFile = URL(filePath: path)
        }
        let (final, sourceAudio) = try await Renderer(env: env, workspace: workspace)
            .render(source: source, layers: layers, settings: render) { event in
                if case .layerStarted(let index, let plugin) = event {
                    let k = index < 0 ? 0 : (enabled.firstIndex(of: index) ?? 0) + 1
                    events(.rendering(layer: k, of: enabled.count, plugin: plugin))
                }
            }

        guard let sourceVideo = try await MediaProbe.probe(source, env: env).video else { throw ExportError.noVideo(source) }
        let audio: ExportPlan.AudioInput?
        switch settings.audio {
        case .none:
            audio = nil
        case .source:
            audio = sourceAudio.map { .source($0) }
        case .file:
            audio = audioFile.map { .file($0) }
        }
        let url = try await encode(input: final.output, sourceTags: ColorTags.resolve(sourceVideo), audio: audio,
                                   settings: settings, to: destination) { events(.encoding($0)) }
        events(.finished(url))
        return url
    }

    /// Encodes `input` to `destination`; returns `destination`. Audio is fitted to the
    /// input's length.
    public func encode(input: URL, sourceTags: ColorTags, audio: ExportPlan.AudioInput?, settings: ExportSettings,
                       to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let fm = FileManager.default
        let probe = try await MediaProbe.probe(input, env: env)
        guard let video = probe.video else { throw ExportError.noVideo(input) }
        guard let ffmpeg = env.which("ffmpeg") else { throw RenderError.commandNotFound(plugin: "export", command: "ffmpeg") }

        let job = exportsDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: job, withIntermediateDirectories: true)
        let log = job.appending(path: "log.txt")
        fm.createFile(atPath: log.path, contents: nil)
        let progressFile = job.appending(path: "progress.txt")
        let tag = String(format: "%08x", UInt32.random(in: .min ... .max))
        let partial: URL
        if settings.format.isSequence {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            partial = destination.appending(path: ".glitchbox-partial-\(tag)", directoryHint: .isDirectory)
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        } else {
            let stem = destination.deletingPathExtension().lastPathComponent
            partial = destination.deletingLastPathComponent()
                .appending(path: ".\(stem).partial-\(tag).\(destination.pathExtension)")
        }

        let args = ExportPlan.arguments(input: input, video: video, duration: probe.duration, sourceTags: sourceTags,
                                        audio: audio, settings: settings, output: partial, progress: progressFile)
        LayerRunner.append(log, "ffmpeg \(args.map(LayerRunner.shellQuote).joined(separator: " "))\n")
        do {
            let code = try await runPolling(ffmpeg, args, cwd: job, log: log, progressFile: progressFile,
                                            duration: probe.duration, progress: progress)
            guard code == 0, fm.fileExists(atPath: partial.path) else {
                throw ExportError.encodeFailed(code: code, log: log, tail: LayerRunner.tail(log, lines: 20))
            }
            if settings.format.isSequence {
                try replaceSequence(in: destination, with: partial)
            } else {
                try Self.replace(destination, with: partial)
            }
        } catch {
            try? fm.removeItem(at: partial)
            if !(error is ExportError) { try? fm.removeItem(at: job) }
            throw error
        }
        try? fm.removeItem(at: job)
        progress(1)
        return destination
    }

    /// Writes one PNG of the frame at `time` seconds in `output` (a layer's `out.mkv`).
    public func exportFrame(of output: URL, at time: Double, sourceTags: ColorTags, to destination: URL) async throws {
        let fm = FileManager.default
        guard let video = try await MediaProbe.probe(output, env: env).video else { throw ExportError.noVideo(output) }
        guard let ffmpeg = env.which("ffmpeg") else { throw RenderError.commandNotFound(plugin: "export", command: "ffmpeg") }
        let job = exportsDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: job, withIntermediateDirectories: true)
        let log = job.appending(path: "log.txt")
        let stem = destination.deletingPathExtension().lastPathComponent
        let partial = destination.deletingLastPathComponent()
            .appending(path: ".\(stem).partial-\(String(format: "%08x", UInt32.random(in: .min ... .max))).png")
        let args = ExportPlan.frameArguments(input: output, video: video, sourceTags: sourceTags, time: time, output: partial)
        do {
            let code = try await Spawner.run(executable: ffmpeg, arguments: args, environment: env.variables, cwd: job, log: log)
            guard code == 0, fm.fileExists(atPath: partial.path) else {
                throw ExportError.encodeFailed(code: code, log: log, tail: LayerRunner.tail(log, lines: 20))
            }
            try Self.replace(destination, with: partial)
        } catch {
            try? fm.removeItem(at: partial)
            if !(error is ExportError) { try? fm.removeItem(at: job) }
            throw error
        }
        try? fm.removeItem(at: job)
    }

    /// Runs ffmpeg while reading its `-progress` file every 250 ms.
    private func runPolling(_ ffmpeg: URL, _ args: [String], cwd: URL, log: URL, progressFile: URL,
                            duration: Double?, progress: @escaping @Sendable (Double?) -> Void) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask {
                try await Spawner.run(executable: ffmpeg, arguments: args, environment: env.variables, cwd: cwd, log: log)
            }
            group.addTask {
                var last: Double?? = .none
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let text = try? String(contentsOf: progressFile, encoding: .utf8) else { continue }
                    let f = ExportProgress.parse(text).fraction(of: duration)
                    if last != .some(f) { progress(f); last = .some(f) }
                }
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let code = result { return code }
            }
            return -1
        }
    }

    private static func replace(_ destination: URL, with partial: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: destination)
        }
    }

    /// Replaces a previous sequence's frames and audio in `dir`; other files stay.
    private func replaceSequence(in dir: URL, with partial: URL) throws {
        let fm = FileManager.default
        let isOurs = { (name: String) in
            name == ExportPlan.sequenceAudioName
                || name.wholeMatch(of: /frame_\d{6}\.png/) != nil
        }
        for name in try fm.contentsOfDirectory(atPath: dir.path) where isOurs(name) {
            try fm.removeItem(at: dir.appending(path: name))
        }
        for name in try fm.contentsOfDirectory(atPath: partial.path) {
            try fm.moveItem(at: partial.appending(path: name), to: dir.appending(path: name))
        }
        try fm.removeItem(at: partial)
    }
}
