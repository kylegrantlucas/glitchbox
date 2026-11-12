/*
 * Run tags for threads (gb_thread_tag.h). Its own object, linked into
 * libGlitchFFmpeg.a and passed to FFmpeg's configure (--extra-libs), whose
 * link tests otherwise could not resolve the gb_pthread_create that the
 * force-included header puts into x264.
 */
#define GB_THREAD_TAG_IMPL
#include "gb_thread_tag.h"

#include <errno.h>
#include <stdlib.h>

_Thread_local unsigned gb_thread_run;

typedef struct ThreadStart {
    void *(*start)(void *);
    void *arg;
    unsigned run;
} ThreadStart;

static void *thread_start(void *opaque)
{
    ThreadStart ts = *(ThreadStart *)opaque;
    free(opaque);
    gb_thread_run = ts.run;
    return ts.start(ts.arg);
}

int gb_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                      void *(*start)(void *), void *arg)
{
    ThreadStart *ts;
    int ret;

    if (!gb_thread_run)
        return pthread_create(thread, attr, start, arg);
    if (!(ts = malloc(sizeof(*ts))))
        return EAGAIN;
    ts->start = start;
    ts->arg = arg;
    ts->run = gb_thread_run;
    ret = pthread_create(thread, attr, thread_start, ts);
    if (ret)
        free(ts);
    return ret;
}
