import Foundation

/// Plugins and presets stored in a videobed checkout.
public struct Workspace: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var pluginsDir: URL { root.appending(path: "plugins", directoryHint: .isDirectory) }
    public var chainPresetsDir: URL { root.appending(path: "presets/chains", directoryHint: .isDirectory) }
    public func pluginPresetsDir(_ plugin: String) -> URL {
        root.appending(path: "presets/plugins/\(plugin)", directoryHint: .isDirectory)
    }
    public var studioDir: URL { root.appending(path: "out/studio", directoryHint: .isDirectory) }
    public var layersDir: URL { studioDir.appending(path: "layers", directoryHint: .isDirectory) }

    // MARK: JSON

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try encoder().encode(value)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private func jsonFiles(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Plugins

    public func loadPlugins() -> (plugins: [PluginManifest], issues: [String: [ValidationIssue]]) {
        var plugins: [PluginManifest] = []
        var issues: [String: [ValidationIssue]] = [:]
        for file in jsonFiles(in: pluginsDir) {
            let name = file.lastPathComponent
            do {
                let m = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: file))
                let found = ManifestValidator.validate(m, fileName: name, root: root)
                if found.isEmpty { plugins.append(m) } else { issues[name] = found }
            } catch {
                issues[name] = [ValidationIssue("cannot decode: \(Self.describe(error))")]
            }
        }
        return (plugins.sorted { $0.id < $1.id }, issues)
    }

    public func savePlugin(_ m: PluginManifest) throws {
        try Self.write(m, to: pluginsDir.appending(path: "\(m.id).json"))
    }

    public func deletePlugin(id: String) throws {
        try FileManager.default.removeItem(at: pluginsDir.appending(path: "\(id).json"))
    }

    // MARK: Chain presets

    public func loadChainPresets() -> [ChainPreset] {
        jsonFiles(in: chainPresetsDir).compactMap { try? JSONDecoder().decode(ChainPreset.self, from: Data(contentsOf: $0)) }
    }

    public func chainPresetURL(name: String) throws -> URL {
        chainPresetsDir.appending(path: "\(try Slug.slug(name)).json")
    }

    public func saveChainPreset(_ p: ChainPreset) throws {
        try Self.write(p, to: chainPresetURL(name: p.name))
    }

    public func deleteChainPreset(name: String) throws {
        try FileManager.default.removeItem(at: chainPresetURL(name: name))
    }

    // MARK: Plugin presets

    public func loadPluginPresets(plugin: String) -> [PluginPreset] {
        jsonFiles(in: pluginPresetsDir(plugin)).compactMap { try? JSONDecoder().decode(PluginPreset.self, from: Data(contentsOf: $0)) }
    }

    public func pluginPresetURL(plugin: String, name: String) throws -> URL {
        pluginPresetsDir(plugin).appending(path: "\(try Slug.slug(name)).json")
    }

    public func savePluginPreset(_ p: PluginPreset) throws {
        try Self.write(p, to: pluginPresetURL(plugin: p.plugin, name: p.name))
    }

    public func deletePluginPreset(plugin: String, name: String) throws {
        try FileManager.default.removeItem(at: pluginPresetURL(plugin: plugin, name: name))
    }

    // MARK: Params

    /// Fills defaults, drops unknown keys, coerces and clamps given values.
    public func resolveParams(_ given: [String: ParamValue], for m: PluginManifest) -> (values: [String: ParamValue], warnings: [String]) {
        var values = m.defaults()
        var warnings: [String] = []
        for key in given.keys.sorted() {
            let v = given[key]!
            guard let spec = m.spec(key) else {
                warnings.append("\(m.id): dropped unknown param '\(key)'"); continue
            }
            guard let c = spec.coerce(v) else {
                warnings.append("\(m.id): '\(key)' has wrong type, using default"); continue
            }
            let clamped = spec.clamp(c)
            if clamped != c { warnings.append("\(m.id): '\(key)' clamped to \(clamped.rendered)") }
            values[key] = clamped
        }
        return (values, warnings)
    }

    // MARK: Files

    /// Repo-relative when `url` lies under the root, else absolute.
    public func storedFileValue(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    public func resolveFile(_ value: String) -> URL {
        value.hasPrefix("/") ? URL(filePath: value) : root.appending(path: value)
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .keyNotFound(let k, let c): return "missing key '\((c.codingPath + [k]).map(\.stringValue).joined(separator: "."))'"
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
                let path = c.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
            @unknown default: break
            }
        }
        return error.localizedDescription
    }
}
