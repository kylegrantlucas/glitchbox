import Foundation
import GBRun

/// The library-backed tools. Each is serialized against itself inside its library.
enum InProcessTool: String, CaseIterable, Sendable {
    case ffmpeg, ffprobe, ffgac, ffedit

    var id: gbr_tool {
        switch self {
        case .ffmpeg: GBR_FFMPEG
        case .ffprobe: GBR_FFPROBE
        case .ffgac: GBR_FFGAC
        case .ffedit: GBR_FFEDIT
        }
    }
}

/// The atomic flag a run polls; setting it stops the run like a SIGTERM.
final class CancelFlag: @unchecked Sendable {
    let raw: OpaquePointer

    init() {
        guard let raw = gbr_flag_new() else { fatalError("out of memory allocating a cancel flag") }
        self.raw = raw
    }

    deinit { gbr_flag_free(raw) }

    func set() { gbr_flag_set(raw) }
    var isSet: Bool { gbr_flag_get(raw) != 0 }
}

enum ToolCall {
    /// Tool runs recurse deeply (option parsing, filter graphs, QuickJS); threads get 16 MB.
    static let stackSize = 16 << 20

    /// Runs `body` on a dedicated thread, keeping blocking work off the cooperative pool.
    static func onThread<T: Sendable>(name: String, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.stackSize = stackSize
            thread.name = "glitchbox.\(name)"
            thread.start()
        }
    }

    /// Runs `tool` synchronously in the calling thread. `argv[0]` is the tool name.
    static func call(_ tool: InProcessTool, _ argv: [String], log: String?, flag: CancelFlag) -> Int32 {
        let cArgs = argv.map { UnsafePointer(strdup($0)) }
        defer { cArgs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return cArgs.withUnsafeBufferPointer { argvBuf in
            if let log {
                log.withCString { gbr_run(tool.id, Int32(argv.count), argvBuf.baseAddress, $0, flag.raw) }
            } else {
                gbr_run(tool.id, Int32(argv.count), argvBuf.baseAddress, nil, flag.raw)
            }
        }
    }

    /// Runs `body` with a flag that is set when the calling task is cancelled; returns only
    /// after `body` returns, then throws `CancellationError` if the task was cancelled.
    static func cancellable(_ name: String, _ body: @escaping @Sendable (CancelFlag) -> Int32) async throws -> Int32 {
        try Task.checkCancellation()
        let flag = CancelFlag()
        let code = await withTaskCancellationHandler {
            await onThread(name: name) { body(flag) }
        } onCancel: {
            flag.set()
        }
        if Task.isCancelled { throw CancellationError() }
        return code
    }

    /// Appends `text` to the log at `url` (created if missing).
    static func append(_ url: URL, _ text: String) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return }
            bytes = bytes.dropFirst(n)
        }
    }
}
