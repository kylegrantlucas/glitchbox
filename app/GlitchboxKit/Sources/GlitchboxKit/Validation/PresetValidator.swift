import Foundation

/// Checks the library's chain presets and plugin presets against its plugins. An undecodable
/// preset is otherwise dropped silently on load, and a wrong key or value only warns at render.
public enum PresetValidator {
    /// Every effective chain preset and plugin preset of `ws` with its issues (empty = valid), sorted by library-relative path.
    public static func validate(_ ws: Workspace) -> [(path: String, issues: [ValidationIssue])] {
        let plugins = Dictionary(ws.loadPlugins().plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var results: [(path: String, issues: [ValidationIssue])] = []
        for file in ws.overlaidJSON(in: "presets/chains") {
            let issues = decoded(ChainPreset.self, file) { chain(ws, $0, fileName: file.lastPathComponent, plugins: plugins) }
            results.append(("presets/chains/\(file.lastPathComponent)", issues.map(ValidationIssue.init)))
        }
        for folder in ws.pluginPresetFolders() {
            for file in ws.overlaidJSON(in: "presets/plugins/\(folder)") {
                let issues = decoded(PluginPreset.self, file) {
                    pluginPreset(ws, $0, fileName: file.lastPathComponent, folder: folder, manifest: plugins[folder])
                }
                results.append(("presets/plugins/\(folder)/\(file.lastPathComponent)", issues.map(ValidationIssue.init)))
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static func decoded<T: Decodable>(_ type: T.Type, _ file: URL, check: (T) -> [String]) -> [String] {
        do {
            return check(try JSONDecoder().decode(type, from: Data(contentsOf: file)))
        } catch {
            return ["cannot decode: \(Workspace.describe(error))"]
        }
    }

    /// Schema and file-name issues shared by both preset kinds.
    private static func header(schema: Int, name: String, fileName: String) -> [String] {
        var issues: [String] = []
        if schema != 1 { issues.append("schema must be 1 (got \(schema))") }
        if let slug = try? Slug.slug(name) {
            if fileName != "\(slug).json" { issues.append("file name '\(fileName)' must be '\(slug).json'") }
        } else {
            issues.append("name must contain a letter or digit")
        }
        return issues
    }

    private static func chain(_ ws: Workspace, _ preset: ChainPreset, fileName: String,
                              plugins: [String: PluginManifest]) -> [String] {
        var issues = header(schema: preset.schema, name: preset.name, fileName: fileName)
        if preset.layers.isEmpty { issues.append("layers must not be empty") }
        let firstEnabled = preset.layers.firstIndex(where: \.enabled)
        for (i, layer) in preset.layers.enumerated() {
            let tag = "layer \(i + 1)"
            guard let manifest = plugins[layer.plugin] else {
                issues.append("\(tag): unknown plugin '\(layer.plugin)'"); continue
            }
            issues += ws.resolveParams(layer.params, for: manifest).warnings.map { "\(tag): \($0)" }
            if manifest.input == .still, layer.enabled, i != firstEnabled {
                issues.append("\(tag): '\(layer.plugin)' reads the still source and must be the first layer")
            }
        }
        return issues
    }

    private static func pluginPreset(_ ws: Workspace, _ preset: PluginPreset, fileName: String, folder: String,
                                     manifest: PluginManifest?) -> [String] {
        var issues = header(schema: preset.schema, name: preset.name, fileName: fileName)
        if preset.plugin != folder { issues.append("plugin '\(preset.plugin)' must match its folder '\(folder)'") }
        if let manifest {
            issues += ws.resolveParams(preset.params, for: manifest).warnings
        } else {
            issues.append("unknown plugin '\(folder)'")
        }
        return issues
    }
}
