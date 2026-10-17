import Foundation
import Testing
@testable import VideobedKit

struct ResolveParamsTests {
    let ws = Workspace(root: URL(filePath: "/tmp/nonexistent-root"))
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
}
