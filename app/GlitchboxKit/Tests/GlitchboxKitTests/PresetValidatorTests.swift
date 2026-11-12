import Foundation
import Testing
@testable import GlitchboxKit

final class PresetValidatorTests {
    let dir: URL
    let ws: Workspace

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "gbp-\(UUID().uuidString)", directoryHint: .isDirectory)
        ws = Workspace(base: dir.appending(path: "base"), user: dir.appending(path: "user"), cache: dir.appending(path: "cache"))
        let step = PluginStep(name: "go", argv: ["true"])
        let demo = PluginManifest(id: "demo", name: "Demo", params: [
            ParamSpec(key: "amount", label: "Amount", type: .int, default: .int(4), min: 0, max: 10),
        ], steps: [step])
        let motion = PluginManifest(id: "motion", name: "Motion", steps: [step], input: .still)
        try Workspace.write(demo, to: ws.base.appending(path: "plugins/demo.json"))
        try Workspace.write(motion, to: ws.base.appending(path: "plugins/motion.json"))
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func issues() -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: PresetValidator.validate(ws).map { ($0.path, $0.issues.map(\.message)) })
    }

    @Test func validLibraryHasNoIssues() throws {
        let chain = ChainPreset(name: "Photo → Demo", layers: [
            LayerSpec(plugin: "demo", enabled: false),
            LayerSpec(plugin: "motion"),
            LayerSpec(plugin: "demo", params: ["amount": .int(9)]),
        ], category: "Stills")
        try Workspace.write(chain, to: ws.base.appending(path: "presets/chains/photo-demo.json"))
        try Workspace.write(PluginPreset(name: "Strong", plugin: "demo", params: ["amount": .int(10)]),
                            to: ws.base.appending(path: "presets/plugins/demo/strong.json"))
        try ws.savePluginPreset(PluginPreset(name: "Mine", plugin: "demo", params: [:]))

        let found = PresetValidator.validate(ws)
        #expect(found.map(\.path) == ["presets/chains/photo-demo.json", "presets/plugins/demo/mine.json",
                                      "presets/plugins/demo/strong.json"])
        #expect(found.flatMap(\.issues) == [])
    }

    @Test func chainIssues() throws {
        let chain = ChainPreset(schema: 2, name: "Broken", layers: [
            LayerSpec(plugin: "nope"),
            LayerSpec(plugin: "demo", params: ["amount": .int(99)]),
            LayerSpec(plugin: "motion"),
        ])
        try Workspace.write(chain, to: ws.base.appending(path: "presets/chains/other.json"))
        try Workspace.write(ChainPreset(name: "Empty", layers: []), to: ws.base.appending(path: "presets/chains/empty.json"))
        try Workspace.write(ChainPreset(name: "→", layers: [LayerSpec(plugin: "demo")]),
                            to: ws.base.appending(path: "presets/chains/arrow.json"))

        let found = issues()
        #expect(found["presets/chains/other.json"] == [
            "schema must be 1 (got 2)",
            "file name 'other.json' must be 'broken.json'",
            "layer 1: unknown plugin 'nope'",
            "layer 2: demo: 'amount' clamped to 10",
            "layer 3: 'motion' reads the still source and must be the first layer",
        ])
        #expect(found["presets/chains/empty.json"] == ["layers must not be empty"])
        #expect(found["presets/chains/arrow.json"] == ["name must contain a letter or digit"])
    }

    @Test func pluginPresetIssues() throws {
        try Workspace.write(PluginPreset(name: "Wrong home", plugin: "motion", params: ["bogus": .int(1)]),
                            to: ws.base.appending(path: "presets/plugins/demo/wrong-home.json"))
        try Workspace.write(PluginPreset(name: "Orphan", plugin: "gone", params: [:]),
                            to: ws.base.appending(path: "presets/plugins/gone/orphan.json"))

        let found = issues()
        #expect(found["presets/plugins/demo/wrong-home.json"] == [
            "plugin 'motion' must match its folder 'demo'",
            "demo: dropped unknown param 'bogus'",
        ])
        #expect(found["presets/plugins/gone/orphan.json"] == ["unknown plugin 'gone'"])
    }

    @Test func undecodableFileIsReported() throws {
        let url = ws.base.appending(path: "presets/chains/bad.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schema":1,"name":"Bad"}"#.utf8).write(to: url)
        #expect(issues()["presets/chains/bad.json"] == ["cannot decode: missing key 'layers'"])
    }
}
