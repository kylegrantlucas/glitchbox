import Darwin
import Foundation

/// Runs a process in its own process group with stdout+stderr appended to a log.
///
/// Foundation `Process` cannot create a process group, so cancellation could
/// not reach grandchildren (e.g. ffmpeg under a pipeline script). Cancelling
/// the calling task sends SIGTERM to the group, then SIGKILL after 3 s.
public enum Spawner {
    public static func run(executable: URL, arguments: [String], environment: [String: String],
                           cwd: URL, log: URL) async throws -> Int32 {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pid = try spawn(executable: executable, arguments: arguments, environment: environment, cwd: cwd, log: log)
        let reaped = ReapFlag()

        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                Thread.detachNewThread {
                    var st: Int32 = 0
                    while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
                    reaped.set()
                    cont.resume(returning: st)
                }
            }
        } onCancel: {
            killpg(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                // The group outlives its leader while any member remains.
                if !reaped.isSet || killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
            }
        }
        if Task.isCancelled { throw CancellationError() }
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    private static func spawn(executable: URL, arguments: [String], environment: [String: String],
                              cwd: URL, log: URL) throws -> pid_t {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        posix_spawn_file_actions_addchdir(&fa, cwd.path)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &fa, &attr, argv, envp)
        guard rc == 0 else { throw SpawnError(path: executable.path, code: rc) }
        return pid
    }
}
