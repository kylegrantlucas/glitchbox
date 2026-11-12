/// How a plugin presents in the app's Simple mode. Plugins without one stay out of its effect picker.
public struct SimpleInfo: Codable, Hashable, Sendable {
    /// Plain-language name; nil uses the manifest name.
    public var name: String?
    /// One line for the effect picker, no tool names.
    public var blurb: String
    /// Effect-picker section.
    public var category: String
    /// At most 4.
    public var controls: [SimpleControl]

    public init(name: String? = nil, blurb: String, category: String, controls: [SimpleControl] = []) {
        self.name = name; self.blurb = blurb; self.category = category; self.controls = controls
    }

    /// `controls` may be left out of a hand-written block (an effect with styles only).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        blurb = try c.decode(String.self, forKey: .blurb)
        category = try c.decode(String.self, forKey: .category)
        controls = try c.decodeIfPresent([SimpleControl].self, forKey: .controls) ?? []
    }

    /// Drops controls whose key has no `isSimpleEligible` param in `params`.
    public func pruned(for params: [ParamSpec]) -> SimpleInfo {
        let eligible = Set(params.filter(\.isSimpleEligible).map(\.key))
        var copy = self
        copy.controls = controls.filter { eligible.contains($0.key) }
        return copy
    }
}
