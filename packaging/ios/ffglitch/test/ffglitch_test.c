/* Host/simulator test for FFglitch.framework (packaging/ios/ffglitch/test/run.sh).
 *
 *   ffglitch_test mosh IN MOSH_JS OUT.m2v
 *       mpeg2-mosh's chain in one process: ffgac -> pipe -> ffedit -> pipe -> OUT
 *   ffglitch_test mvscript IN SCRIPT AMOUNT OUT.m2v
 *       mv-script's chain (AMOUNT 0 = no -sp)
 *   ffglitch_test mangle IN SCRIPT ENC.avi GLITCHED.avi
 *       mv-mangle's file-based ffgac and ffedit invocations
 *   ffglitch_test errors IN LONG_IN MOSH_JS WORKDIR
 *       failure paths return nonzero without killing the process, cancel
 *       returns 255, and a good run still works afterwards
 *   ffglitch_test ffmpeg IN MOSH_JS OUT.mkv   (built with -DWITH_GLITCH_FFMPEG)
 *       ffgac -> ffedit -> gb_ffmpeg_run (FFmpeg 8.1) concurrently
 *
 * Logs go to $FFG_TEST_LOGDIR (default /tmp) as <tool>-<n>.log. */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <FFglitch/ffglitch.h>
#ifdef WITH_GLITCH_FFMPEG
#include <GlitchFFmpeg/gb_ffmpeg.h>
#endif

typedef int (*ToolFn)(int, const char *const *, const char *, const atomic_int *);

#define MAX_ARGS 64

typedef struct Job {
    ToolFn fn;
    const char *name;
    char *argv[MAX_ARGS];
    int argc;
    char log[1024];
    const atomic_int *cancel;
    int close_fds[2];
    int ret;
    atomic_int done;
    double end;
    pthread_t thread;
} Job;

static int failures;
static int log_seq;

#define CHECK(cond, ...) do {                                        \
    if (!(cond)) {                                                   \
        failures++;                                                  \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);         \
        fprintf(stderr, __VA_ARGS__);                                \
        fputc('\n', stderr);                                         \
    }                                                                \
} while (0)

static const char *logdir(void)
{
    const char *d = getenv("FFG_TEST_LOGDIR");
    return d ? d : "/tmp";
}

/* Builds a job from a NULL-terminated list; "@R<n>"/"@W<n>" become pipe:<fd>. */
static void job_init(Job *j, ToolFn fn, const char *name, const int *fds, ...)
{
    va_list ap;
    const char *a;
    memset(j, 0, sizeof(*j));
    j->fn = fn;
    j->name = name;
    j->close_fds[0] = j->close_fds[1] = -1;
    snprintf(j->log, sizeof(j->log), "%s/%s-%d.log", logdir(), name, ++log_seq);
    unlink(j->log);
    va_start(ap, fds);
    while ((a = va_arg(ap, const char *)) && j->argc < MAX_ARGS - 1) {
        char buf[64];
        if (a[0] == '@' && (a[1] == 'R' || a[1] == 'W')) {
            int idx = (a[2] - '1') * 2 + (a[1] == 'W');
            snprintf(buf, sizeof(buf), "pipe:%d", fds[idx]);
            a = buf;
        }
        j->argv[j->argc++] = strdup(a);
    }
    va_end(ap);
}

static void job_free(Job *j)
{
    for (int i = 0; i < j->argc; i++)
        free(j->argv[i]);
}

static double now(void);

static void *job_main(void *p)
{
    Job *j = p;
    j->ret = j->fn(j->argc, (const char *const *) j->argv, j->log, j->cancel);
    for (int i = 0; i < 2; i++)
        if (j->close_fds[i] >= 0)
            close(j->close_fds[i]);
    j->end = now();
    atomic_store(&j->done, 1);
    return NULL;
}

static void job_start(Job *j)
{
    pthread_create(&j->thread, NULL, job_main, j);
}

static int job_wait(Job *j)
{
    pthread_join(j->thread, NULL);
    if (j->ret != 0)
        fprintf(stderr, "  %s returned %d (log %s)\n", j->name, j->ret, j->log);
    return j->ret;
}

static int job_run(Job *j)
{
    job_start(j);
    return job_wait(j);
}

/* Copies fd to path until EOF; returns the byte count (-1 on error). */
static long long drain(int fd, const char *path)
{
    char buf[65536];
    long long total = 0;
    FILE *f = path ? fopen(path, "wb") : NULL;
    ssize_t n;
    if (path && !f)
        return -1;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        if (f)
            fwrite(buf, 1, (size_t) n, f);
        total += n;
    }
    if (f)
        fclose(f);
    return n < 0 ? -1 : total;
}

static void make_pipes(int *fds, int n)
{
    for (int i = 0; i < n; i++)
        if (pipe(fds + 2 * i) < 0) {
            perror("pipe");
            exit(2);
        }
}

static int files_equal(const char *a, const char *b)
{
    FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
    int ca, cb, eq = fa && fb;
    while (eq) {
        ca = getc(fa);
        cb = getc(fb);
        if (ca != cb)
            eq = 0;
        if (ca == EOF || cb == EOF)
            break;
    }
    if (fa)
        fclose(fa);
    if (fb)
        fclose(fb);
    return eq;
}

static long long file_size(const char *path)
{
    struct stat st;
    return stat(path, &st) < 0 ? -1 : (long long) st.st_size;
}

/* ffgac (args as mpeg2-mosh/mv-script) -> ffedit (EDIT_ARGS...) -> out.
 * Returns 0 if both tools succeed and the output is non-empty. */
typedef struct Chain {
    Job gac, edit;
    int fds[4];
    long long bytes;
} Chain;

static void chain_start(Chain *c, const char *in, const atomic_int *cancel)
{
    make_pipes(c->fds, 2);
    job_init(&c->gac, ffglitch_ffgac_run, "ffgac", c->fds,
             "ffgac", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", in, "-an",
             "-mpv_flags", "+nopimb+forcemv", "-qscale:v", "0", "-g", "max", "-bf", "0",
             "-sc_threshold", "max", "-vcodec", "mpeg2video", "-f", "rawvideo", "@W1", NULL);
    c->gac.cancel = cancel;
    c->gac.close_fds[0] = c->fds[1];
}

static void chain_run_edit(Chain *c, const char *out)
{
    c->edit.close_fds[0] = c->fds[0];
    c->edit.close_fds[1] = c->fds[3];
    job_start(&c->gac);
    job_start(&c->edit);
    c->bytes = drain(c->fds[2], out);
    close(c->fds[2]);
    job_wait(&c->gac);
    job_wait(&c->edit);
}

static int mosh_chain(const char *in, const char *script, const char *out,
                      const atomic_int *cancel, Chain *c)
{
    chain_start(c, in, cancel);
    job_init(&c->edit, ffglitch_ffedit_run, "ffedit", c->fds,
             "ffedit", "-i", "@R1", "-f", "mv", "-s", script,
             "-sp", "{\"tail\":10,\"h_scale\":100,\"v_scale\":100,\"pan_x\":0,\"pan_y\":0}",
             "-o", "@W2", NULL);
    c->edit.cancel = cancel;
    chain_run_edit(c, out);
    job_free(&c->gac);
    job_free(&c->edit);
    return c->gac.ret == 0 && c->edit.ret == 0 && c->bytes > 0 ? 0 : 1;
}

static int cmd_mosh(int argc, char **argv)
{
    Chain c;
    if (argc != 5)
        return 2;
    CHECK(mosh_chain(argv[2], argv[3], argv[4], NULL, &c) == 0, "mosh chain failed");
    printf("mosh: ffgac=%d ffedit=%d bytes=%lld\n", c.gac.ret, c.edit.ret, c.bytes);
    return failures != 0;
}

static int cmd_mvscript(int argc, char **argv)
{
    Chain c;
    if (argc != 6)
        return 2;
    chain_start(&c, argv[2], NULL);
    if (strcmp(argv[4], "0"))
        job_init(&c.edit, ffglitch_ffedit_run, "ffedit", c.fds,
                 "ffedit", "-i", "@R1", "-f", "mv", "-s", argv[3], "-sp", argv[4], "-o", "@W2", NULL);
    else
        job_init(&c.edit, ffglitch_ffedit_run, "ffedit", c.fds,
                 "ffedit", "-i", "@R1", "-f", "mv", "-s", argv[3], "-o", "@W2", NULL);
    chain_run_edit(&c, argv[5]);
    CHECK(c.gac.ret == 0 && c.edit.ret == 0 && c.bytes > 0, "mv-script chain failed");
    printf("mvscript: ffgac=%d ffedit=%d bytes=%lld\n", c.gac.ret, c.edit.ret, c.bytes);
    return failures != 0;
}

static int cmd_mangle(int argc, char **argv)
{
    Job j;
    if (argc != 6)
        return 2;
    job_init(&j, ffglitch_ffgac_run, "ffgac", NULL,
             "ffgac", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", argv[2], "-an",
             "-flags", "+bitexact", "-fflags", "+bitexact",
             "-mpv_flags", "+forcemv+nopimb", "-qscale:v", "3", "-g", "12",
             "-vcodec", "mpeg4", "-f", "avi", "-y", argv[4], NULL);
    CHECK(job_run(&j) == 0, "mangle ffgac failed");
    job_free(&j);
    job_init(&j, ffglitch_ffedit_run, "ffedit", NULL,
             "ffedit", "-t", "-i", argv[4], "-f", "mv", "-s", argv[3],
             "-sp", "{\"seed\":42,\"amount\":50}", "-o", argv[5], NULL);
    CHECK(job_run(&j) == 0, "mangle ffedit failed");
    job_free(&j);
    printf("mangle: enc=%lld glitched=%lld\n", file_size(argv[4]), file_size(argv[5]));
    return failures != 0;
}

static void write_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int count_open_fds(void)
{
    int n = 0;
    for (int fd = 0; fd < 1024; fd++)
        if (fcntl(fd, F_GETFD) != -1)
            n++;
    return n;
}

static int edit_file(const char *in, const char *script, const char *out,
                     const atomic_int *cancel)
{
    Job j;
    int ret;
    job_init(&j, ffglitch_ffedit_run, "ffedit", NULL,
             "ffedit", "-y", "-i", in, "-f", "mv", "-s", script, "-o", out, NULL);
    j.cancel = cancel;
    ret = job_run(&j);
    job_free(&j);
    return ret;
}

typedef struct Canceller {
    atomic_int *flag;
    double delay;
} Canceller;

static void *cancel_later(void *p)
{
    Canceller *c = p;
    usleep((useconds_t) (c->delay * 1e6));
    atomic_store(c->flag, 1);
    return NULL;
}

static int cmd_errors(int argc, char **argv)
{
    const char *in, *longin, *mosh, *dir;
    char m2v[1024], out[1024], js[1024];
    Job j;
    Chain c;
    int ret, fds_before, fds_after;
    double t0;

    if (argc != 6)
        return 2;
    in = argv[2];
    longin = argv[3]; /* long enough to still be running when cancelled */
    mosh = argv[4];
    dir = argv[5];
    snprintf(m2v, sizeof(m2v), "%s/in.m2v", dir);
    snprintf(out, sizeof(out), "%s/out.m2v", dir);
    fds_before = count_open_fds();

    /* an MPEG-2 file for ffedit */
    job_init(&j, ffglitch_ffgac_run, "ffgac", NULL,
             "ffgac", "-hide_banner", "-y", "-i", in, "-an", "-mpv_flags", "+nopimb+forcemv",
             "-bf", "0", "-vcodec", "mpeg2video", "-f", "rawvideo", m2v, NULL);
    CHECK(job_run(&j) == 0, "ffgac to file");
    job_free(&j);

    /* missing input */
    job_init(&j, ffglitch_ffgac_run, "ffgac", NULL,
             "ffgac", "-i", "/nonexistent/in.mkv", "-f", "rawvideo", "-y", out, NULL);
    ret = job_run(&j);
    job_free(&j);
    CHECK(ret != 0, "ffgac missing input returned 0");
    printf("errors: ffgac missing input -> %d\n", ret);
    ret = edit_file("/nonexistent/in.m2v", mosh, out, NULL);
    CHECK(ret != 0, "ffedit missing input returned 0");
    printf("errors: ffedit missing input -> %d\n", ret);

    /* bad script path */
    ret = edit_file(m2v, "/nonexistent/script.js", out, NULL);
    CHECK(ret != 0, "ffedit bad script path returned 0");
    printf("errors: ffedit bad script path -> %d\n", ret);

    /* JS exception in setup() and in glitch_frame() */
    snprintf(js, sizeof(js), "%s/throw_setup.js", dir);
    write_file(js, "export function setup(args) { throw new Error('boom in setup'); }\n"
                   "export function glitch_frame(frame) {}\n");
    ret = edit_file(m2v, js, out, NULL);
    CHECK(ret != 0, "ffedit setup() exception returned 0");
    printf("errors: ffedit setup() exception -> %d\n", ret);

    snprintf(js, sizeof(js), "%s/throw_frame.js", dir);
    write_file(js, "export function setup(args) { args.features = ['mv']; }\n"
                   "export function glitch_frame(frame) { throw new Error('boom in glitch_frame'); }\n");
    ret = edit_file(m2v, js, out, NULL);
    CHECK(ret != 0, "ffedit glitch_frame() exception returned 0");
    printf("errors: ffedit glitch_frame() exception -> %d\n", ret);

    /* std.exit() from a script */
    snprintf(js, sizeof(js), "%s/exit.js", dir);
    write_file(js, "import * as std from 'std';\n"
                   "export function setup(args) { args.features = ['mv']; }\n"
                   "export function glitch_frame(frame) { std.exit(7); }\n");
    ret = edit_file(m2v, js, out, NULL);
    CHECK(ret == 7, "ffedit std.exit(7) returned %d", ret);
    printf("errors: ffedit std.exit(7) -> %d\n", ret);

    /* process spawning is refused */
    snprintf(js, sizeof(js), "%s/exec.js", dir);
    write_file(js, "import * as os from 'os';\n"
                   "export function setup(args) { args.features = ['mv']; os.exec(['/usr/bin/true']); }\n"
                   "export function glitch_frame(frame) {}\n");
    ret = edit_file(m2v, js, out, NULL);
    CHECK(ret != 0, "ffedit os.exec returned 0");
    printf("errors: ffedit os.exec -> %d\n", ret);

    /* a script that never returns: cancel */
    {
        atomic_int flag = 0;
        Canceller cc = { &flag, 0.5 };
        pthread_t t;
        snprintf(js, sizeof(js), "%s/loop.js", dir);
        write_file(js, "export function setup(args) { args.features = ['mv']; }\n"
                       "export function glitch_frame(frame) { for (;;) {} }\n");
        pthread_create(&t, NULL, cancel_later, &cc);
        t0 = now();
        ret = edit_file(m2v, js, out, &flag);
        pthread_join(t, NULL);
        CHECK(ret == 255, "ffedit cancelled infinite loop returned %d", ret);
        printf("errors: ffedit cancel (infinite loop script) -> %d after %.2fs\n", ret, now() - t0);
    }

    /* a run queued behind a running run of the same tool returns 255 within
       ~100 ms of its cancel, without waiting for the running one */
    {
        atomic_int flag_long = 0, flag_queued = 0;
        Job jl, jq;
        double dt;
        int waiting, long_running;

        /* ffedit: the never-returning script holds the ffedit lock */
        job_init(&jl, ffglitch_ffedit_run, "ffedit", NULL,
                 "ffedit", "-y", "-i", m2v, "-f", "mv", "-s", js, "-o", out, NULL);
        jl.cancel = &flag_long;
        job_init(&jq, ffglitch_ffedit_run, "ffedit", NULL,
                 "ffedit", "-y", "-i", m2v, "-f", "mv", "-s", mosh, "-o", out, NULL);
        jq.cancel = &flag_queued;
        job_start(&jl);
        usleep(300 * 1000);
        job_start(&jq);
        usleep(300 * 1000);
        waiting = !atomic_load(&jq.done);
        t0 = now();
        atomic_store(&flag_queued, 1);
        while (!atomic_load(&jq.done) && now() - t0 < 5)
            usleep(1000);
        dt = atomic_load(&jq.done) ? jq.end - t0 : -1;
        long_running = !atomic_load(&jl.done);
        CHECK(waiting && long_running && jq.ret == 255 && dt >= 0 && dt < 0.1,
              "queued ffedit: waiting %d, ret %d after %.3fs, long run still going %d",
              waiting, jq.ret, dt, long_running);
        printf("errors: queued ffedit cancelled -> %d after %.3fs\n", jq.ret, dt);
        atomic_store(&flag_long, 1);
        job_wait(&jl);
        job_wait(&jq);
        CHECK(jl.ret == 255, "long ffedit then cancelled returned %d", jl.ret);
        job_free(&jl);
        job_free(&jq);

        /* ffgac: a long encode (-re: the 60 s input at its frame rate) holds
           the ffgac lock */
        atomic_store(&flag_long, 0);
        atomic_store(&flag_queued, 0);
        job_init(&jl, ffglitch_ffgac_run, "ffgac", NULL,
                 "ffgac", "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-re", "-i", longin,
                 "-an", "-vcodec", "mpeg2video", "-f", "null", "-", NULL);
        jl.cancel = &flag_long;
        job_init(&jq, ffglitch_ffgac_run, "ffgac", NULL,
                 "ffgac", "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", in,
                 "-an", "-vcodec", "mpeg2video", "-f", "null", "-", NULL);
        jq.cancel = &flag_queued;
        job_start(&jl);
        usleep(300 * 1000);
        job_start(&jq);
        usleep(300 * 1000);
        waiting = !atomic_load(&jq.done);
        t0 = now();
        atomic_store(&flag_queued, 1);
        while (!atomic_load(&jq.done) && now() - t0 < 5)
            usleep(1000);
        dt = atomic_load(&jq.done) ? jq.end - t0 : -1;
        long_running = !atomic_load(&jl.done);
        CHECK(waiting && long_running && jq.ret == 255 && dt >= 0 && dt < 0.1,
              "queued ffgac: waiting %d, ret %d after %.3fs, long run still going %d",
              waiting, jq.ret, dt, long_running);
        printf("errors: queued ffgac cancelled -> %d after %.3fs\n", jq.ret, dt);
        atomic_store(&flag_long, 1);
        job_wait(&jl);
        job_wait(&jq);
        CHECK(jl.ret == 255, "long ffgac then cancelled returned %d", jl.ret);
        job_free(&jl);
        job_free(&jq);
    }

    /* ffedit fails mid-chain: ffgac must get EPIPE (not SIGPIPE) and fail,
       not hang or kill us */
    snprintf(js, sizeof(js), "%s/throw_frame.js", dir);
    chain_start(&c, longin, NULL);
    job_init(&c.edit, ffglitch_ffedit_run, "ffedit", c.fds,
             "ffedit", "-i", "@R1", "-f", "mv", "-s", js, "-o", "@W2", NULL);
    chain_run_edit(&c, NULL);
    CHECK(c.edit.ret != 0 && c.gac.ret != 0, "chain with failing script: ffgac=%d ffedit=%d",
          c.gac.ret, c.edit.ret);
    printf("errors: chain with failing ffedit -> ffgac=%d ffedit=%d\n", c.gac.ret, c.edit.ret);
    job_free(&c.gac);
    job_free(&c.edit);

    /* cancel a whole chain mid-run */
    {
        atomic_int flag = 0;
        Canceller cc = { &flag, 0.5 };
        pthread_t t;
        pthread_create(&t, NULL, cancel_later, &cc);
        t0 = now();
        ret = mosh_chain(longin, mosh, NULL, &flag, &c);
        pthread_join(t, NULL);
        CHECK(c.gac.ret == 255 && c.edit.ret == 255,
              "cancelled chain: ffgac=%d ffedit=%d", c.gac.ret, c.edit.ret);
        printf("errors: cancelled chain -> ffgac=%d ffedit=%d after %.2fs\n",
               c.gac.ret, c.edit.ret, now() - t0);
    }

    /* the process survived all of that; good runs still work, twice in a
       row with identical output (globals are reset) */
    {
        char out2[1024];
        snprintf(out2, sizeof(out2), "%s/out2.m2v", dir);
        CHECK(mosh_chain(in, mosh, out, NULL, &c) == 0, "good chain after errors failed");
        CHECK(mosh_chain(in, mosh, out2, NULL, &c) == 0, "second good chain failed");
        ret = files_equal(out, out2);
        CHECK(ret && file_size(out) > 0, "repeated chain output differs");
        printf("errors: good chains after failures -> %lld bytes, repeat %s\n", file_size(out),
               ret ? "byte-identical" : "DIFFERENT");
    }

    fds_after = count_open_fds();
    CHECK(fds_after == fds_before, "fd leak: %d open before, %d after", fds_before, fds_after);
    printf("errors: open fds before %d after %d\n", fds_before, fds_after);
    printf("errors: %s\n", failures ? "FAILED" : "ok");
    return failures != 0;
}

#ifdef WITH_GLITCH_FFMPEG
static int gb_ffmpeg_tool(int argc, const char *const *argv, const char *log, const atomic_int *cancel)
{
    return gb_ffmpeg_run(argc, argv, log, cancel);
}

static int cmd_ffmpeg(int argc, char **argv)
{
    Chain c;
    Job mpeg;
    int fds[6];
    if (argc != 5)
        return 2;
    chain_start(&c, argv[2], NULL);
    memcpy(fds, c.fds, sizeof(c.fds));
    job_init(&c.edit, ffglitch_ffedit_run, "ffedit", c.fds,
             "ffedit", "-i", "@R1", "-f", "mv", "-s", argv[3],
             "-sp", "{\"tail\":10,\"h_scale\":100,\"v_scale\":100,\"pan_x\":0,\"pan_y\":0}",
             "-o", "@W2", NULL);
    c.edit.close_fds[0] = c.fds[0];
    c.edit.close_fds[1] = c.fds[3];
    job_init(&mpeg, gb_ffmpeg_tool, "ffmpeg", c.fds,
             "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "mpegvideo",
             "-i", "@R2", "-fflags", "+bitexact", "-flags:v", "+bitexact",
             "-map_metadata", "-1", "-map_chapters", "-1", "-c:v", "ffvhuff", "-y", argv[4], NULL);
    mpeg.close_fds[0] = c.fds[2];
    job_start(&c.gac);
    job_start(&c.edit);
    job_start(&mpeg);
    job_wait(&c.gac);
    job_wait(&c.edit);
    job_wait(&mpeg);
    CHECK(c.gac.ret == 0 && c.edit.ret == 0 && mpeg.ret == 0, "ffgac=%d ffedit=%d ffmpeg=%d",
          c.gac.ret, c.edit.ret, mpeg.ret);
    printf("ffmpeg: ffgac=%d ffedit=%d ffmpeg=%d out=%lld bytes\n",
           c.gac.ret, c.edit.ret, mpeg.ret, file_size(argv[4]));
    job_free(&c.gac);
    job_free(&c.edit);
    job_free(&mpeg);
    return failures != 0;
}
#endif

int main(int argc, char **argv)
{
    if (argc < 2)
        goto usage;
    if (!strcmp(argv[1], "mosh"))
        return cmd_mosh(argc, argv);
    if (!strcmp(argv[1], "mvscript"))
        return cmd_mvscript(argc, argv);
    if (!strcmp(argv[1], "mangle"))
        return cmd_mangle(argc, argv);
    if (!strcmp(argv[1], "errors"))
        return cmd_errors(argc, argv);
#ifdef WITH_GLITCH_FFMPEG
    if (!strcmp(argv[1], "ffmpeg"))
        return cmd_ffmpeg(argc, argv);
#endif
usage:
    fprintf(stderr, "usage: see the header of ffglitch_test.c\n");
    return 2;
}
