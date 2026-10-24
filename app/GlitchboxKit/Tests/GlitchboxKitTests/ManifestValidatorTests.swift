import Testing
@testable import GlitchboxKit

struct ManifestValidatorTests {
    func base() -> PluginManifest {
        PluginManifest(id: "demo", name: "Demo", requires: ["ffmpeg"],
                       params: [ParamSpec(key: "amount", label: "Amount", type: .int, default: .int(4), min: 0, max: 10)],
                       steps: [PluginStep(name: "run", argv: ["ffmpeg", "-i", "{in}", "{p.amount}", "{out}"])])
    }

    func messages(_ m: PluginManifest, fileName: String? = "demo.json") -> [String] {
        ManifestValidator.validate(m, fileName: fileName).map(\.message)
    }

    @Test func acceptsValidManifest() {
        #expect(messages(base()).isEmpty)
    }

    @Test func rejectsUndeclaredParam() {
        var m = base()
        m.steps[0].argv = ["ffmpeg", "{p.nope}"]
        #expect(messages(m).contains { $0.contains("{p.nope}") && $0.contains("undeclared") })
    }

    @Test func rejectsBadID() {
        var m = base()
        m.id = "Bad_ID"
        #expect(messages(m, fileName: nil).contains { $0.contains("id 'Bad_ID'") })
    }

    @Test func rejectsIntDefaultOutOfRange() {
        var m = base()
        m.params[0].default = .int(11)
        #expect(messages(m).contains { $0.contains("above max") })
    }

    @Test func rejectsEnumDefaultNotInOptions() {
        var m = base()
        m.params = [ParamSpec(key: "mode", label: "Mode", type: .enumeration, default: .string("c"), options: ["a", "b"])]
        m.steps[0].argv = ["ffmpeg"]
        #expect(messages(m).contains { $0.contains("default not in options") })
    }

    @Test func rejectsStepWithArgvAndScript() {
        var m = base()
        m.steps[0].script = "echo hi"
        #expect(messages(m).contains { $0.contains("exactly one of argv or script") })
    }

    @Test func rejectsFileNameMismatch() {
        #expect(messages(base(), fileName: "other.json").contains { $0.contains("must be 'demo.json'") })
    }

    @Test func checksLabelsScaleAndOptional() {
        var m = base()
        m.params = [
            ParamSpec(key: "mode", label: "Mode", type: .enumeration, default: .string("0"), options: ["0", "1"], labels: ["Only one"]),
            ParamSpec(key: "gain", label: "Gain", type: .float, default: .float(0), scale: .log),
            ParamSpec(key: "name", label: "Name", type: .string, default: .string(""), optional: true),
        ]
        m.steps[0].argv = ["ffmpeg", "{source_audio}", "{params}"]
        let found = messages(m)
        #expect(found.contains { $0.contains("labels must match options") })
        #expect(found.contains { $0.contains("log scale needs min and max") })
        #expect(found.contains { $0.contains("optional is only for file params") })
        #expect(found.count == 3)
    }

    func gated() -> PluginManifest {
        var m = base()
        m.params = [
            ParamSpec(key: "mode", label: "Mode", type: .enumeration, default: .string("a"), options: ["a", "b"]),
            ParamSpec(key: "on", label: "On", type: .bool, default: .bool(false), visibleWhen: ["mode": [.string("b")]]),
            ParamSpec(key: "level", label: "Level", type: .int, default: .int(1), visibleWhen: ["on": [.bool(true)]]),
        ]
        m.steps[0].argv = ["ffmpeg"]
        return m
    }

    @Test func visibilityFollowsControllingParamsTransitively() {
        let m = gated()
        let level = m.spec("level")!
        #expect(messages(m).isEmpty)
        #expect(!m.isVisible(level, values: [:]))
        #expect(m.isVisible(level, values: ["mode": .string("b"), "on": .bool(true)]))
        // `on` is set, but hidden because mode is "a", so `level` stays hidden too.
        #expect(!m.isVisible(level, values: ["mode": .string("a"), "on": .bool(true)]))
    }

    @Test func rejectsBadVisibleWhen() {
        var m = gated()
        m.params[1].visibleWhen = ["mode": [.string("c")], "nope": [.int(1)]]
        m.params[0].visibleWhen = ["level": [.int(1)]]
        let found = messages(m)
        #expect(found.contains { $0.contains("visibleWhen 'mode': c is not a valid enum value") })
        #expect(found.contains { $0.contains("visibleWhen 'nope' must name another param") })
        #expect(found.contains { $0.contains("param 'mode': visibleWhen forms a cycle") })
    }
}
