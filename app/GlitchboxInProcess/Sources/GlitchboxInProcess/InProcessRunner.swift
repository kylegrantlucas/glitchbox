import Foundation
import GBRun
import GlitchboxKit

/// Runs every tool in-process (iOS forbids spawning): ffmpeg and ffprobe from GlitchFFmpeg,
/// ffgac and ffedit from FFglitch, and native implementations of the plugin steps that would
/// otherwise need bash or other executables.
///
/// Each run happens on a dedicated 16 MB-stack thread. Runs of the same tool are serialized
/// inside its library, so e.g. an export's ffmpeg may wait behind a render's. A run ignores
/// `ToolInvocation.environment` and `cwd` (tools share the process); every engine invocation
/// passes absolute paths.
public struct InProcessRunner: ToolRunner {
    private static let natives: [String: any NativeStep] = [
        "mpeg2-mosh": MPEG2MoshStep(),
        "mv-script": MVScriptStep(),
        "mv-mangle": MVMangleStep(),
        "analog-pass": AnalogPassStep(),
        "bender": BenderStep(),
        "reactive-vcr": ReactiveVCRStep(),
        "still-motion": StillMotionStep(),
    ]

    public init() { Self.prepare() }

    /// Process-wide setup the tools rely on: SIGPIPE ignored, so a stage writing to a pipe
    /// whose reader quit gets EPIPE instead of killing the app. Idempotent; `init` calls it.
    public static func prepare() { gbr_ignore_sigpipe() }

    public func has(_ command: String) -> Bool { InProcessTool(rawValue: command) != nil }

    public func run(_ invocation: ToolInvocation) async throws -> Int32 {
        guard let tool = InProcessTool(rawValue: invocation.command) else {
            throw InProcessError.unknownTool(invocation.command)
        }
        try FileManager.default.createDirectory(at: invocation.log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let argv = [tool.rawValue] + invocation.arguments
        let log = invocation.log.path
        return try await ToolCall.cancellable(tool.rawValue) { flag in
            ToolCall.call(tool, argv, log: log, flag: flag)
        }
    }

    public func native(_ id: String) -> (any NativeStep)? { Self.natives[id] }
}

public enum InProcessError: Error, LocalizedError {
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "\(name) is not available in-process"
        }
    }
}
