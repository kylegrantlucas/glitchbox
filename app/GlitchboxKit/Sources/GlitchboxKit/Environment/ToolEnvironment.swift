import Foundation

/// The hermetic environment every render step, pipeline, and `glitchbox env` runs in.
public struct ToolEnvironment: Sendable {
    /// Keys the toolchain defines: `PATH`, `GLITCHBOX_*`, and toolchain.json `environment`.
    public let own: [String: String]
    /// `own` plus the pass-through parent variables; what child processes receive.
    public let variables: [String: String]
    /// toolchain.json `digest`; part of every layer cache key.
    public let digest: String
    /// Runs every tool and native step.
    public let runner: any ToolRunner

    public init(own: [String: String], passThrough: [String: String] = [:], digest: String, runner: any ToolRunner) {
        self.own = own
        self.variables = passThrough.merging(own) { _, mine in mine }
        self.digest = digest
        self.runner = runner
    }

    #if os(macOS)
    /// Spawns tools found on the resulting `variables["PATH"]`.
    public init(own: [String: String], passThrough: [String: String] = [:], digest: String) {
        let variables = passThrough.merging(own) { _, mine in mine }
        self.init(own: own, passThrough: passThrough, digest: digest, runner: SpawnRunner(path: variables["PATH"] ?? ""))
    }

    /// Absolute executable for `cmd`, searched on `variables["PATH"]`.
    public func which(_ cmd: String) -> URL? {
        SpawnRunner(path: variables["PATH"] ?? "").which(cmd)
    }
    #endif

    /// The `requires` entries `runner` cannot run.
    public func missing(_ requires: [String]) -> [String] {
        requires.filter { !runner.has($0) }
    }

    /// What `manifest` lacks on this runner, by the rule a render applies (see
    /// `LayerRunner.modes`); empty when every step can run.
    public func missing(for manifest: PluginManifest) -> [String] {
        do {
            _ = try LayerRunner.modes(for: manifest, runner: runner)
            return []
        } catch RenderError.unavailable(_, let missing) {
            return missing
        } catch {
            return []
        }
    }

    /// `own` as sorted `export KEY='value'` lines for `eval "$(glitchbox env)"`.
    public func shellExports() -> String {
        own.keys.sorted().map { "export \($0)=\(Self.shellQuote(own[$0]!))\n" }.joined()
    }

    /// POSIX single-quoted `s`; an embedded `'` becomes `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
