/* FFglitch.framework runtime: runs FFglitch's ffgac and ffedit mains in-process.
 *
 * Each tool's fftools objects are one relocatable object (packaging/ios/
 * ffglitch.sh) whose symbols are all local except <tool>_tool_main, with its
 * writable data in __DATA,__<tool>_data/__<tool>_bss. Before every run those
 * sections are restored to their load-time contents, which resets every
 * fftools global (option tables, nb_* counters, file lists, ...).
 *
 * A run executes the tool's main on a fresh thread. Every thread a run starts
 * inherits it (thread-local `cur_run`, propagated by the pthread_create hook
 * in ffg_hooks.h), which gives each thread the run's log, log level, cancel
 * state, and failure handling:
 *  - exit() on any thread of the run records the status (first wins), marks
 *    the run abandoned, and ends only that thread (pthread_exit);
 *  - an abandoned run's threads leave at their next condition wait (unlocking
 *    the mutex first), their next pipe/file read or write gives up, and a
 *    running QuickJS script is interrupted;
 *  - the caller's thread waits until every fftools thread of the run has
 *    ended, joins the ones the tool did not join, and closes the descriptors
 *    and FILEs the run opened and left open.
 * Cancel: ffgac gets a SIGTERM-equivalent (it stops gracefully, as ffmpeg
 * does) and interrupted I/O; ffedit, which has no SIGTERM handling, is
 * abandoned. Either way the run returns 255. A run still waiting for the
 * previous run of the same tool (tool->serial) returns 255 without running
 * once its cancel atom is set.
 *
 * Built without ffg_hooks.h, so the names below are the real libc calls. */

#include <dlfcn.h>
#include <errno.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "libavutil/log.h"

#include "ffglitch.h"

#define FFG_API __attribute__((visibility("default")))

/* fftools entry points (ffgac = FFglitch's fftools/ffmpeg.c) */
int ffgac_tool_main(int argc, char **argv);
void ffgac_tool_cancel(void);
int ffedit_tool_main(int argc, char **argv);

/* The tools' main thread gets the stack a process main thread would have. */
#define FFG_MAIN_STACK (8 << 20)
/* Granularity of abandon/cancel checks in waits. */
#define FFG_POLL_NS (50 * 1000 * 1000)

typedef struct Thread {
    pthread_t thread;
    int joined;
    struct Thread *next;
} Thread;

typedef struct Run {
    pthread_mutex_t lock;   /* everything below except the atomics and log */
    pthread_cond_t cond;    /* signalled when a tracked thread ends */
    Thread *threads;        /* fftools threads, joined at the end */
    int live;               /* fftools threads still running */
    int exited, exit_code;  /* first exit() */
    int main_ret;
    atomic_int abandon;     /* threads leave at their next wait */
    atomic_int interrupted; /* pipe/file I/O gives up */
    int *fds;
    size_t nb_fds, cap_fds;
    FILE **files;
    size_t nb_files, cap_files;

    pthread_mutex_t log_lock;
    FILE *log;
    int log_level;
    int print_prefix;
} Run;

typedef struct Tool {
    const char *data_sect, *bss_sect;
    int (*main)(int, char **);
    void (*cancel)(void); /* NULL: cancelling abandons the run */
    pthread_mutex_t serial;
    uint8_t *data_init;   /* load-time contents of data_sect */
    int argc;
    char **argv;
    Run run;
} Tool;

#define FFG_TOOL(name, cancel_fn) {                                   \
    .data_sect = "__" #name "_data", .bss_sect = "__" #name "_bss",   \
    .main = name##_tool_main, .cancel = cancel_fn,                    \
    .serial = PTHREAD_MUTEX_INITIALIZER,                              \
    .run = { .lock = PTHREAD_MUTEX_INITIALIZER,                       \
             .cond = PTHREAD_COND_INITIALIZER,                        \
             .log_lock = PTHREAD_MUTEX_INITIALIZER } }

static Tool tool_ffgac  = FFG_TOOL(ffgac, ffgac_tool_cancel);
static Tool tool_ffedit = FFG_TOOL(ffedit, NULL);

static __thread Run *cur_run;
static __thread Thread *cur_thread;

/* --- threads ------------------------------------------------------------ */

typedef struct Start {
    void *(*fn)(void *);
    void *arg;
    Run *run;
    Thread *thread; /* NULL: not an fftools thread */
} Start;

static void thread_left(Run *run)
{
    pthread_mutex_lock(&run->lock);
    run->live--;
    pthread_cond_broadcast(&run->cond);
    pthread_mutex_unlock(&run->lock);
}

static void *start_thread(void *p)
{
    Start s = *(Start *) p;
    void *ret;
    free(p);
    cur_run = s.run;
    cur_thread = s.thread;
    ret = s.fn(s.arg);
    if (s.thread)
        thread_left(s.run);
    return ret;
}

static __attribute__((noreturn)) void leave_thread(void)
{
    if (cur_run && cur_thread)
        thread_left(cur_run);
    pthread_exit(NULL);
}

static int create_tracked(Run *run, pthread_t *out, const pthread_attr_t *attr,
                          void *(*fn)(void *), void *arg)
{
    Thread *th = calloc(1, sizeof(*th));
    Start *s = malloc(sizeof(*s));
    Thread **pp;
    int ret;

    if (!th || !s) {
        free(th);
        free(s);
        return EAGAIN;
    }
    *s = (Start) { fn, arg, run, th };
    pthread_mutex_lock(&run->lock);
    th->next = run->threads;
    run->threads = th;
    run->live++;
    pthread_mutex_unlock(&run->lock);

    ret = pthread_create(&th->thread, attr, start_thread, s);
    if (ret) {
        pthread_mutex_lock(&run->lock);
        for (pp = &run->threads; *pp != th; pp = &(*pp)->next)
            ;
        *pp = th->next;
        run->live--;
        pthread_mutex_unlock(&run->lock);
        free(th);
        free(s);
        return ret;
    }
    *out = th->thread;
    return 0;
}

int ffg_pthread_create(pthread_t *out, const pthread_attr_t *attr,
                       void *(*fn)(void *), void *arg)
{
    Run *run = cur_run;
    Start *s;
    int ret;

    if (!run)
        return pthread_create(out, attr, fn, arg);
    if (!(s = malloc(sizeof(*s))))
        return EAGAIN;
    *s = (Start) { fn, arg, run, NULL };
    ret = pthread_create(out, attr, start_thread, s);
    if (ret)
        free(s);
    return ret;
}

int ffg_tool_pthread_create(pthread_t *out, const pthread_attr_t *attr,
                            void *(*fn)(void *), void *arg)
{
    Run *run = cur_run;
    if (!run)
        return pthread_create(out, attr, fn, arg);
    return create_tracked(run, out, attr, fn, arg);
}

int ffg_tool_pthread_join(pthread_t thread, void **ret)
{
    Run *run = cur_run;
    if (run) {
        pthread_mutex_lock(&run->lock);
        for (Thread *th = run->threads; th; th = th->next)
            if (pthread_equal(th->thread, thread))
                th->joined = 1;
        pthread_mutex_unlock(&run->lock);
    }
    return pthread_join(thread, ret);
}

static struct timespec deadline(long ns)
{
    struct timeval now;
    struct timespec ts;
    gettimeofday(&now, NULL);
    ts.tv_sec = now.tv_sec;
    ts.tv_nsec = now.tv_usec * 1000L + ns;
    ts.tv_sec += ts.tv_nsec / 1000000000L;
    ts.tv_nsec %= 1000000000L;
    return ts;
}

/* A wait that wakes up at least every FFG_POLL_NS. A timeout is returned to
 * the caller as a spurious wakeup (callers re-check their predicate in a
 * loop, as POSIX requires): waiting again here could miss a signal sent
 * without the mutex held (libavcodec's frame threads do that). */
int ffg_pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex)
{
    Run *run = cur_run;
    struct timespec ts;
    int ret;

    if (!run)
        return pthread_cond_wait(cond, mutex);
    if (atomic_load(&run->abandon)) {
        pthread_mutex_unlock(mutex);
        leave_thread();
    }
    ts = deadline(FFG_POLL_NS);
    ret = pthread_cond_timedwait(cond, mutex, &ts);
    return ret == ETIMEDOUT ? 0 : ret;
}

__attribute__((noreturn)) void ffg_exit(int status)
{
    Run *run = cur_run;
    if (run) {
        pthread_mutex_lock(&run->lock);
        if (!run->exited) {
            run->exited = 1;
            run->exit_code = status & 0xff;
        }
        pthread_mutex_unlock(&run->lock);
        atomic_store(&run->interrupted, 1);
        atomic_store(&run->abandon, 1);
    }
    leave_thread();
}

int ffg_should_abandon(void)
{
    Run *run = cur_run;
    return run && atomic_load(&run->abandon);
}

int ffg_io_interrupted(void)
{
    Run *run = cur_run;
    return run && atomic_load(&run->interrupted);
}

/* --- descriptors and FILEs ---------------------------------------------- */

#define FFG_PUSH(run, arr, nb, cap, val) do {                          \
    if ((run)->nb == (run)->cap) {                                     \
        size_t c = (run)->cap ? (run)->cap * 2 : 16;                   \
        void *p = realloc((run)->arr, c * sizeof(*(run)->arr));        \
        if (!p)                                                        \
            break;                                                     \
        (run)->arr = p;                                                \
        (run)->cap = c;                                                \
    }                                                                  \
    (run)->arr[(run)->nb++] = (val);                                   \
} while (0)

#define FFG_REMOVE(run, arr, nb, val) do {                             \
    for (size_t i_ = (run)->nb; i_ > 0; i_--) {                        \
        if ((run)->arr[i_ - 1] == (val)) {                             \
            (run)->arr[i_ - 1] = (run)->arr[--(run)->nb];              \
            break;                                                     \
        }                                                              \
    }                                                                  \
} while (0)

void ffg_fd_track(int fd)
{
    Run *run = cur_run;
    if (!run || fd < 0)
        return;
    pthread_mutex_lock(&run->lock);
    FFG_PUSH(run, fds, nb_fds, cap_fds, fd);
    pthread_mutex_unlock(&run->lock);
}

void ffg_fd_untrack(int fd)
{
    Run *run = cur_run;
    if (!run)
        return;
    pthread_mutex_lock(&run->lock);
    FFG_REMOVE(run, fds, nb_fds, fd);
    pthread_mutex_unlock(&run->lock);
}

static FILE *track_file(FILE *f)
{
    Run *run = cur_run;
    if (f && run) {
        pthread_mutex_lock(&run->lock);
        FFG_PUSH(run, files, nb_files, cap_files, f);
        pthread_mutex_unlock(&run->lock);
    }
    return f;
}

FILE *ffg_fopen(const char *path, const char *mode)
{
    return track_file(fopen(path, mode));
}

FILE *ffg_fdopen(int fd, const char *mode)
{
    return track_file(fdopen(fd, mode));
}

int ffg_fclose(FILE *f)
{
    Run *run = cur_run;
    if (run) {
        pthread_mutex_lock(&run->lock);
        FFG_REMOVE(run, files, nb_files, f);
        pthread_mutex_unlock(&run->lock);
    }
    return fclose(f);
}

/* --- logging and stdio -------------------------------------------------- */

static FILE *devnull;
static pthread_once_t devnull_once = PTHREAD_ONCE_INIT;

static void open_devnull(void)
{
    devnull = fopen("/dev/null", "w");
}

static FILE **run_stdio(void)
{
    Run *run = cur_run;
    if (run && run->log)
        return &run->log;
    pthread_once(&devnull_once, open_devnull);
    return &devnull;
}

FILE **ffg_tool_stderr_ptr(void) { return run_stdio(); }
FILE **ffg_tool_stdout_ptr(void) { return run_stdio(); }

int ffg_tool_vprintf(const char *fmt, va_list ap)
{
    return vfprintf(*run_stdio(), fmt, ap);
}

int ffg_tool_printf(const char *fmt, ...)
{
    va_list ap;
    int ret;
    va_start(ap, fmt);
    ret = vfprintf(*run_stdio(), fmt, ap);
    va_end(ap);
    return ret;
}

int ffg_tool_puts(const char *s)
{
    FILE *f = *run_stdio();
    if (fputs(s, f) == EOF)
        return EOF;
    return fputc('\n', f) == EOF ? EOF : 1;
}

int ffg_tool_putchar(int c)
{
    return fputc(c, *run_stdio());
}

int *ffg_log_level_ptr(void)
{
    static int level = AV_LOG_INFO; /* threads outside any run */
    Run *run = cur_run;
    return run ? &run->log_level : &level;
}

void ffg_log_callback(void *avcl, int level, const char *fmt, va_list vl)
{
    Run *run = cur_run;
    char line[4096];

    if (!run || level > run->log_level)
        return;
    pthread_mutex_lock(&run->log_lock);
    if (run->log) {
        av_log_format_line2(avcl, level, fmt, vl, line, sizeof(line), &run->print_prefix);
        fputs(line, run->log);
    }
    pthread_mutex_unlock(&run->log_lock);
}

/* --- runs --------------------------------------------------------------- */

static uint8_t *unit_section(const char *name, size_t *size)
{
    Dl_info info;
    unsigned long sz = 0;
    uint8_t *p;

    *size = 0;
    if (!dladdr((const void *) &unit_section, &info) || !info.dli_fbase)
        return NULL;
    p = getsectiondata((const struct mach_header_64 *) info.dli_fbase,
                       "__DATA", name, &sz);
    *size = p ? sz : 0;
    return p;
}

/* Restores the tool's writable data to its load-time state (snapshotted
 * before the tool first runs, when nothing has written to it yet). */
static int reset_unit(Tool *tool)
{
    size_t size;
    uint8_t *data = unit_section(tool->data_sect, &size);
    uint8_t *bss;

    if (size) {
        if (!tool->data_init) {
            if (!(tool->data_init = malloc(size)))
                return -1;
            memcpy(tool->data_init, data, size);
        } else {
            memcpy(data, tool->data_init, size);
        }
    }
    bss = unit_section(tool->bss_sect, &size);
    if (size)
        memset(bss, 0, size);
    return 0;
}

static void *tool_main_thread(void *arg)
{
    Tool *tool = arg;
    tool->run.main_ret = tool->main(tool->argc, tool->argv);
    return NULL;
}

/* Takes tool->serial, giving up (-1) once *cancel is set. */
static int lock_serial(Tool *tool, const atomic_int *cancel)
{
    const struct timespec poll = { 0, 10 * 1000 * 1000 };

    while (pthread_mutex_trylock(&tool->serial)) {
        if (cancel && atomic_load(cancel))
            return -1;
        nanosleep(&poll, NULL);
    }
    return 0;
}

static int run_tool(Tool *tool, int argc, const char *const *argv,
                    const char *log_path, const atomic_int *cancel)
{
    Run *run = &tool->run;
    pthread_attr_t attr;
    pthread_t main_thread;
    int cancelled = 0, ret;

    if (argc < 1 || !argv)
        return 1;

    if (lock_serial(tool, cancel) < 0)
        return 255;

    run->threads = NULL;
    run->live = 0;
    run->exited = 0;
    run->exit_code = 0;
    run->main_ret = 0;
    atomic_store(&run->abandon, 0);
    atomic_store(&run->interrupted, 0);
    run->nb_fds = 0;
    run->nb_files = 0;
    run->log_level = AV_LOG_INFO;
    run->print_prefix = 1;
    run->log = fopen(log_path ? log_path : "/dev/null", "a");
    if (!run->log) {
        pthread_mutex_unlock(&tool->serial);
        return 1;
    }
    setvbuf(run->log, NULL, _IOLBF, 0);

    ret = 1;
    tool->argc = argc;
    tool->argv = calloc((size_t) argc + 1, sizeof(char *));
    if (!tool->argv)
        goto end;
    for (int i = 0; i < argc; i++)
        if (!(tool->argv[i] = strdup(argv[i] ? argv[i] : "")))
            goto end;

    if (reset_unit(tool) < 0)
        goto end;

    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, FFG_MAIN_STACK);
    ret = create_tracked(run, &main_thread, &attr, tool_main_thread, tool);
    pthread_attr_destroy(&attr);
    if (ret) {
        fprintf(run->log, "%s: could not start: %s\n", argv[0], strerror(ret));
        ret = 1;
        goto end;
    }

    pthread_mutex_lock(&run->lock);
    while (run->live > 0) {
        struct timespec ts;
        if (!cancelled && cancel && atomic_load(cancel)) {
            cancelled = 1;
            atomic_store(&run->interrupted, 1);
            if (!tool->cancel)
                atomic_store(&run->abandon, 1);
            pthread_mutex_unlock(&run->lock);
            if (tool->cancel)
                tool->cancel();
            pthread_mutex_lock(&run->lock);
            continue;
        }
        ts = deadline(cancel && !cancelled ? FFG_POLL_NS / 5 : FFG_POLL_NS);
        pthread_cond_timedwait(&run->cond, &run->lock, &ts);
    }
    pthread_mutex_unlock(&run->lock);

    /* Every fftools thread has ended; join the ones the tool did not. */
    while (run->threads) {
        Thread *th = run->threads;
        run->threads = th->next;
        if (!th->joined)
            pthread_join(th->thread, NULL);
        free(th);
    }
    for (size_t i = 0; i < run->nb_fds; i++)
        close(run->fds[i]);
    run->nb_fds = 0;
    for (size_t i = 0; i < run->nb_files; i++)
        fclose(run->files[i]);
    run->nb_files = 0;

    ret = cancelled   ? 255 :
          run->exited ? run->exit_code :
                        run->main_ret & 0xff;

end:
    if (tool->argv) {
        for (int i = 0; i < argc; i++)
            free(tool->argv[i]);
        free(tool->argv);
        tool->argv = NULL;
    }
    pthread_mutex_lock(&run->log_lock);
    fclose(run->log);
    run->log = NULL;
    pthread_mutex_unlock(&run->log_lock);
    pthread_mutex_unlock(&tool->serial);
    return ret;
}

FFG_API int ffglitch_ffgac_run(int argc, const char *const *argv,
                               const char *log_path, const atomic_int *cancel)
{
    return run_tool(&tool_ffgac, argc, argv, log_path, cancel);
}

FFG_API int ffglitch_ffedit_run(int argc, const char *const *argv,
                                const char *log_path, const atomic_int *cancel)
{
    return run_tool(&tool_ffedit, argc, argv, log_path, cancel);
}
