import Foundation
import VideobedKit

/// A step row in the editor; argv is edited one argument per line.
struct EditableStep: Identifiable, Hashable {
    enum Mode: String, CaseIterable, Identifiable {
        case argv = "Argv", script = "Script"
        var id: Self { self }
    }

    let id = UUID()
    var name: String
    var mode: Mode
    var argvText: String
    var script: String

    init(_ step: PluginStep) {
        name = step.name
        let argv = step.argv ?? []
        mode = argv.isEmpty && step.script != nil ? .script : .argv
        argvText = argv.joined(separator: "\n")
        script = step.script ?? ""
    }

    var step: PluginStep {
        switch mode {
        case .argv:
            PluginStep(name: name, argv: argvText.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        case .script:
            PluginStep(name: name, script: script)
        }
    }
}
