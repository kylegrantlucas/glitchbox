import Foundation

/// One tool run: `command` is the tool name as in argv[0] (or an absolute path on macOS).
public struct ToolInvocation: Sendable {
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var cwd: URL
    /// stdout and stderr are appended here.
    public var log: URL

    public init(command: String, arguments: [String], environment: [String: String], cwd: URL, log: URL) {
        self.command = command; self.arguments = arguments; self.environment = environment
        self.cwd = cwd; self.log = log
    }
}

/// How the engine runs tools: spawned processes on macOS, in-process on iOS.
public protocol ToolRunner: Sendable {
    /// Whether `command` (a tool name as in argv[0] or a manifest's `requires`) can run.
    func has(_ command: String) -> Bool
    /// Runs `invocation` with its output appended to `invocation.log`; returns the exit code.
    /// Cancelling the calling task stops the tool and returns (throwing `CancellationError`)
    /// only after it has stopped.
    func run(_ invocation: ToolInvocation) async throws -> Int32
    /// The engine-provided implementation of a plugin step's `native` id, if this runner has one.
    func native(_ id: String) -> (any NativeStep)?
}

/// Everything a native step implementation gets: the same inputs a plugin's argv/script step sees.
public struct NativeStepContext: Sendable {
    public var plugin: String
    public var step: String
    public var input: URL
    public var output: URL
    public var work: URL
    /// The base library (`{root}` / `GB_ROOT`).
    public var root: URL
    /// Typed, resolved params (file params are absolute paths).
    public var params: [String: ParamValue]
    /// The same params as JSON (`{params}` / `GB_PARAMS`).
    public var paramsFile: URL
    /// The source layer's trimmed audio track, when it has one.
    public var sourceAudio: URL?
    public var log: URL
    /// The step environment: the tool environment plus every `GB_*` variable.
    public var environment: [String: String]

    public init(plugin: String, step: String, input: URL, output: URL, work: URL, root: URL,
                params: [String: ParamValue], paramsFile: URL, sourceAudio: URL?, log: URL,
                environment: [String: String]) {
        self.plugin = plugin; self.step = step; self.input = input; self.output = output; self.work = work
        self.root = root; self.params = params; self.paramsFile = paramsFile; self.sourceAudio = sourceAudio
        self.log = log; self.environment = environment
    }
}

/// An engine-provided step implementation (see `PluginStep.native`).
public protocol NativeStep: Sendable {
    /// Writes `context.output`; returns an exit code (0 = success). Same cancellation
    /// contract as `ToolRunner.run`.
    func run(_ context: NativeStepContext) async throws -> Int32
}

#if os(macOS)
/// Spawns tools found on a PATH (see `Spawner`). Has no native steps.
public struct SpawnRunner: ToolRunner {
    /// Colon-separated directories searched for commands.
    public let path: String

    public init(path: String) { self.path = path }

    /// Absolute executable for `cmd`: an absolute path as-is, else the first match on `path`.
    public func which(_ cmd: String) -> URL? {
        let fm = FileManager.default
        if cmd.contains("/") {
            let url = URL(filePath: cmd)
            return cmd.hasPrefix("/") && fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let url = URL(filePath: String(dir), directoryHint: .isDirectory).appending(path: cmd)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public func has(_ command: String) -> Bool { which(command) != nil }

    public func run(_ invocation: ToolInvocation) async throws -> Int32 {
        guard let executable = which(invocation.command) else {
            throw SpawnError(path: invocation.command, code: ENOENT)
        }
        return try await Spawner.run(executable: executable, arguments: invocation.arguments,
                                     environment: invocation.environment, cwd: invocation.cwd, log: invocation.log)
    }

    public func native(_ id: String) -> (any NativeStep)? { nil }
}
#endif
