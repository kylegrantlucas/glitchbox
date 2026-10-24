import Darwin
import Foundation
import Testing
@testable import GlitchboxKit

final class LayerRunnerTests {
    let root: URL
    let input: URL
    let runner: LayerRunner

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "gbk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        input = root.appending(path: "in.mkv")
        try Data("source bytes".utf8).write(to: input)
        runner = LayerRunner(env: ToolEnvironment(own: ProcessInfo.processInfo.environment, digest: "toolchain-a"),
                             workspace: Workspace(base: root.appending(path: "base"), user: root.appending(path: "user"),
                                                  cache: root.appending(path: "cache")))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func plugin(_ id: String, script: String, params: [ParamSpec] = []) -> PluginManifest {
        PluginManifest(id: id, name: id, params: params, steps: [PluginStep(name: "go", script: script)])
    }

    func cacheEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: runner.cacheDir.path)) ?? []
    }

    func run(_ m: PluginManifest, _ params: [String: ParamValue] = [:], parent: String = "p") async throws -> LayerOutput {
        try await runner.run(manifest: m, params: params.isEmpty ? m.defaults() : params, input: input,
                             parentKey: parent, onStep: { _, _, _, _ in })
    }

    @Test func secondIdenticalRunIsCachedWithoutExecuting() async throws {
        let counter = root.appending(path: "count.txt")
        let m = plugin("count", script: "echo run >> '\(counter.path)'; cp \"$GB_IN\" \"$GB_OUT\"")
        let a = try await run(m)
        let b = try await run(m)
        #expect(!a.cached)
        #expect(b.cached)
        #expect(a.key == b.key)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "run\n")
        #expect(FileManager.default.fileExists(atPath: a.dir.appending(path: "manifest.json").path))
    }

    @Test func paramChangeReExecutes() async throws {
        let m = PluginManifest(id: "argv", name: "argv",
                               params: [ParamSpec(key: "n", label: "N", type: .int, default: .int(1))],
                               steps: [PluginStep(name: "copy", argv: ["/bin/cp", "{in}", "{out}"])])
        let a = try await run(m, ["n": .int(1)])
        let b = try await run(m, ["n": .int(2)])
        #expect(!b.cached)
        #expect(a.key != b.key)
    }

    @Test func toolchainDigestChangeReExecutes() async throws {
        let m = plugin("tool", script: "cp \"$GB_IN\" \"$GB_OUT\"")
        let a = try await run(m)
        let rebuilt = LayerRunner(env: ToolEnvironment(own: runner.env.own, digest: "toolchain-b"), workspace: runner.workspace)
        let b = try await rebuilt.run(manifest: m, params: m.defaults(), input: input, parentKey: "p", onStep: { _, _, _, _ in })
        #expect(!b.cached)
        #expect(a.key != b.key)
    }

    @Test func upstreamChangeChangesDownstreamKey() async throws {
        let up = plugin("up", script: "printf %s \"$GB_P_N\" > \"$GB_OUT\"",
                        params: [ParamSpec(key: "n", label: "N", type: .int, default: .int(1))])
        let down = plugin("down", script: "cp \"$GB_IN\" \"$GB_OUT\"")
        let u1 = try await run(up, ["n": .int(1)])
        let d1 = try await runner.run(manifest: down, params: [:], input: u1.output, parentKey: u1.key, onStep: { _, _, _, _ in })
        let u2 = try await run(up, ["n": .int(2)])
        let d2 = try await runner.run(manifest: down, params: [:], input: u2.output, parentKey: u2.key, onStep: { _, _, _, _ in })
        #expect(d1.key != d2.key)
        #expect(!d2.cached)
        #expect(try String(contentsOf: d2.output, encoding: .utf8) == "2")
    }

    @Test func scriptsSeeTypedParamsOptionalFilesAndSourceAudio() async throws {
        let audio = root.appending(path: "audio.wav")
        try Data("pcm".utf8).write(to: audio)
        let m = PluginManifest(id: "env", name: "env", params: [
            ParamSpec(key: "on", label: "On", type: .bool, default: .bool(true)),
            ParamSpec(key: "mode", label: "Mode", type: .enumeration, default: .string("2"), options: ["1", "2"]),
            ParamSpec(key: "track", label: "Track", type: .file, default: .string(""), optional: true),
        ], steps: [PluginStep(name: "dump", script: """
            jq -c --arg a "$GB_SOURCE_AUDIO" --arg t "$GB_P_TRACK" '. + {audio: $a, track_env: $t}' "$GB_PARAMS" > "$GB_OUT"
            """)])
        let out = try await runner.run(manifest: m, params: m.defaults(), input: input, parentKey: "p",
                                       sourceAudio: audio, onStep: { _, _, _, _ in })
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: out.output)) as? [String: Any]
        #expect(json?["on"] as? Bool == true)
        #expect(json?["mode"] as? String == "2")
        #expect(json?["track"] as? String == "")
        #expect(json?["track_env"] as? String == "")
        #expect(json?["audio"] as? String == audio.path)
    }

    @Test func stillTargetReachesScriptsAndKeysTheCache() async throws {
        let m = plugin("motion", script: "printf '%s %s %s %s' \"$GB_FPS\" \"$GB_DURATION\" \"$GB_WIDTH\" \"$GB_HEIGHT\" > \"$GB_OUT\"")
        let a = try await runner.run(manifest: m, params: [:], input: input, parentKey: "p",
                                     still: StillTarget(fps: "30000/1001", duration: 2, width: 640, height: 480),
                                     onStep: { _, _, _, _ in })
        #expect(try String(contentsOf: a.output, encoding: .utf8) == "30000/1001 2.0 640 480")
        let b = try await runner.run(manifest: m, params: [:], input: input, parentKey: "p",
                                     still: StillTarget(fps: "30000/1001", duration: 3, width: 640, height: 480),
                                     onStep: { _, _, _, _ in })
        #expect(!b.cached)
        #expect(a.key != b.key)
    }

    @Test func requiredEmptyFileParamFailsBeforeSpawning() async throws {
        let m = PluginManifest(id: "req", name: "req",
                               params: [ParamSpec(key: "track", label: "Track", type: .file, default: .string(""))],
                               steps: [PluginStep(name: "go", script: "cp \"$GB_IN\" \"$GB_OUT\"")])
        await #expect {
            _ = try await run(m)
        } throws: { error in
            if case RenderError.missingFile(_, let param) = error { return param == "track" }
            return false
        }
        #expect(cacheEntries().isEmpty)
    }

    @Test func failingStepKeepsFailedDir() async throws {
        let m = plugin("fail", script: "echo boom >&2; exit 3")
        do {
            _ = try await run(m)
            Issue.record("expected failure")
        } catch RenderError.stepFailed(_, let step, let code, let log, let tail) {
            #expect(step == "go")
            #expect(code == 3)
            #expect(log.deletingLastPathComponent().lastPathComponent.hasSuffix(".failed"))
            #expect(FileManager.default.fileExists(atPath: log.path))
            #expect(tail.last == "boom")
        }
        #expect(cacheEntries().allSatisfy { $0.hasSuffix(".failed") })
        #expect(cacheEntries().count == 1)
    }

    @Test func emptyOutputIsNoOutput() async throws {
        let m = plugin("empty", script: "true")
        await #expect {
            _ = try await run(m)
        } throws: { error in
            if case RenderError.noOutput = error { return true }
            return false
        }
        #expect(cacheEntries().allSatisfy { $0.hasSuffix(".failed") })
    }

    @Test func cancellationKillsProcessGroupAndCleansUp() async throws {
        let pidFile = root.appending(path: "sleep.pid")
        let m = plugin("slow", script: "sleep 30 & echo $! > '\(pidFile.path)'; wait")
        let runner = runner, input = input
        let task = Task {
            try await runner.run(manifest: m, params: [:], input: input, parentKey: "p", onStep: { _, _, _, _ in })
        }

        var pid: pid_t = 0
        for _ in 0..<100 where pid == 0 {
            try await Task.sleep(for: .milliseconds(50))
            if let s = try? String(contentsOf: pidFile, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = p
            }
        }
        #expect(pid > 0)
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!cacheEntries().contains { $0.contains(".partial-") })

        var alive = true
        for _ in 0..<40 where alive {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
    }
}
