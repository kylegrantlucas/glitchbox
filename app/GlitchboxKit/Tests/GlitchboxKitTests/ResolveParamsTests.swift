import Foundation
import Testing
@testable import GlitchboxKit

struct ResolveParamsTests {
    let ws = Workspace(base: URL(filePath: "/tmp/nonexistent-root"), user: URL(filePath: "/tmp/nonexistent-user"),
                       cache: URL(filePath: "/tmp/nonexistent-cache"))
    let m = PluginManifest(id: "demo", name: "Demo", params: [
        ParamSpec(key: "amount", label: "Amount", type: .int, default: .int(4), min: 0, max: 10),
        ParamSpec(key: "gain", label: "Gain", type: .float, default: .float(0.5), min: 0, max: 1),
    ], steps: [PluginStep(name: "x", argv: ["true"])])

    @Test func dropsUnknownKey() {
        let r = ws.resolveParams(["bogus": .int(1)], for: m)
        #expect(r.values["bogus"] == nil)
        #expect(r.warnings == ["demo: dropped unknown param 'bogus'"])
    }

    @Test func fillsMissingWithDefaults() {
        let r = ws.resolveParams([:], for: m)
        #expect(r.values == ["amount": .int(4), "gain": .float(0.5)])
        #expect(r.warnings.isEmpty)
    }

    @Test func clampsOutOfRange() {
        let r = ws.resolveParams(["amount": .int(99)], for: m)
        #expect(r.values["amount"] == .int(10))
        #expect(r.warnings == ["demo: 'amount' clamped to 10"])
    }

    @Test func wrongTypeFallsBackToDefault() {
        let r = ws.resolveParams(["amount": .string("lots")], for: m)
        #expect(r.values["amount"] == .int(4))
        #expect(r.warnings == ["demo: 'amount' has wrong type, using default"])
    }

    @Test func integralFloatAcceptedForInt() {
        let r = ws.resolveParams(["amount": .float(7.0), "gain": .int(1)], for: m)
        #expect(r.values == ["amount": .int(7), "gain": .float(1)])
        #expect(r.warnings.isEmpty)
    }

    /// JSON has one number type, so a float param's `0.0` default reads as an integer. Left that
    /// way, an untouched default differs from the same value once it has been through a session
    /// or preset, and a layer matching a preset exactly compares as changed.
    @Test func manifestDefaultsTakeTheParamType() throws {
        let json = """
        {"schema":1,"id":"demo","name":"Demo","summary":"","requires":[],"assets":[],
         "params":[{"key":"gain","label":"Gain","type":"float","default":0.0,"min":0,"max":1},
                   {"key":"count","label":"Count","type":"int","default":3}],
         "steps":[{"name":"x","argv":["true"]}]}
        """
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(decoded.spec("gain")?.default == .float(0))
        #expect(decoded.spec("count")?.default == .int(3))
        #expect(ws.resolveParams(["gain": .int(0)], for: decoded).values == decoded.defaults())
        #expect(try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(decoded)) == decoded)
    }
}
