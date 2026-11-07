/* Force-included after ffg_hooks.h into the fftools objects (ffgac = FFglitch's
 * fftools/ffmpeg, ffedit). Their threads are tracked so a failed or cancelled
 * run can wait for and join every one of them, and their stdout/stderr (help,
 * banners, -stats, ffedit's feature list) go to the run's log: stdio.h's
 * `extern FILE *__stderrp;` becomes `extern FILE *(*ffg_tool_stderr_ptr());`,
 * so `stderr` is the run's log FILE. */
#ifndef FFG_TOOL_HOOKS_H
#define FFG_TOOL_HOOKS_H

#include "ffg_hooks.h"

#undef pthread_create
#define pthread_create ffg_tool_pthread_create
#define pthread_join ffg_tool_pthread_join

#define __stderrp (*ffg_tool_stderr_ptr())
#define __stdoutp (*ffg_tool_stdout_ptr())
#define printf ffg_tool_printf
#define vprintf ffg_tool_vprintf
#define puts ffg_tool_puts
#define putchar ffg_tool_putchar

/* The tools' mains (renamed with -Dmain=<tool>_tool_main) and ffgac's cancel
   entry (inprocess.patch), called from ffglitch_runtime.c. Everything else is
   -fvisibility=hidden; these stay global through the per-tool `ld -r` (which
   makes all hidden symbols local) and are hidden again by the dylib's
   exported-symbols list. */
#define FFG_TOOL_ENTRY __attribute__((visibility("default")))
FFG_TOOL_ENTRY int ffgac_tool_main(int argc, char **argv);
FFG_TOOL_ENTRY void ffgac_tool_cancel(void);
FFG_TOOL_ENTRY int ffedit_tool_main(int argc, char **argv);

#endif
