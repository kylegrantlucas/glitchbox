import Foundation
import Testing
@testable import GlitchboxKit

/// A runner with a fixed tool set that records what it runs: a tool copies its first argument
/// to its second; "bash" writes "bash" to `$GB_OUT` without running the script.
final class FakeRunner: ToolRunner, @unchecked Sendable {
    let tools: Set<String>
    let natives: [String: any NativeStep]
    private let lock = NSLock()
    private var _ran: [String] = []
    var ran: [String] { lock.withLock { _ran } }

    init(tools: Set<String>, natives: [String: any NativeStep] = [:]) {
        self.tools = tools; self.natives = natives
    }

    func has(_ command: String) -> Bool { tools.contains(command) }

    func run(_ invocation: ToolInvocation) async throws -> Int32 {
        lock.withLock { _ran.append(invocation.command) }
        let args = invocation.arguments
        if invocation.command == "bash" {
            try Data("bash".utf8).write(to: URL(filePath: invocation.environment["GB_OUT"]!))
        } else {
            try FileManager.default.copyItem(at: URL(filePath: args[0]), to: URL(filePath: args[1]))
        }
        return 0
    }

    func native(_ id: String) -> (any NativeStep)? { natives[id] }
}

/// Writes the plugin id and its `n` param to the output.
struct EchoNative: NativeStep {
    let seen: @Sendable (NativeStepContext) -> Void
    func run(_ context: NativeStepContext) async throws -> Int32 {
        seen(context)
        try Data("\(context.plugin):\(context.params["n"]?.rendered ?? "")".utf8).write(to: context.output)
        return 0
    }
}

final class StepModeTests {
    let root: URL
    let input: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "gbm-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        input = root.appending(path: "in.mkv")
        try Data("source".utf8).write(to: input)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func render(_ m: PluginManifest, on runner: FakeRunner) async throws -> LayerOutput {
        let env = ToolEnvironment(own: [:], digest: "d", runner: runner)
        let ws = Workspace(base: root.appending(path: "base"), user: root.appending(path: "user"), cache: root.appending(path: "cache"))
        return try await LayerRunner(env: env, workspace: ws)
            .run(manifest: m, params: m.defaults(), input: input, parentKey: "p", onStep: { _, _, _, _ in })
    }

    func manifest(requires: [String] = ["tool"], _ steps: PluginStep...) -> PluginManifest {
        PluginManifest(id: "demo", name: "Demo", requires: requires,
                       params: [ParamSpec(key: "n", label: "N", type: .int, default: .int(7))], steps: steps)
    }

    func recorded(_ out: LayerOutput) throws -> [PluginStep] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out.dir.appending(path: "manifest.json"))) as! [String: Any]
        let steps = try JSONSerialization.data(withJSONObject: json["steps"]!)
        return try JSONDecoder().decode([PluginStep].self, from: steps)
    }

    @Test func nativeRunsBeforeArgvAndScript() async throws {
        let runner = FakeRunner(tools: ["tool", "bash"], natives: ["demo": EchoNative { _ in }])
        let step = PluginStep(name: "go", argv: ["tool", "{in}", "{out}"], script: "true", native: "demo")
        let out = try await render(manifest(step), on: runner)
        #expect(runner.ran.isEmpty)
        #expect(try String(contentsOf: out.output, encoding: .utf8) == "demo:7")
    }

    @Test func argvRunsWhenTheRunnerLacksTheNative() async throws {
        let runner = FakeRunner(tools: ["tool"])
        _ = try await render(manifest(PluginStep(name: "copy", argv: ["tool", "{in}", "{out}"], native: "demo")), on: runner)
        #expect(runner.ran == ["tool"])
    }

    @Test func nativeRunsWithoutToolsAndSkipsRequires() async throws {
        let seen = Seen()
        let runner = FakeRunner(tools: [], natives: ["demo": EchoNative { seen.set($0) }])
        let out = try await render(manifest(PluginStep(name: "go", script: "exit 1", native: "demo")), on: runner)
        #expect(runner.ran.isEmpty)
        #expect(try String(contentsOf: out.output, encoding: .utf8) == "demo:7")
        let ctx = try #require(seen.value)
        #expect(ctx.step == "go" && ctx.input == input && ctx.params["n"] == .int(7))
        #expect(ctx.environment["GB_P_N"] == "7" && ctx.sourceAudio == nil)
        #expect(try recorded(out) == [PluginStep(name: "go", native: "demo")])
    }

    @Test func requiresAppliesWhenAnyStepSpawns() async throws {
        let runner = FakeRunner(tools: ["bash"], natives: ["demo": EchoNative { _ in }])
        let m = manifest(PluginStep(name: "a", native: "demo"), PluginStep(name: "b", script: "true"))
        let error = await #expect(throws: RenderError.self) { try await self.render(m, on: runner) }
        guard case .unavailable(_, let missing) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(missing == ["tool"])
    }

    @Test func stepWithoutAnyModeReportsWhatIsMissing() async throws {
        let runner = FakeRunner(tools: ["tool"])
        let m = manifest(PluginStep(name: "a", argv: ["tool", "{in}", "{out}"]),
                         PluginStep(name: "b", script: "true", native: "absent"),
                         PluginStep(name: "c", argv: ["ffmpeg"]))
        let error = await #expect(throws: RenderError.self) { try await self.render(m, on: runner) }
        guard case .unavailable(_, let missing) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(missing == ["bash", "ffmpeg"])
        #expect(runner.ran.isEmpty)
        let caches = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "cache/layers").path)) ?? []
        #expect(caches.isEmpty)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: NativeStepContext?
    var value: NativeStepContext? { lock.withLock { _value } }
    func set(_ c: NativeStepContext) { lock.withLock { _value = c } }
}
