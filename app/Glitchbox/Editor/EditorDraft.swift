import Foundation
import GlitchboxKit

/// Editable copy of a plugin manifest.
struct EditorDraft: Hashable {
    let id: String
    /// Not editable here; kept so saving a still-input plugin doesn't turn it into a regular layer.
    let input: PluginInput?
    /// Not editable here; kept so saving a built-in plugin doesn't drop it from Simple mode.
    let simple: SimpleInfo?
    var name: String
    var summary: String
    var requiresText: String
    var assetsText: String
    var params: [EditableParam]
    var steps: [EditableStep]

    init(_ m: PluginManifest) {
        id = m.id
        input = m.input
        simple = m.simple
        name = m.name
        summary = m.summary
        requiresText = m.requires.joined(separator: ", ")
        assetsText = m.assets.joined(separator: "\n")
        params = m.params.map(EditableParam.init)
        steps = m.steps.map(EditableStep.init)
    }

    var manifest: PluginManifest {
        let specs = params.map(\.normalized)
        return PluginManifest(
            id: id, name: name, summary: summary,
            requires: EditableParam.list(requiresText),
            assets: assetsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            params: specs,
            steps: steps.map(\.step),
            input: input,
            // Pruned so a renamed or retyped param can't leave a control the editor has no way to fix.
            simple: simple?.pruned(for: specs))
    }
}
