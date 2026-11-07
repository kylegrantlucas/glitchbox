/*
 * Force-included (-include) into every fftools object of the in-process
 * ffmpeg/ffprobe build (packaging/ios/ffmpeg.sh). The tools' stdout/stderr
 * become the per-run log stream that gb_ffmpeg.c opens, so nothing a run
 * prints reaches the host process's own descriptors.
 */
#ifndef GB_FFTOOLS_PREFIX_H
#define GB_FFTOOLS_PREFIX_H

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "gb_thread_tag.h"

/* Owned by gb_ffmpeg.c (outside the reset sections). */
extern FILE *gb_fftools_stdout;
extern FILE *gb_fftools_stderr;
/* Nonzero once the current run's cancel atom is set. */
int gb_fftools_cancel_requested(void);
/* Stands in for av_log_default_callback inside the tools (ffprobe -show_log
 * and -report chain to it): writes to the run's log. */
void gb_fftools_log_default(void *avcl, int level, const char *fmt, va_list vl);
/* The renamed mains (patched ffmpeg.c / ffprobe.c), called by gb_ffmpeg.c. */
int gb_fftool_ffmpeg_main(int argc, char **argv);
int gb_fftool_ffprobe_main(int argc, char **argv);

#undef stdout
#undef stderr
#define stdout gb_fftools_stdout
#define stderr gb_fftools_stderr
#define printf(...) fprintf(gb_fftools_stdout, __VA_ARGS__)
#define vprintf(fmt, vl) vfprintf(gb_fftools_stdout, fmt, vl)
#define putchar(c) fputc((c), gb_fftools_stdout)
#define puts(s) (fputs((s), gb_fftools_stdout), fputc('\n', gb_fftools_stdout))
#define perror(s) fprintf(gb_fftools_stderr, "%s: %s\n", (s), strerror(errno))
#define av_log_default_callback gb_fftools_log_default

#endif
