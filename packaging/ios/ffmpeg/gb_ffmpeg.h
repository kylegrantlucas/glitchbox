/*
 * GlitchFFmpeg: the ffmpeg and ffprobe command-line tools (FFmpeg 8.1.2)
 * running in-process, for hosts that cannot spawn processes (iOS).
 */
#ifndef GB_FFMPEG_H
#define GB_FFMPEG_H

#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Runs the ffmpeg CLI in-process; argv[0] is "ffmpeg". Never exits the process,
   never installs signal handlers or touches the terminal. All stderr-style output
   (log lines at the run's -loglevel, stats, errors) is appended to log_path
   (created if missing; NULL discards). If *cancel becomes nonzero the run stops
   like a SIGTERM'd ffmpeg and returns 255. Returns ffmpeg's exit code. Calls are
   serialized by an internal lock shared with gb_ffprobe_run (fftools globals);
   every global is reset so any number of sequential runs behave like fresh processes.
   pipe:N reads/writes a dup of the host's descriptor N (closed before returning);
   the host closes its own end. stdout-style output (e.g. -version, ffprobe
   without -o) also goes to log_path. */
int gb_ffmpeg_run(int argc, const char *const *argv, const char *log_path, const atomic_int *cancel);

/* Same contract for ffprobe (argv[0] "ffprobe"); JSON goes wherever -o says. */
int gb_ffprobe_run(int argc, const char *const *argv, const char *log_path, const atomic_int *cancel);

#ifdef __cplusplus
}
#endif

#endif
