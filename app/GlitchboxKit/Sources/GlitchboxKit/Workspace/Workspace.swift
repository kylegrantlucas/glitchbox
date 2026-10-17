import Foundation

/// The plugin and preset library: a read-only base root overlaid by a writable user root.
///
/// Entries are identified by their library-relative file (`plugins/<id>.json`,
/// `presets/chains/<slug>.json`, `presets/plugins/<id>/<slug>.json`); a user file
/// shadows the base file with the same path. Saves go to the user root; deletes
/// remove only the user copy.
public struct Workspace: Sendable {
    /// Read-only base library (`Contents/Resources/library`, or the repo checkout in development).
    public let base: URL
    /// Writable user library: `plugins/`, `presets/`, `session.json`.
    public let user: URL
    /// Cache dir: `layers/` and the GStreamer registry.
    public let cache: URL

    public init(base: URL, user: URL, cache: URL) {
        self.base = base.standardizedFileURL
        self.user = user.standardizedFileURL
        self.cache = cache.standardizedFileURL
    }

    /// Base and user roots at their default (or `GLITCHBOX_DATA_DIR`/`GLITCHBOX_CACHE_DIR`) locations.
    public static func standard(base: URL, environment: [String: String]) -> Workspace {
        Workspace(base: base, user: defaultUserDir(environment: environment), cache: defaultCacheDir(environment: environment))
    }

    /// `$GLITCHBOX_DATA_DIR`, else `~/Library/Application Support/Glitchbox`.
    public static func defaultUserDir(environment: [String: String]) -> URL {
        directory(environment["GLITCHBOX_DATA_DIR"], default: .applicationSupportDirectory)
    }

    /// `$GLITCHBOX_CACHE_DIR`, else `~/Library/Caches/Glitchbox`.
    public static func defaultCacheDir(environment: [String: String]) -> URL {
        directory(environment["GLITCHBOX_CACHE_DIR"], default: .cachesDirectory)
    }

    private static func directory(_ override: String?, default dir: FileManager.SearchPathDirectory) -> URL {
        if let override, !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory).standardizedFileURL
        }
        let parent = FileManager.default.urls(for: dir, in: .userDomainMask)[0]
        return parent.appending(path: "Glitchbox", directoryHint: .isDirectory)
    }

    public var layersDir: URL { cache.appending(path: "layers", directoryHint: .isDirectory) }
    public var sessionURL: URL { user.appending(path: "session.json") }

    public func clearLayerCache() throws {
        if FileManager.default.fileExists(atPath: layersDir.path) {
            try FileManager.default.removeItem(at: layersDir)
        }
    }

    // MARK: Overlay

    static func pluginPath(_ id: String) -> String { "plugins/\(id).json" }
    static func chainPresetPath(_ name: String) throws -> String { "presets/chains/\(try Slug.slug(name)).json" }
    static func pluginPresetPath(_ plugin: String, _ name: String) throws -> String {
        "presets/plugins/\(plugin)/\(try Slug.slug(name)).json"
    }

    /// Which roots hold `relativePath`; nil when neither does.
    public func origin(of relativePath: String) -> LibraryOrigin? {
        let fm = FileManager.default
        let inUser = fm.fileExists(atPath: user.appending(path: relativePath).path)
        let inBase = fm.fileExists(atPath: base.appending(path: relativePath).path)
        switch (inUser, inBase) {
        case (true, true): return .overridden
        case (true, false): return .user
        case (false, true): return .builtin
        case (false, false): return nil
        }
    }

    /// The effective file for `relativePath`: the user copy, else the base one.
    public func libraryFile(_ relativePath: String) -> URL? {
        [user, base].map { $0.appending(path: relativePath) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// JSON files in `dir` from both roots, user copies replacing base files of the same name.
    private func overlaidJSON(in dir: String) -> [URL] {
        var byName: [String: URL] = [:]
        for root in [base, user] {
            let files = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: dir, directoryHint: .isDirectory),
                                                                      includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "json" { byName[f.lastPathComponent] = f }
        }
        return byName.keys.sorted().map { byName[$0]! }
    }

    private func save<T: Encodable>(_ value: T, at relativePath: String) throws {
        try Self.write(value, to: user.appending(path: relativePath))
    }

    /// Removes the user copy of `relativePath`; a base-only entry is refused.
    private func removeUserCopy(_ relativePath: String) throws {
        switch origin(of: relativePath) {
        case .user, .overridden: try FileManager.default.removeItem(at: user.appending(path: relativePath))
        case .builtin: throw WorkspaceError.builtin(path: relativePath)
        case nil: throw WorkspaceError.notFound(path: relativePath)
        }
    }

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

    // MARK: Plugins

    /// Effective plugin manifest files by name; a user copy replaces the base file.
    public func pluginFiles() -> [URL] { overlaidJSON(in: "plugins") }

    public func loadPlugins() -> (plugins: [PluginManifest], issues: [String: [ValidationIssue]]) {
        var plugins: [PluginManifest] = []
        var issues: [String: [ValidationIssue]] = [:]
        for file in pluginFiles() {
            let name = file.lastPathComponent
            do {
                let m = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: file))
                let found = ManifestValidator.validate(m, fileName: name, roots: [user, base])
                if found.isEmpty { plugins.append(m) } else { issues[name] = found }
            } catch {
                issues[name] = [ValidationIssue("cannot decode: \(Self.describe(error))")]
            }
        }
        return (plugins.sorted { $0.id < $1.id }, issues)
    }

    public func pluginOrigin(id: String) -> LibraryOrigin? { origin(of: Self.pluginPath(id)) }

    /// The effective manifest file for `id`.
    public func pluginFile(id: String) -> URL? { libraryFile(Self.pluginPath(id)) }

    /// The base library's manifest for `id`, ignoring any user copy.
    public func builtinPlugin(id: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: base.appending(path: Self.pluginPath(id))))
    }

    public func savePlugin(_ m: PluginManifest) throws {
        try save(m, at: Self.pluginPath(m.id))
    }

    /// Deletes a user plugin or reverts an overridden builtin.
    public func deletePlugin(id: String) throws {
        try removeUserCopy(Self.pluginPath(id))
    }

    // MARK: Chain presets

    public func loadChainPresets() -> [ChainPreset] {
        overlaidJSON(in: "presets/chains").compactMap { try? JSONDecoder().decode(ChainPreset.self, from: Data(contentsOf: $0)) }
    }

    /// nil when `name` has no file in either root.
    public func chainPresetOrigin(name: String) -> LibraryOrigin? {
        (try? Self.chainPresetPath(name)).flatMap(origin(of:))
    }

    public func saveChainPreset(_ p: ChainPreset) throws {
        try save(p, at: Self.chainPresetPath(p.name))
    }

    public func deleteChainPreset(name: String) throws {
        try removeUserCopy(Self.chainPresetPath(name))
    }

    // MARK: Plugin presets

    public func loadPluginPresets(plugin: String) -> [PluginPreset] {
        overlaidJSON(in: "presets/plugins/\(plugin)").compactMap { try? JSONDecoder().decode(PluginPreset.self, from: Data(contentsOf: $0)) }
    }

    public func pluginPresetOrigin(plugin: String, name: String) -> LibraryOrigin? {
        (try? Self.pluginPresetPath(plugin, name)).flatMap(origin(of:))
    }

    public func savePluginPreset(_ p: PluginPreset) throws {
        try save(p, at: Self.pluginPresetPath(p.plugin, p.name))
    }

    public func deletePluginPreset(plugin: String, name: String) throws {
        try removeUserCopy(Self.pluginPresetPath(plugin, name))
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

    /// Relative to the user root, else the base root, when `url` lies under one; else absolute.
    public func storedFileValue(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for root in [user, base] {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }

    /// Absolute paths as-is; relative ones under the user root when the file exists there, else the base root.
    public func resolveFile(_ value: String) -> URL {
        if value.hasPrefix("/") { return URL(filePath: value) }
        let mine = user.appending(path: value)
        return FileManager.default.fileExists(atPath: mine.path) ? mine : base.appending(path: value)
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
