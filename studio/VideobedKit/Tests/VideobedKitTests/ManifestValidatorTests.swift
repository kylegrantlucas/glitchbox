import Testing
@testable import VideobedKit

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
}
