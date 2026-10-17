import Foundation

/// Renders a source through a chain of plugin layers.
public struct Renderer: Sendable {
    public let env: ToolEnvironment
    public let workspace: Workspace

    public init(env: ToolEnvironment, workspace: Workspace) {
        self.env = env; self.workspace = workspace
    }

    /// Cancelling the consuming task cancels the render and kills running steps.
    public func render(source: URL, layers: [LayerSpec], settings: RenderSettings) -> AsyncThrowingStream<RenderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(source: source, layers: layers, settings: settings) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(source: URL, layers: [LayerSpec], settings: RenderSettings,
                     emit: @Sendable (RenderEvent) -> Void) async throws {
        let plugins = Dictionary(workspace.loadPlugins().plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var resolved: [(Int, PluginManifest, [String: ParamValue])] = []
        for (i, layer) in layers.enumerated() where layer.enabled {
            guard let m = plugins[layer.plugin] else {
                throw RenderFailure(index: i, plugin: layer.plugin, underlying: RenderError.unknownPlugin(layer.plugin))
            }
            resolved.append((i, m, workspace.resolveParams(layer.params, for: m).values))
        }

        let runner = LayerRunner(env: env, cacheDir: workspace.layersDir)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RenderFailure(index: -1, plugin: "source", underlying: RenderError.missingSource(source))
        }
        let sourceManifest = SourcePrep.manifest(settings: settings, still: SourcePrep.isStill(source))
        emit(.layerStarted(index: -1, plugin: "source"))
        var current: LayerOutput
        do {
            current = try await runner.run(
                manifest: sourceManifest, params: sourceManifest.defaults(), input: source,
                parentKey: "file:" + Hashing.sha256Hex(fileAt: source),
                onStep: { emit(.step(index: -1, step: $0, of: $1, name: $2, log: $3)) })
        } catch {
            throw Self.attribute(error, index: -1, plugin: "source")
        }
        emit(.layerFinished(index: -1, current))
        let audio = current.dir.appending(path: SourcePrep.audioFileName)
        let sourceAudio = FileManager.default.fileExists(atPath: audio.path) ? audio : nil

        for (i, m, params) in resolved {
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
        emit(.finished(current))
    }

    private static func attribute(_ error: any Error, index: Int, plugin: String) -> any Error {
        error is CancellationError ? error : RenderFailure(index: index, plugin: plugin, underlying: error)
    }
}
