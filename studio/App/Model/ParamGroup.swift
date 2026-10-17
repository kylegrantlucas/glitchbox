import VideobedKit

/// Params sharing an inspector section, in manifest order.
struct ParamGroup: Identifiable {
    let name: String
    let params: [ParamSpec]

    var id: String { name }

    /// Groups in order of first appearance; ungrouped params form "Parameters".
    static func groups(of plugin: PluginManifest) -> [ParamGroup] {
        var order: [String] = []
        var members: [String: [ParamSpec]] = [:]
        for spec in plugin.params {
            let name = spec.group?.isEmpty == false ? spec.group! : "Parameters"
            if members[name] == nil { order.append(name) }
            members[name, default: []].append(spec)
        }
        return order.map { ParamGroup(name: $0, params: members[$0]!) }
    }
}
