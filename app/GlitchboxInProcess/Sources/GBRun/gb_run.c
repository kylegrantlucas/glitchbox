#include "gb_run.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

#include <GlitchFFmpeg/gb_ffmpeg.h>
#include <FFglitch/ffglitch.h>

struct gbr_flag {
    atomic_int value;
};

gbr_flag *gbr_flag_new(void) {
    gbr_flag *f = malloc(sizeof *f);
    if (f) atomic_init(&f->value, 0);
    return f;
}

void gbr_flag_free(gbr_flag *flag) { free(flag); }

void gbr_flag_set(gbr_flag *flag) { atomic_store(&flag->value, 1); }

int gbr_flag_get(const gbr_flag *flag) { return atomic_load(&((gbr_flag *)flag)->value); }

int gbr_run(gbr_tool tool, int argc, const char *const *argv, const char *log_path, const gbr_flag *flag) {
    const atomic_int *cancel = &flag->value;
    switch (tool) {
    case GBR_FFMPEG: return gb_ffmpeg_run(argc, argv, log_path, cancel);
    case GBR_FFPROBE: return gb_ffprobe_run(argc, argv, log_path, cancel);
    case GBR_FFGAC: return ffglitch_ffgac_run(argc, argv, log_path, cancel);
    case GBR_FFEDIT: return ffglitch_ffedit_run(argc, argv, log_path, cancel);
    }
    return 1;
}

int gbr_pipe(int fds[2]) {
    if (pipe(fds) != 0) return errno;
    for (int i = 0; i < 2; i++) {
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
#ifdef F_SETNOSIGPIPE
        fcntl(fds[i], F_SETNOSIGPIPE, 1);
#endif
    }
    return 0;
}

static void ignore_sigpipe_once(void) { signal(SIGPIPE, SIG_IGN); }

void gbr_ignore_sigpipe(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, ignore_sigpipe_once);
}
