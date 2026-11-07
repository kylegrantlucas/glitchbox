/* Force-included (-include) into every FFglitch object compiled for
 * FFglitch.framework, before any system header. The renames route process-
 * wide operations to ffglitch_runtime.c, which knows the tool run (ffgac or
 * ffedit) the calling thread belongs to:
 *
 *   exit               ends only the calling thread and fails its run
 *                      (ffedit, its worker threads, libavcodec's ffedit code,
 *                      and QuickJS's std.exit all call exit()).
 *   pthread_create     the new thread inherits its creator's run (log, level,
 *                      cancel); fftools threads are also tracked and joined.
 *   pthread_cond_wait  a thread waiting in a run that has failed or been
 *                      cancelled leaves instead of blocking forever.
 *   fopen/fdopen/fclose  files a run leaves open are closed when it ends.
 *
 * Only object-like renames: the system prototypes are renamed with them, so
 * every call site is type-checked against the real signature. */
#ifndef FFG_HOOKS_H
#define FFG_HOOKS_H

#define exit ffg_exit
#define pthread_create ffg_pthread_create
#define pthread_cond_wait ffg_pthread_cond_wait
#define fopen ffg_fopen
#define fdopen ffg_fdopen
#define fclose ffg_fclose

/* Called from the patched libavutil/log.c, libavformat/file.c, and
 * libavutil/script_quickjs.c (see inprocess.patch). */
int *ffg_log_level_ptr(void);
int ffg_io_interrupted(void);
int ffg_should_abandon(void);
void ffg_fd_track(int fd);
void ffg_fd_untrack(int fd);

#endif
