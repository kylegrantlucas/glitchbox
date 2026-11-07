#ifndef GB_RUN_H
#define GB_RUN_H

/* The in-process tools behind one call shape. Each run blocks until the tool returns;
   call it from a thread with a large stack (the tools recurse deeply). */

typedef enum gbr_tool {
    GBR_FFMPEG = 0,
    GBR_FFPROBE = 1,
    GBR_FFGAC = 2,
    GBR_FFEDIT = 3,
} gbr_tool;

/* A cancel flag (wraps the C11 atomic_int the tool entry points poll). */
typedef struct gbr_flag gbr_flag;

gbr_flag *gbr_flag_new(void);
void gbr_flag_free(gbr_flag *flag);
/* Asks every run polling `flag` to stop. Async-signal and thread safe. */
void gbr_flag_set(gbr_flag *flag);
int gbr_flag_get(const gbr_flag *flag);

/* Runs `tool` with argv[0..argc) (argv[0] is the tool name); appends its output to `log_path`
   (NULL discards). Returns the tool's exit code; 255 when stopped through `flag`. */
int gbr_run(gbr_tool tool, int argc, const char *const *argv, const char *log_path, const gbr_flag *flag);

/* pipe() with both ends close-on-exec and never raising SIGPIPE. Returns 0 or errno. */
int gbr_pipe(int fds[2]);

/* Ignores SIGPIPE process-wide (writes to a closed pipe then fail with EPIPE). Idempotent. */
void gbr_ignore_sigpipe(void);

#endif
