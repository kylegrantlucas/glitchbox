/*
 * Host/simulator test for GlitchFFmpeg.xcframework (gb_ffmpeg_run/gb_ffprobe_run).
 * Not part of the ios_ffmpeg stage. Run from the repository root after
 * `packaging/build.sh stage ios_ffmpeg`:
 *
 *   X=build/ios/xcframeworks/GlitchFFmpeg.xcframework
 *   LIBS="-lz -lbz2 -liconv -lc++ -framework AudioToolbox -framework CoreAudio
 *         -framework CoreFoundation -framework CoreMedia -framework CoreServices
 *         -framework CoreVideo -framework VideoToolbox"
 *   # macOS slice (compares a native filter's output with the macOS app's bundled ffmpeg):
 *   clang -O1 -target arm64-apple-macos26.0 -I$X/macos-arm64/Headers \
 *     packaging/ios/ffmpeg/test/test_gb_ffmpeg.c $X/macos-arm64/libGlitchFFmpeg.a $LIBS -o /tmp/gbff-test
 *   /tmp/gbff-test /tmp/gbff-work [REF_FFMPEG]
 *     e.g. REF_FFMPEG=/path/Glitchbox.app/Contents/Helpers/ffmpeg
 *   # simulator slice:
 *   clang -O1 -target arm64-apple-ios26.0-simulator -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) \
 *     -I$X/ios-arm64-simulator/Headers packaging/ios/ffmpeg/test/test_gb_ffmpeg.c \
 *     $X/ios-arm64-simulator/libGlitchFFmpeg.a $LIBS -o /tmp/gbff-test-sim
 *   xcrun simctl spawn <booted-device> /tmp/gbff-test-sim /tmp/gbff-work-sim
 *   # device slice: link check only (same command with -target arm64-apple-ios26.0,
 *   # -isysroot of iphoneos, and $X/ios-arm64).
 *
 * Prints one line per check and exits nonzero if any failed.
 */
#include <GlitchFFmpeg/gb_ffmpeg.h>
#include <libavutil/log.h>

#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static const char *work;
static int failures;

#define ARGC(a) ((int)(sizeof(a) / sizeof((a)[0])))

static void check(int ok, const char *fmt, ...)
{
    va_list vl;
    printf("%s ", ok ? "PASS" : "FAIL");
    va_start(vl, fmt);
    vprintf(fmt, vl);
    va_end(vl);
    printf("\n");
    fflush(stdout);
    if (!ok)
        failures++;
}

static char *path(const char *name)
{
    static _Thread_local char bufs[32][1024];
    static _Thread_local int next;
    char *b = bufs[next++ % 32];
    snprintf(b, sizeof(bufs[0]), "%s/%s", work, name);
    return b;
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static unsigned char *slurp(const char *p, size_t *size)
{
    FILE *f = fopen(p, "rb");
    unsigned char *buf;
    long n;
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc(n ? n : 1);
    if (fread(buf, 1, n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *size = n;
    return buf;
}

static int same_file(const char *a, const char *b)
{
    size_t na, nb;
    unsigned char *x = slurp(a, &na), *y = slurp(b, &nb);
    int same = x && y && na == nb && na > 0 && !memcmp(x, y, na);
    free(x);
    free(y);
    return same;
}

static long file_size(const char *p)
{
    struct stat st;
    return stat(p, &st) ? -1 : (long)st.st_size;
}

static void fd_snapshot(unsigned char open[1024])
{
    for (int fd = 0; fd < 1024; fd++)
        open[fd] = fcntl(fd, F_GETFD) != -1;
}

/* Number of descriptors open now that were not in BEFORE; prints them. */
static int new_fds(const unsigned char before[1024])
{
    int n = 0;
    for (int fd = 0; fd < 1024; fd++) {
        if (before[fd] || fcntl(fd, F_GETFD) == -1)
            continue;
        char p[1024] = "";
        struct stat st;
        fstat(fd, &st);
        if (fcntl(fd, F_GETPATH, p) == -1)
            snprintf(p, sizeof(p), "(no path, mode %o)", st.st_mode & S_IFMT);
        printf("     new fd %d: %s\n", fd, p);
        n++;
    }
    return n;
}

static int ff(const char *const *argv, int argc, const char *log, const atomic_int *cancel)
{
    return gb_ffmpeg_run(argc, argv, log, cancel);
}

/* ffvhuff MKV of a lavfi testsrc: the reference encode. */
static int encode_testsrc(const char *out, const char *log)
{
    const char *argv[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
        "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1",
        "-c:v", "ffvhuff", "-y", out };
    return ff(argv, ARGC(argv), log, NULL);
}

static int spawn_wait(const char *const *argv)
{
    pid_t pid;
    int status;
    char *envp[] = { NULL };
#if TARGET_OS_OSX
    if (posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, envp))
        return -1;
    if (waitpid(pid, &status, 0) < 0)
        return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
#else
    (void)pid; (void)status; (void)envp; (void)argv;
    return -1;
#endif
}

typedef struct CancelArgs {
    atomic_int *cancel;
    int ret;
    double end;
} CancelArgs;

static void *cancel_run(void *opaque)
{
    CancelArgs *a = opaque;
    const char *argv[] = { "ffmpeg", "-hide_banner", "-nostdin",
        "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30:duration=600",
        "-vf", "showinfo", "-c:v", "mpeg4", "-f", "null", "-" };
    a->ret = ff(argv, ARGC(argv), path("cancel.log"), a->cancel);
    a->end = now();
    return NULL;
}

typedef struct ThreadArgs {
    int index, ok;
} ThreadArgs;

static void *concurrent_run(void *opaque)
{
    ThreadArgs *t = opaque;
    char name[64], out[1024], log[1024], probe[1024];
    t->ok = 1;
    snprintf(name, sizeof(name), "thread%d.log", t->index);
    snprintf(log, sizeof(log), "%s", path(name));
    for (int i = 0; i < 2; i++) {
        snprintf(name, sizeof(name), "thread%d-%d.mkv", t->index, i);
        snprintf(out, sizeof(out), "%s", path(name));
        if (encode_testsrc(out, log) != 0 || !same_file(out, path("ref.mkv")))
            t->ok = 0;
        /* ffprobe shares the lock and the reset */
        snprintf(name, sizeof(name), "thread%d-%d.json", t->index, i);
        snprintf(probe, sizeof(probe), "%s", path(name));
        const char *pargv[] = { "ffprobe", "-v", "error", "-print_format", "json",
            "-show_streams", "-o", probe, out };
        size_t n = 0;
        char *json;
        if (gb_ffprobe_run(ARGC(pargv), pargv, log, NULL) != 0 ||
            !(json = (char *)slurp(probe, &n)) || !strstr(json, "\"codec_name\": \"ffvhuff\""))
            t->ok = 0;
        else
            free(json);
    }
    return NULL;
}

typedef struct PipeIO {
    int fd;
    const char *file;
    unsigned char *buf;
    size_t size;
} PipeIO;

static void *pipe_writer(void *opaque)
{
    PipeIO *p = opaque;
    size_t n;
    unsigned char *data = slurp(p->file, &n), *q = data;
    while (data && n > 0) {
        ssize_t w = write(p->fd, q, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            break;
        q += w;
        n -= w;
    }
    free(data);
    close(p->fd);
    return NULL;
}

static void *pipe_reader(void *opaque)
{
    PipeIO *p = opaque;
    size_t cap = 1 << 20;
    p->buf = malloc(cap);
    p->size = 0;
    for (;;) {
        if (p->size == cap)
            p->buf = realloc(p->buf, cap *= 2);
        ssize_t r = read(p->fd, p->buf + p->size, cap - p->size);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            break;
        p->size += r;
    }
    close(p->fd);
    return NULL;
}

typedef struct QueuedArgs {
    const char *const *argv;
    int argc;
    const char *log;
    atomic_int *cancel;
    atomic_int done;
    int ret;
    double end;
} QueuedArgs;

static void *queued_run(void *opaque)
{
    QueuedArgs *q = opaque;
    q->ret = ff(q->argv, q->argc, q->log, q->cancel);
    q->end = now();
    atomic_store(&q->done, 1);
    return NULL;
}

static atomic_int foreign_stop;

/* A host thread using libav while runs are active. */
static void *foreign_logger(void *opaque)
{
    (void)opaque;
    for (int i = 0; !atomic_load(&foreign_stop); i++) {
        av_log(NULL, AV_LOG_ERROR, "GBTEST-FOREIGN-ERROR %d\n", i);
        av_log(NULL, AV_LOG_INFO, "GBTEST-FOREIGN-INFO %d\n", i);
        av_log(NULL, AV_LOG_DEBUG, "GBTEST-FOREIGN-DEBUG %d\n", i);
        usleep(20 * 1000);
    }
    return NULL;
}

static int file_has(const char *p, const char *needle)
{
    size_t n = 0;
    char *txt = (char *)slurp(p, &n);
    int has;
    if (!txt)
        return 0;
    txt = realloc(txt, n + 1);
    txt[n] = 0;
    has = strstr(txt, needle) != NULL;
    free(txt);
    return has;
}

int main(int argc, char **argv)
{
    const char *ref_ffmpeg = argc > 2 ? argv[2] : NULL;
    char errlog[1024];
    int ret;
    static unsigned char fds_start[1024], fds_mid[1024];

    if (argc < 2) {
        fprintf(stderr, "usage: %s WORKDIR [REF_FFMPEG]\n", argv[0]);
        return 2;
    }
    work = argv[1];
    mkdir(work, 0755);
    setvbuf(stdout, NULL, _IOLBF, 0);

    /* Anything the runs print to the real stderr lands here (must stay empty). */
    snprintf(errlog, sizeof(errlog), "%s/process-stderr.txt", work);
    int errfd = open(errlog, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int saved_stderr = dup(2);
    dup2(errfd, 2);
    close(errfd);
    fd_snapshot(fds_start);

    /* 1. testsrc -> ffvhuff MKV, three times: identical bytes */
    ret = encode_testsrc(path("ref.mkv"), path("ref.log"));
    check(ret == 0 && file_size(path("ref.mkv")) > 0, "testsrc -> ffvhuff mkv (ret %d, %ld bytes)", ret, file_size(path("ref.mkv")));
    for (int i = 0; i < 3; i++) {
        char name[32];
        snprintf(name, sizeof(name), "repeat%d.mkv", i);
        ret = encode_testsrc(path(name), path("repeat.log"));
        check(ret == 0 && same_file(path(name), path("ref.mkv")), "repeat %d identical to first run (ret %d)", i + 1, ret);
    }

    /* 2. a native filter's output against the macOS app's bundled ffmpeg */
    if (ref_ffmpeg) {
        const char *a[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
            "-i", path("ref.mkv"), "-vf", "rgbashift=rh=4:bv=-3,lagfun=decay=0.9,format=yuv420p",
            "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1",
            "-c:v", "ffvhuff", "-y", path("native-filters.mkv"), NULL };
        ret = ff(a, ARGC(a) - 1, path("native.log"), NULL);
        a[0] = ref_ffmpeg;
        a[18] = path("native-filters.macos.mkv");
        int rret = spawn_wait(a);
        int same = ret == 0 && rret == 0 && same_file(path("native-filters.mkv"), path("native-filters.macos.mkv"));
        printf("%s rgbashift+lagfun byte-identical to macOS bundled ffmpeg: %s (ret %d, ref ret %d)\n",
               same ? "INFO" : "DIFF", same ? "yes" : "no", ret, rret);
    }

    /* 3. h264_videotoolbox */
    {
        const char *a[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
            "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", "-y", path("vt.mp4") };
        ret = ff(a, ARGC(a), path("vt.log"), NULL);
        check(ret == 0 && file_size(path("vt.mp4")) > 0, "h264_videotoolbox encode (ret %d, %ld bytes)", ret, file_size(path("vt.mp4")));
    }

    /* 4. ffprobe JSON via -o */
    {
        const char *a[] = { "ffprobe", "-v", "error", "-print_format", "json",
            "-show_format", "-show_streams", "-o", path("probe.json"), path("vt.mp4") };
        ret = gb_ffprobe_run(ARGC(a), a, path("probe.log"), NULL);
        size_t n = 0;
        char *json = (char *)slurp(path("probe.json"), &n);
        int ok = ret == 0 && json && strstr(json, "\"codec_name\": \"h264\"") && strstr(json, "\"format_name\"");
        check(ok, "ffprobe -print_format json -show_format -show_streams -o (ret %d, %zu bytes)", ret, n);
        free(json);
    }

    /* 5. invalid commands: nonzero, process survives, next run still fine */
    {
        const char *a[] = { "ffmpeg", "-hide_banner", "-i", path("does-not-exist.mkv"), "-y", path("never.mkv") };
        ret = ff(a, ARGC(a), path("invalid.log"), NULL);
        check(ret != 0, "missing input returns nonzero (%d)", ret);
        const char *b[] = { "ffmpeg", "-no_such_option", "1" };
        ret = ff(b, ARGC(b), path("invalid.log"), NULL);
        check(ret != 0, "unknown option returns nonzero (%d)", ret);
        const char *c[] = { "ffprobe", "-v", "error", path("does-not-exist.mkv") };
        ret = gb_ffprobe_run(ARGC(c), c, path("invalid.log"), NULL);
        check(ret == 1, "ffprobe on missing input returns 1 (%d)", ret);
        const char *d[] = { "ffprobe", "-v", "error", "-show_streams", "-of", "json", "-o", path("x.json"),
            "-codec:v", "no_such_decoder", path("ref.mkv") };
        ret = gb_ffprobe_run(ARGC(d), d, path("invalid.log"), NULL);
        check(ret != 0, "ffprobe with unknown decoder returns nonzero (%d)", ret);
        const char *v[] = { "ffmpeg", "-version" };
        ret = ff(v, ARGC(v), path("version.log"), NULL);
        size_t n = 0;
        char *txt = (char *)slurp(path("version.log"), &n);
        check(ret == 0 && txt && strstr(txt, "ffmpeg version 8.1.2"), "-version goes to the log (ret %d)", ret);
        free(txt);
        ret = encode_testsrc(path("after-invalid.mkv"), path("after-invalid.log"));
        check(ret == 0 && same_file(path("after-invalid.mkv"), path("ref.mkv")), "run after failures still identical (ret %d)", ret);
    }

    /* 6. cancel mid-run */
    {
        atomic_int cancel = 0;
        CancelArgs ca = { &cancel, -1, 0 };
        pthread_t th;
        pthread_create(&th, NULL, cancel_run, &ca);
        usleep(1500 * 1000);
        double t0 = now();
        atomic_store(&cancel, 1);
        pthread_join(th, NULL);
        check(ca.ret == 255 && ca.end - t0 < 2.0, "cancel returns 255 (%d) after %.3f s", ca.ret, ca.end - t0);
        ret = encode_testsrc(path("after-cancel.mkv"), path("after-cancel.log"));
        check(ret == 0 && same_file(path("after-cancel.mkv"), path("ref.mkv")), "run after cancel identical (ret %d)", ret);
    }

    /* 7. two threads at once: serialized, outputs uncorrupted */
    {
        ThreadArgs t[2] = { { 0, 0 }, { 1, 0 } };
        pthread_t th[2];
        for (int i = 0; i < 2; i++)
            pthread_create(&th[i], NULL, concurrent_run, &t[i]);
        for (int i = 0; i < 2; i++)
            pthread_join(th[i], NULL);
        check(t[0].ok && t[1].ok, "two concurrent threads x (ffmpeg + ffprobe) x2 all identical to reference");
    }

    /* 8. pipe:N input and output with host pipe() descriptors */
    {
        int in[2], out[2];
        pipe(in);
        pipe(out);
        char rin[16], wout[16];
        snprintf(rin, sizeof(rin), "pipe:%d", in[0]);
        snprintf(wout, sizeof(wout), "pipe:%d", out[1]);
        PipeIO w = { in[1], path("ref.mkv"), NULL, 0 }, r = { out[0], NULL, NULL, 0 };
        pthread_t tw, tr;
        pthread_create(&tw, NULL, pipe_writer, &w);
        pthread_create(&tr, NULL, pipe_reader, &r);
        const char *a[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
            "-f", "matroska", "-i", rin, "-f", "rawvideo", "-pix_fmt", "rgb24", wout };
        ret = ff(a, ARGC(a), path("pipe.log"), NULL);
        close(in[0]);
        close(out[1]);
        pthread_join(tw, NULL);
        pthread_join(tr, NULL);
        const char *b[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
            "-i", path("ref.mkv"), "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", path("ref.rgb") };
        int ret2 = ff(b, ARGC(b), path("pipe.log"), NULL);
        size_t n = 0;
        unsigned char *expect = slurp(path("ref.rgb"), &n);
        check(ret == 0 && ret2 == 0 && expect && n == r.size && n == 320 * 240 * 3 * 50 && !memcmp(expect, r.buf, n),
              "pipe:%d in -> pipe:%d out (ret %d, %zu bytes, expected %zu)", in[0], out[1], ret, r.size, n);
        free(expect);
        free(r.buf);
    }

    /* 9. a run queued behind a long run returns 255 promptly when cancelled */
    {
        atomic_int cancel_long = 0, cancel_queued = 0;
        CancelArgs ca = { &cancel_long, -1, 0 };
        pthread_t th_long, th_q;
        const char *a[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2", "-f", "null", "-" };
        QueuedArgs q = { a, ARGC(a), path("queued.log"), &cancel_queued, 0, -1, 0 };
        pthread_create(&th_long, NULL, cancel_run, &ca);
        usleep(500 * 1000);
        pthread_create(&th_q, NULL, queued_run, &q);
        usleep(300 * 1000);
        int waiting = !atomic_load(&q.done);
        double t0 = now();
        atomic_store(&cancel_queued, 1);
        while (!atomic_load(&q.done) && now() - t0 < 5)
            usleep(1000);
        double dt = q.done ? q.end - t0 : -1;
        int long_running = ca.end == 0;
        check(waiting && long_running && q.done && q.ret == 255 && dt < 0.1,
              "ffmpeg run queued behind a long run returns 255 (%d) %.3f s after cancel (long run still going: %d)",
              q.ret, dt, long_running);
        atomic_store(&cancel_long, 1);
        pthread_join(th_long, NULL);
        pthread_join(th_q, NULL);
        check(ca.ret == 255, "long run then cancelled (%d)", ca.ret);
    }

    /* 10. log routing: lines from a host thread never land in a run's log
     * (they go to stderr at the host's level); the run's own lines do */
    {
        char foreign[1024];
        snprintf(foreign, sizeof(foreign), "%s", path("foreign-stderr.txt"));
        int ffd = open(foreign, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        int run_stderr = dup(2);
        dup2(ffd, 2);
        close(ffd);
        av_log_set_level(AV_LOG_INFO);

        atomic_int cancel = 0;
        CancelArgs ca = { &cancel, -1, 0 };
        pthread_t th_f, th_long;
        atomic_store(&foreign_stop, 0);
        unlink(path("cancel.log"));
        pthread_create(&th_f, NULL, foreign_logger, NULL);
        pthread_create(&th_long, NULL, cancel_run, &ca);
        usleep(1500 * 1000);
        atomic_store(&cancel, 1);
        pthread_join(th_long, NULL);
        const char *m[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
            "-i", path("does-not-exist.mkv"), "-f", "null", "-" };
        unlink(path("routing-error.log"));
        ret = ff(m, ARGC(m), path("routing-error.log"), NULL);
        atomic_store(&foreign_stop, 1);
        pthread_join(th_f, NULL);
        fflush(stderr);
        dup2(run_stderr, 2);
        close(run_stderr);

        check(ca.ret == 255 && file_has(path("cancel.log"), "Output #0") &&
              file_has(path("cancel.log"), "[Parsed_showinfo_0 @") &&
              !file_has(path("cancel.log"), "GBTEST-FOREIGN"),
              "run log has the run's main and filter-thread lines and no host-thread lines");
        check(ret != 0 && file_has(path("routing-error.log"), "does-not-exist.mkv") &&
              !file_has(path("routing-error.log"), "GBTEST-FOREIGN"),
              "a run's own error reaches its log while a host thread logs (ret %d)", ret);
        check(file_has(foreign, "GBTEST-FOREIGN-ERROR") && file_has(foreign, "GBTEST-FOREIGN-INFO") &&
              !file_has(foreign, "GBTEST-FOREIGN-DEBUG"),
              "host-thread lines go to stderr at the host's level (info), not the run's");
    }

    /* System frameworks (VideoToolbox, CoreMedia) may keep a descriptor for the
     * life of the process once first used; that must not grow per run. */
    printf("INFO descriptors opened since start: %d\n", new_fds(fds_start));
    fd_snapshot(fds_mid);
    for (int i = 0; i < 3; i++) {
        const char *a[] = { "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=1",
            "-c:v", "h264_videotoolbox", "-y", path("fd-vt.mp4") };
        const char *p[] = { "ffprobe", "-v", "error", "-of", "json", "-show_streams",
            "-o", path("fd.json"), path("fd-vt.mp4") };
        ff(a, ARGC(a), path("fd.log"), NULL);
        encode_testsrc(path("fd.mkv"), path("fd.log"));
        gb_ffprobe_run(ARGC(p), p, path("fd.log"), NULL);
    }
    check(new_fds(fds_mid) == 0, "3 more rounds of runs leave no new descriptors open");

    fflush(stderr);
    dup2(saved_stderr, 2);
    close(saved_stderr);
    check(file_size(errlog) == 0, "nothing written to the process's stderr (%ld bytes)", file_size(errlog));

    printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
