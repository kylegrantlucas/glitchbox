/*
 * gb_ffmpeg_run / gb_ffprobe_run: the patched fftools (see
 * patches/ffmpeg-8.1.2-inprocess.patch) run in the calling thread.
 *
 * packaging/ios/ffmpeg.sh links each tool's objects (with cmdutils/opt_common
 * and the text formatters) into one relocatable object whose symbols are all
 * local except its main, and renames its writable sections to
 * __DATA,__gbft_data / __DATA,__gbft_bss. Those two sections therefore hold
 * every fftools global and static; each run restores them to their load-time
 * contents (snapshotted before the first run), so every run starts from the
 * state a fresh process would have.
 *
 * Log routing. av_log's callback is process-wide, but a run's log must hold
 * only that run's lines. Every thread carries a run tag (gb_thread_run): run_tool
 * tags its calling thread, and gb_pthread_create (gb_thread_tag.c; ffmpeg.sh
 * force-includes gb_thread_tag.h into the fftools, every libav* library, and
 * x264) gives each new thread its creator's tag. A run's scheduler, demux, decode,
 * filter, encode and mux threads, and the worker threads libavcodec,
 * libavfilter and x264 start from them, therefore log into the run; a thread
 * the host started (e.g. GBMedia decoding with libav directly) has tag 0 and
 * its lines go to stderr, filtered by the level the host had before the run
 * (the run's -loglevel changes the global level only for the run's own
 * lines). Threads started by system frameworks (VideoToolbox, libc++
 * std::async in frei0r's kaleid0sc0pe) are untagged: their rare av_log lines
 * go to stderr, never into a run's log.
 *
 * A run waiting for another to finish (run_lock) polls its cancel atom and
 * returns 255 without running once it is set.
 */
#include "gb_ffmpeg.h"

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "libavutil/cpu.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

#define GB_THREAD_TAG_IMPL
#include "gb_thread_tag.h"

int gb_fftool_ffmpeg_main(int argc, char **argv);
int gb_fftool_ffprobe_main(int argc, char **argv);

/* The tools' stdout/stderr (gb_fftools_prefix.h); the current run's log. */
FILE *gb_fftools_stdout;
FILE *gb_fftools_stderr;

static pthread_mutex_t run_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

static const atomic_int *_Atomic run_cancel;
static atomic_int run_cancelled;

static unsigned run_seq; /* guarded by run_lock */

/* Guarded by log_lock: the active run's log (else NULL), its tag, and the
 * global log level from before it started. */
static FILE *run_log;
static unsigned active_run;
static int host_level = AV_LOG_INFO;
static int log_print_prefix = 1;
static int log_repeat_count;
static char log_prev[1024];

int gb_fftools_cancel_requested(void)
{
    const atomic_int *cancel = atomic_load(&run_cancel);
    if (cancel && atomic_load(cancel)) {
        atomic_store(&run_cancelled, 1);
        return 1;
    }
    return 0;
}

/* av_log_default_callback's level filter, prefixing, and repeat folding, minus
 * colour, for the active run's threads; while no run is active, messages go to
 * the default callback; from other threads, to stderr at the host's level. */
void gb_fftools_log_default(void *avcl, int level, const char *fmt, va_list vl)
{
    static _Thread_local int foreign_print_prefix = 1;
    char line[1024];
    int lvl = level >= 0 ? (level & 0xff) : level;

    pthread_mutex_lock(&log_lock);
    if (!run_log) {
        pthread_mutex_unlock(&log_lock);
        av_log_default_callback(avcl, level, fmt, vl);
        return;
    }
    if (gb_thread_run != active_run) {
        int max = host_level;
        pthread_mutex_unlock(&log_lock);
        if (lvl > max)
            return;
        av_log_format_line2(avcl, level, fmt, vl, line, sizeof(line), &foreign_print_prefix);
        fputs(line, stderr);
        return;
    }
    if (lvl > av_log_get_level())
        goto end;
    av_log_format_line2(avcl, level, fmt, vl, line, sizeof(line), &log_print_prefix);
    if (log_print_prefix && (av_log_get_flags() & AV_LOG_SKIP_REPEATED) &&
        !strcmp(line, log_prev) && *line && line[strlen(line) - 1] != '\r') {
        log_repeat_count++;
        goto end;
    }
    if (log_repeat_count > 0) {
        fprintf(run_log, "    Last message repeated %d times\n", log_repeat_count);
        log_repeat_count = 0;
    }
    strcpy(log_prev, line);
    fputs(line, run_log);
end:
    pthread_mutex_unlock(&log_lock);
}

typedef struct Section {
    uint8_t *addr;
    unsigned long size;
} Section;

static Section tool_data, tool_bss;
static uint8_t *tool_data_init;
static int sections_found;

/* Called with run_lock held. */
static int reset_tool_globals(void)
{
    if (!sections_found) {
        Dl_info info;
        const struct mach_header_64 *mh;

        if (!dladdr((const void *)&gb_ffmpeg_run, &info) || !info.dli_fbase)
            return -1;
        mh = (const struct mach_header_64 *)info.dli_fbase;
        tool_data.addr = getsectiondata(mh, "__DATA", "__gbft_data", &tool_data.size);
        tool_bss.addr  = getsectiondata(mh, "__DATA", "__gbft_bss", &tool_bss.size);
        if (!tool_data.addr || !tool_bss.addr)
            return -1;
        /* No fftools code has run yet: this is the load-time state. */
        tool_data_init = malloc(tool_data.size);
        if (!tool_data_init)
            return -1;
        memcpy(tool_data_init, tool_data.addr, tool_data.size);
        sections_found = 1;
        return 0;
    }
    memcpy(tool_data.addr, tool_data_init, tool_data.size);
    memset(tool_bss.addr, 0, tool_bss.size);
    return 0;
}

/* Takes run_lock, giving up (-1) once *cancel is set. */
static int lock_run(const atomic_int *cancel)
{
    const struct timespec poll = { 0, 10 * 1000 * 1000 };

    while (pthread_mutex_trylock(&run_lock)) {
        if (cancel && atomic_load(cancel))
            return -1;
        nanosleep(&poll, NULL);
    }
    return 0;
}

static int run_tool(int (*tool_main)(int, char **), int argc, const char *const *argv,
                    const char *log_path, const atomic_int *cancel)
{
    FILE *log;
    char **args;
    int ret, level, flags;

    if (argc < 1 || !argv)
        return 1;

    if (lock_run(cancel) < 0)
        return 255;

    log = fopen(log_path ? log_path : "/dev/null", "ae");
    if (!log) {
        pthread_mutex_unlock(&run_lock);
        return 1;
    }
    setvbuf(log, NULL, _IOLBF, 0);

    if (reset_tool_globals() < 0) {
        fputs("GlitchFFmpeg: fftools data sections not found\n", log);
        fclose(log);
        pthread_mutex_unlock(&run_lock);
        return 1;
    }

    args = calloc((size_t)argc + 1, sizeof(*args));
    if (!args) {
        fclose(log);
        pthread_mutex_unlock(&run_lock);
        return 1;
    }
    for (int i = 0; i < argc; i++) {
        if (!(args[i] = strdup(argv[i] ? argv[i] : ""))) {
            for (int j = 0; j < i; j++)
                free(args[j]);
            free(args);
            fclose(log);
            pthread_mutex_unlock(&run_lock);
            return 1;
        }
    }

    /* A fresh process: default log level and flags, our sink. */
    level = av_log_get_level();
    flags = av_log_get_flags();
    av_log_set_level(AV_LOG_INFO);
    av_log_set_flags(0);
    gb_fftools_stdout = gb_fftools_stderr = log;
    atomic_store(&run_cancelled, 0);
    atomic_store(&run_cancel, cancel);
    gb_thread_run = ++run_seq ? run_seq : ++run_seq;
    pthread_mutex_lock(&log_lock);
    run_log = log;
    active_run = gb_thread_run;
    host_level = level;
    log_print_prefix = 1;
    log_repeat_count = 0;
    log_prev[0] = 0;
    pthread_mutex_unlock(&log_lock);
    av_log_set_callback(gb_fftools_log_default);

    ret = tool_main(argc, args);

    /* Undo what options may have changed process-wide. */
    av_log_set_callback(gb_fftools_log_default);
    pthread_mutex_lock(&log_lock);
    if (log_repeat_count > 0)
        fprintf(log, "    Last message repeated %d times\n", log_repeat_count);
    run_log = NULL;
    active_run = 0;
    pthread_mutex_unlock(&log_lock);
    gb_thread_run = 0;
    atomic_store(&run_cancel, NULL);
    av_log_set_level(level);
    av_log_set_flags(flags);
    av_max_alloc(INT_MAX);
    av_force_cpu_flags(-1);
    av_cpu_force_count(0);
    gb_fftools_stdout = gb_fftools_stderr = NULL;

    fclose(log);
    for (int i = 0; i < argc; i++)
        free(args[i]);
    free(args);

    ret = atomic_load(&run_cancelled) ? 255 : (ret & 0xff);
    pthread_mutex_unlock(&run_lock);
    return ret;
}

int gb_ffmpeg_run(int argc, const char *const *argv, const char *log_path, const atomic_int *cancel)
{
    return run_tool(gb_fftool_ffmpeg_main, argc, argv, log_path, cancel);
}

int gb_ffprobe_run(int argc, const char *const *argv, const char *log_path, const atomic_int *cancel)
{
    return run_tool(gb_fftool_ffprobe_main, argc, argv, log_path, cancel);
}
