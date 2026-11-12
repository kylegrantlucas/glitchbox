/* FFglitch.framework: FFglitch 0.10.2's ffgac and ffedit as in-process calls.
 *
 * argv[0] is the tool name ("ffgac" / "ffedit"); the rest is the command line
 * exactly as for the executables. Every stderr-style line (log output at the
 * run's -loglevel, stats, help, ffedit's feature list) is appended to log_path
 * (created if missing; NULL discards). If *cancel (may be NULL) becomes
 * nonzero the run stops like a SIGTERM'd tool and returns 255. The return
 * value is the tool's exit status (0-255). exit() inside the tools, their
 * worker threads, or a script (std.exit) ends only that run; a script error
 * fails the run. No signal handlers, terminal access, or processes.
 *
 * Each tool is serialized against itself (a second call waits), and every
 * global is reset per run, so sequential runs behave like fresh processes.
 * One ffgac and one ffedit run may run concurrently, and with any other
 * FFmpeg in the process: FFglitch's libraries are private to this framework.
 * pipe:N reads/writes the caller's fd N (the run closes only what it opens). */
#ifndef FFGLITCH_H
#define FFGLITCH_H

#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

int ffglitch_ffgac_run(int argc, const char *const *argv, const char *log_path, const atomic_int *cancel);
int ffglitch_ffedit_run(int argc, const char *const *argv, const char *log_path, const atomic_int *cancel);

#ifdef __cplusplus
}
#endif

#endif
