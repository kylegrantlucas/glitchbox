/*
 * Force-included into every C file of the in-process FFmpeg build — the libav*
 * libraries and (through gb_fftools_prefix.h) the fftools — by
 * packaging/ios/ffmpeg.sh. A thread created by any of them inherits its
 * creator's run tag (gb_thread_tag.c), so gb_ffmpeg.c can send log lines from
 * a run's own threads, its decoder/encoder/filter worker threads included, to
 * that run's log, and lines from threads the host started to the host's
 * default log.
 */
#ifndef GB_THREAD_TAG_H
#define GB_THREAD_TAG_H

#include <pthread.h>

/* The calling thread's run tag: 0 for threads the host started, else the run
 * whose thread (directly or through other tagged threads) created it. */
extern _Thread_local unsigned gb_thread_run;

/* pthread_create, plus the new thread inherits the creator's gb_thread_run. */
int gb_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                      void *(*start)(void *), void *arg);

#ifndef GB_THREAD_TAG_IMPL
#undef pthread_create
#define pthread_create gb_pthread_create
#endif

#endif
