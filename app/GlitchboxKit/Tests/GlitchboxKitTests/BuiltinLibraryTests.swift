import Foundation
import Testing
@testable import GlitchboxKit

/// The checkout's own `plugins/` and `presets/`: what ships as the built-in library.
struct BuiltinLibraryTests {
    let ws: Workspace

    init() {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let nowhere = FileManager.default.temporaryDirectory.appending(path: "gbl-\(UUID().uuidString)", directoryHint: .isDirectory)
        ws = Workspace(base: root, user: nowhere.appending(path: "user"), cache: nowhere.appending(path: "cache"))
    }

    @Test func pluginsAreValid() {
        let loaded = ws.loadPlugins()
        #expect(!loaded.plugins.isEmpty)
        #expect(loaded.issues.mapValues { $0.map(\.message) } == [:])
    }

    @Test func presetsAreValid() {
        let found = PresetValidator.validate(ws)
        #expect(!found.isEmpty)
        #expect(found.filter { !$0.issues.isEmpty }.map { "\($0.path): \($0.issues.map(\.message))" } == [])
    }

    /// Simple mode shows a picture for every effect it offers and every built-in look
    /// (`packaging/make-thumbnails.sh` renders them).
    @Test func simpleBrowserHasThumbnails() {
        let effects = ws.loadPlugins().plugins.filter { $0.simple != nil }
        #expect(!effects.isEmpty)
        #expect(effects.filter { ws.effectThumbnail(plugin: $0.id) == nil }.map(\.id) == [])
        let looks = ws.loadChainPresets().filter { $0.category != nil }
        #expect(!looks.isEmpty)
        #expect(looks.filter { ws.lookThumbnail(name: $0.name) == nil }.map(\.name) == [])
    }
}
