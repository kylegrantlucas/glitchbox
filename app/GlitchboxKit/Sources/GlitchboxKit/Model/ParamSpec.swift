import Foundation

public struct ParamSpec: Codable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var type: ParamType
    public var `default`: ParamValue
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var options: [String]?
    public var extensions: [String]?
    public var help: String?
    /// Inspector section; params sharing a group are shown together.
    public var group: String?
    /// Display names for enum `options`, index-aligned.
    public var labels: [String]?
    /// Slider mapping for int/float params; nil means linear.
    public var scale: ParamScale?
    /// File params only: an empty value is allowed and passed as "".
    public var optional: Bool?
    /// Shown in the inspector only while each named param holds one of the listed values
    /// (all keys must match). Hidden params still keep and pass their values.
    public var visibleWhen: [String: [ParamValue]]?

    public init(key: String, label: String, type: ParamType, default: ParamValue,
                min: Double? = nil, max: Double? = nil, step: Double? = nil,
                options: [String]? = nil, extensions: [String]? = nil, help: String? = nil,
                group: String? = nil, labels: [String]? = nil, scale: ParamScale? = nil, optional: Bool? = nil,
                visibleWhen: [String: [ParamValue]]? = nil) {
        self.key = key; self.label = label; self.type = type; self.default = `default`
        self.min = min; self.max = max; self.step = step
        self.options = options; self.extensions = extensions; self.help = help
        self.group = group; self.labels = labels; self.scale = scale; self.optional = optional
        self.visibleWhen = visibleWhen
    }

    /// JSON has one number type, so `0.0` decodes as an integer: the default is stored in the
    /// param's own type, equal to the same value once `Workspace.resolveParams` has coerced it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        type = try c.decode(ParamType.self, forKey: .type)
        `default` = try c.decode(ParamValue.self, forKey: .default)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        step = try c.decodeIfPresent(Double.self, forKey: .step)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions)
        help = try c.decodeIfPresent(String.self, forKey: .help)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        scale = try c.decodeIfPresent(ParamScale.self, forKey: .scale)
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
        visibleWhen = try c.decodeIfPresent([String: [ParamValue]].self, forKey: .visibleWhen)
        if let typed = coerce(`default`) { `default` = typed }
    }

    /// Display name for an enum option.
    public func label(forOption option: String) -> String {
        guard let labels, let i = options?.firstIndex(of: option), labels.indices.contains(i) else { return option }
        return labels[i]
    }

    public var isOptional: Bool { optional ?? false }

    /// Whether Simple mode can show this param: a switch, a menu, a file chooser, or a slider with both ends.
    public var isSimpleEligible: Bool {
        switch type {
        case .bool, .enumeration, .file: return true
        case .int, .float:
            guard let min, let max else { return false }
            return min < max
        case .string: return false
        }
    }

    /// Converts `v` to this spec's type, or nil when it is not representable.
    public func coerce(_ v: ParamValue) -> ParamValue? {
        switch (type, v) {
        case (.int, .int): return v
        case (.int, .float(let d)):
            guard d.rounded() == d, let i = Int(exactly: d) else { return nil }
            return .int(i)
        case (.float, .int(let i)): return .float(Double(i))
        case (.float, .float): return v
        case (.bool, .bool): return v
        case (.enumeration, .string(let s)): return (options ?? []).contains(s) ? v : nil
        case (.string, .string), (.file, .string): return v
        default: return nil
        }
    }

    /// Clamps numeric values to `min`/`max`; other values pass through.
    public func clamp(_ v: ParamValue) -> ParamValue {
        switch v {
        case .int(let i):
            var r = i
            if let lo = min, Double(r) < lo { r = Int(lo.rounded(.up)) }
            if let hi = max, Double(r) > hi { r = Int(hi.rounded(.down)) }
            return .int(r)
        case .float(let d):
            var r = d
            if let lo = min { r = Swift.max(r, lo) }
            if let hi = max { r = Swift.min(r, hi) }
            return .float(r)
        default:
            return v
        }
    }
}
