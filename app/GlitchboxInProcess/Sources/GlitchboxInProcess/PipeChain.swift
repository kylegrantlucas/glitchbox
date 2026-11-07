import Foundation
import GBRun

/// `a | b | c` for in-process tools: every stage runs on its own thread, connected by pipe()s
/// that the stages open as `pipe:N`. The tools dup() the fds they open, so the host closes its
/// copies as each stage returns — that is what delivers EOF downstream and EPIPE upstream.
enum PipeChain {
    struct Stage: Sendable {
        let tool: InProcessTool
        /// argv for the stage, given its `pipe:N` input URL (nil for the first stage) and
        /// output URL (nil for the last).
        let argv: @Sendable (_ input: String?, _ output: String?) -> [String]
        /// Where the stage's output goes; nil discards it.
        let log: URL?
    }

    /// Runs the stages concurrently. Any stage failing (or the task being cancelled) stops
    /// the others. Returns 0 when every stage succeeded, else the first failure's code; throws
    /// `CancellationError` after every stage returned when the task was cancelled.
    /// Multi-tool chains run one at a time process-wide (see `ChainGate`).
    static func run(_ stages: [Stage], log: URL) async throws -> Int32 {
        if stages.count > 1 {
            return try await ChainGate.shared.run { try await runUngated(stages, log: log) }
        }
        return try await runUngated(stages, log: log)
    }

    private static func runUngated(_ stages: [Stage], log: URL) async throws -> Int32 {
        try Task.checkCancellation()
        var pipes: [(read: Int32, write: Int32)] = []
        for _ in 0..<max(0, stages.count - 1) {
            var fds: [Int32] = [-1, -1]
            let rc = gbr_pipe(&fds)
            guard rc == 0 else {
                pipes.forEach { close($0.read); close($0.write) }
                ToolCall.append(log, "error: pipe: \(String(cString: strerror(rc)))\n")
                return 1
            }
            pipes.append((fds[0], fds[1]))
        }

        let flag = CancelFlag()
        let codes = await withTaskCancellationHandler {
            await withTaskGroup(of: Int32.self) { group in
                for (i, stage) in stages.enumerated() {
                    let input = i > 0 ? pipes[i - 1].read : nil
                    let output = i < stages.count - 1 ? pipes[i].write : nil
                    let argv = stage.argv(input.map { "pipe:\($0)" }, output.map { "pipe:\($0)" })
                    group.addTask {
                        await ToolCall.onThread(name: stage.tool.rawValue) {
                            let code = ToolCall.call(stage.tool, argv, log: stage.log?.path, flag: flag)
                            if let input { close(input) }
                            if let output { close(output) }
                            if code != 0 { flag.set() }
                            return code
                        }
                    }
                }
                var codes: [Int32] = []
                for await code in group { codes.append(code) }
                return codes
            }
        } onCancel: {
            flag.set()
        }
        if Task.isCancelled { throw CancellationError() }
        return codes.first { $0 != 0 } ?? 0
    }
}
