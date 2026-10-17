import Foundation
import Testing
@testable import GlitchboxKit

final class WorkspaceOverlayTests {
    let dir: URL
    let ws: Workspace

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "gbw-\(UUID().uuidString)", directoryHint: .isDirectory)
        ws = Workspace(base: dir.appending(path: "base"), user: dir.appending(path: "user"), cache: dir.appending(path: "cache"))
        try FileManager.default.createDirectory(at: ws.base.appending(path: "plugins"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func manifest(_ id: String, _ name: String) -> PluginManifest {
        PluginManifest(id: id, name: name, steps: [PluginStep(name: "go", argv: ["true"])])
    }

    func names() -> [String: String] {
        Dictionary(uniqueKeysWithValues: ws.loadPlugins().plugins.map { ($0.id, $0.name) })
    }

    @Test func userPluginWinsAndDeleteRevertsToBuiltin() throws {
        try Workspace.write(manifest("demo", "Built-in"), to: ws.base.appending(path: "plugins/demo.json"))
        try Workspace.write(manifest("solo", "Solo"), to: ws.base.appending(path: "plugins/solo.json"))
        try ws.savePlugin(manifest("demo", "Mine"))
        try ws.savePlugin(manifest("custom", "Custom"))

        #expect(FileManager.default.fileExists(atPath: ws.user.appending(path: "plugins/demo.json").path))
        #expect(names() == ["demo": "Mine", "custom": "Custom", "solo": "Solo"])
        #expect(ws.pluginOrigin(id: "demo") == .overridden)
        #expect(ws.pluginOrigin(id: "custom") == .user)
        #expect(ws.pluginOrigin(id: "solo") == .builtin)

        #expect(throws: WorkspaceError.builtin(path: "plugins/solo.json")) { try self.ws.deletePlugin(id: "solo") }
        #expect(FileManager.default.fileExists(atPath: ws.base.appending(path: "plugins/solo.json").path))

        try ws.deletePlugin(id: "demo")
        try ws.deletePlugin(id: "custom")
        #expect(names() == ["demo": "Built-in", "solo": "Solo"])
        #expect(ws.pluginOrigin(id: "demo") == .builtin)
        #expect(ws.pluginOrigin(id: "custom") == nil)
    }

    @Test func chainPresetsOverlayByName() throws {
        let builtin = ChainPreset(name: "Analog → Mosh", layers: [])
        try Workspace.write(builtin, to: ws.base.appending(path: "presets/chains/analog-mosh.json"))
        let mine = ChainPreset(name: "Analog → Mosh", layers: [LayerSpec(plugin: "demo", enabled: true, params: [:])])
        try ws.saveChainPreset(mine)

        #expect(ws.loadChainPresets() == [mine])
        #expect(ws.chainPresetOrigin(name: "Analog → Mosh") == .overridden)
        try ws.deleteChainPreset(name: "Analog → Mosh")
        #expect(ws.loadChainPresets() == [builtin])
        #expect(throws: WorkspaceError.builtin(path: "presets/chains/analog-mosh.json")) {
            try self.ws.deleteChainPreset(name: "Analog → Mosh")
        }
    }

    @Test func relativeFilesResolveUserFirstThenBase() throws {
        for url in [ws.base.appending(path: "media/a.wav"), ws.base.appending(path: "media/b.wav"), ws.user.appending(path: "media/a.wav")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("pcm".utf8).write(to: url)
        }
        #expect(ws.resolveFile("media/a.wav").path == ws.user.appending(path: "media/a.wav").path)
        #expect(ws.resolveFile("media/b.wav").path == ws.base.appending(path: "media/b.wav").path)
        #expect(ws.resolveFile("/elsewhere/c.wav").path == "/elsewhere/c.wav")

        #expect(ws.storedFileValue(ws.user.appending(path: "media/a.wav")) == "media/a.wav")
        #expect(ws.storedFileValue(ws.base.appending(path: "media/b.wav")) == "media/b.wav")
        #expect(ws.storedFileValue(URL(filePath: "/elsewhere/c.wav")) == "/elsewhere/c.wav")
    }
}
