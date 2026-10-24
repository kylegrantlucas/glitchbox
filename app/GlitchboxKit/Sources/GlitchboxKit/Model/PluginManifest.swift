public struct PluginManifest: Codable, Hashable, Sendable, Identifiable {
    public var schema: Int
    public var id: String
    public var name: String
    public var summary: String
    public var requires: [String]
    public var assets: [String]
    public var params: [ParamSpec]
    public var steps: [PluginStep]
    public var input: PluginInput?

    public init(schema: Int = 1, id: String, name: String, summary: String = "",
                requires: [String] = [], assets: [String] = [],
                params: [ParamSpec] = [], steps: [PluginStep] = [], input: PluginInput? = nil) {
        self.schema = schema; self.id = id; self.name = name; self.summary = summary
        self.requires = requires; self.assets = assets; self.params = params; self.steps = steps
        self.input = input
    }

    public func defaults() -> [String: ParamValue] {
        Dictionary(params.map { ($0.key, $0.default) }, uniquingKeysWith: { a, _ in a })
    }

    public func spec(_ key: String) -> ParamSpec? { params.first { $0.key == key } }

    /// Whether `spec` is shown for `values` (missing keys read as defaults): every
    /// `visibleWhen` param must hold a listed value and itself be visible.
    public func isVisible(_ spec: ParamSpec, values: [String: ParamValue]) -> Bool {
        isVisible(spec, values: values, visiting: [])
    }

    private func isVisible(_ spec: ParamSpec, values: [String: ParamValue], visiting: Set<String>) -> Bool {
        guard let conditions = spec.visibleWhen else { return true }
        guard !visiting.contains(spec.key) else { return false }
        for (key, allowed) in conditions {
            guard let control = self.spec(key) else { return false }
            let value = values[key] ?? control.default
            guard allowed.contains(where: { control.coerce($0) == value }),
                  isVisible(control, values: values, visiting: visiting.union([spec.key])) else { return false }
        }
        return true
    }
}
