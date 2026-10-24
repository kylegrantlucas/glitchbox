import Foundation
import GlitchboxKit

/// Editable copy of a plugin manifest.
struct EditorDraft: Hashable {
    let id: String
    /// Not editable here; kept so saving a still-input plugin doesn't turn it into a regular layer.
    let input: PluginInput?
    var name: String
    var summary: String
    var requiresText: String
    var assetsText: String
    var params: [EditableParam]
    var steps: [EditableStep]

    init(_ m: PluginManifest) {
        id = m.id
        input = m.input
        name = m.name
        summary = m.summary
        requiresText = m.requires.joined(separator: ", ")
        assetsText = m.assets.joined(separator: "\n")
        params = m.params.map(EditableParam.init)
        steps = m.steps.map(EditableStep.init)
    }

    var manifest: PluginManifest {
        PluginManifest(
            id: id, name: name, summary: summary,
            requires: EditableParam.list(requiresText),
            assets: assetsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            params: params.map(\.normalized),
            steps: steps.map(\.step),
            input: input)
    }
}
