import Foundation
import Testing
@testable import GlitchboxKit

/// Still-input placement is checked before any probing, so these need no toolchain.
final class RendererTests {
    let root: URL
    let renderer: Renderer

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "gbk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace(base: root.appending(path: "base"), user: root.appending(path: "user"),
                                  cache: root.appending(path: "cache"))
        try workspace.savePlugin(PluginManifest(id: "motion", name: "Motion",
                                                steps: [PluginStep(name: "go", script: "cp \"$GB_IN\" \"$GB_OUT\"")],
                                                input: .still))
        try workspace.savePlugin(PluginManifest(id: "copy", name: "Copy",
                                                steps: [PluginStep(name: "go", script: "cp \"$GB_IN\" \"$GB_OUT\"")]))
        renderer = Renderer(env: ToolEnvironment(own: ProcessInfo.processInfo.environment, digest: "toolchain-a"),
                            workspace: workspace)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func source(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try Data("not media".utf8).write(to: url)
        return url
    }

    func failure(_ source: URL, _ layers: [LayerSpec]) async throws -> RenderFailure? {
        do {
            try await renderer.render(source: source, layers: layers, settings: RenderSettings(), emit: { _ in })
            return nil
        } catch let f as RenderFailure {
            return f
        }
    }

    @Test func stillInputNeedsAStillSource() async throws {
        let f = try #require(try await failure(source("clip.mp4"), [LayerSpec(plugin: "motion")]))
        #expect(f.index == 0)
        guard case .needsStillSource = f.underlying as? RenderError else {
            Issue.record("unexpected \(f.underlying)")
            return
        }
    }

    @Test func stillInputMustBeFirstEnabled() async throws {
        let still = try source("still.png")
        let f = try #require(try await failure(still, [LayerSpec(plugin: "copy"), LayerSpec(plugin: "motion")]))
        #expect(f.index == 1)
        guard case .stillInputNotFirst = f.underlying as? RenderError else {
            Issue.record("unexpected \(f.underlying)")
            return
        }

        // A disabled layer above doesn't count; the render gets past placement (and then
        // fails on these fake bytes or the missing ffprobe).
        let g = try await failure(still, [LayerSpec(plugin: "copy", enabled: false), LayerSpec(plugin: "motion")])
        if case .stillInputNotFirst = g?.underlying as? RenderError {
            Issue.record("a disabled layer above counted as first")
        }
    }
}
