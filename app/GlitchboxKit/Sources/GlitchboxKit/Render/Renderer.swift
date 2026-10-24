import Foundation

/// Renders a source through a chain of plugin layers.
public struct Renderer: Sendable {
    public let env: ToolEnvironment
    public let workspace: Workspace

    public init(env: ToolEnvironment, workspace: Workspace) {
        self.env = env; self.workspace = workspace
    }

    /// Cancelling the consuming task cancels the render and kills running steps. The stream
    /// ends at cancellation without waiting for that cleanup; use `render(…emit:)` to wait.
    public func render(source: URL, layers: [LayerSpec], settings: RenderSettings) -> AsyncThrowingStream<RenderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await render(source: source, layers: layers, settings: settings) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Renders in the calling task and returns what `.finished` carries. On cancellation it
    /// returns only after running steps are killed and their partial outputs removed.
    @discardableResult
    public func render(source: URL, layers: [LayerSpec], settings: RenderSettings,
                       emit: @Sendable (RenderEvent) -> Void) async throws -> (output: LayerOutput, sourceAudio: URL?) {
        let plugins = Dictionary(workspace.loadPlugins().plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var resolved: [(Int, PluginManifest, [String: ParamValue])] = []
        for (i, layer) in layers.enumerated() where layer.enabled {
            guard let m = plugins[layer.plugin] else {
                throw RenderFailure(index: i, plugin: layer.plugin, underlying: RenderError.unknownPlugin(layer.plugin))
            }
            resolved.append((i, m, workspace.resolveParams(layer.params, for: m).values))
        }

        let runner = LayerRunner(env: env, workspace: workspace)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RenderFailure(index: -1, plugin: "source", underlying: RenderError.missingSource(source))
        }
        let still = SourcePrep.isStill(source)
        for (pos, (i, m, _)) in resolved.enumerated() where m.input == .still {
            guard pos == 0 else {
                throw RenderFailure(index: i, plugin: m.id, underlying: RenderError.stillInputNotFirst(plugin: m.id))
            }
            guard still else {
                throw RenderFailure(index: i, plugin: m.id, underlying: RenderError.needsStillSource(plugin: m.id))
            }
        }
        let sourceKey: String
        let probe: MediaProbe
        let video: MediaProbe.Video
        do {
            sourceKey = "file:" + (try Hashing.sha256Hex(fileAt: source))
            probe = try await MediaProbe.probe(source, env: env)
            guard let v = probe.video else { throw ExportError.noVideo(source) }
            video = v
        } catch {
            throw Self.attribute(error, index: -1, plugin: "source")
        }

        // A still-input first layer turns the still into a clip, which source prep then
        // normalizes like a video at the still's rate and size (so it passes through unscaled),
        // keeping the still's colour tags: export and frame export tag from the source probe.
        var prepInput = source
        var prepKey = sourceKey
        let sourceManifest: PluginManifest
        let motion = resolved.first.flatMap { $0.1.input == .still ? $0 : nil }
        if let (i, m, params) = motion {
            emit(.layerStarted(index: i, plugin: m.id))
            let out: LayerOutput
            let clip: MediaProbe.Video
            do {
                out = try await runner.run(manifest: m, params: params, input: source, parentKey: sourceKey,
                                           still: SourcePrep.stillTarget(settings: settings, video: video),
                                           onStep: { emit(.step(index: i, step: $0, of: $1, name: $2, log: $3)) })
                guard let v = try await MediaProbe.probe(out.output, env: env).video else {
                    throw ExportError.noVideo(out.output)
                }
                clip = v
            } catch {
                throw Self.attribute(error, index: i, plugin: m.id)
            }
            emit(.layerFinished(index: i, out))
            prepInput = out.output
            prepKey = out.key
            let prep = RenderSettings(fps: SourcePrep.frameRate(settings: settings, video: video, still: true))
            sourceManifest = SourcePrep.manifest(settings: prep, video: clip, audio: nil, still: false,
                                                 tags: ColorTags.resolve(video))
        } else {
            sourceManifest = SourcePrep.manifest(settings: settings, video: video, audio: probe.audio, still: still)
        }

        emit(.layerStarted(index: -1, plugin: "source"))
        var current: LayerOutput
        do {
            current = try await runner.run(
                manifest: sourceManifest, params: sourceManifest.defaults(), input: prepInput, parentKey: prepKey,
                onStep: { emit(.step(index: -1, step: $0, of: $1, name: $2, log: $3)) })
        } catch {
            throw Self.attribute(error, index: -1, plugin: "source")
        }
        emit(.layerFinished(index: -1, current))
        let audio = current.dir.appending(path: SourcePrep.audioFileName)
        let sourceAudio = FileManager.default.fileExists(atPath: audio.path) ? audio : nil

        for (i, m, params) in resolved.dropFirst(motion == nil ? 0 : 1) {
            emit(.layerStarted(index: i, plugin: m.id))
            do {
                current = try await runner.run(manifest: m, params: params, input: current.output, parentKey: current.key,
                                               sourceAudio: sourceAudio,
                                               onStep: { emit(.step(index: i, step: $0, of: $1, name: $2, log: $3)) })
            } catch {
                throw Self.attribute(error, index: i, plugin: m.id)
            }
            emit(.layerFinished(index: i, current))
        }
        emit(.finished(current, sourceAudio: sourceAudio))
        return (current, sourceAudio)
    }

    private static func attribute(_ error: any Error, index: Int, plugin: String) -> any Error {
        error is CancellationError ? error : RenderFailure(index: index, plugin: plugin, underlying: error)
    }
}
