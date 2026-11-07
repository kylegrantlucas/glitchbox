/* GlitchboxBurns: the burns-rs (v0.1.0) render core as a C API.
 *
 * A still image plus a burns project (the JSON `burns render --config` reads)
 * becomes a clip of RGBA8 frames, rendered on the GPU (wgpu over Metal) at
 * burns's final quality (2x supersampled, box-resolved): the same pixels
 * `burns render` feeds its encoder. Nothing here spawns a process or encodes;
 * the host encodes the frames. Depth parallax takes a depth PNG, or estimates
 * one with Depth Anything V2 Small through ONNX Runtime, downloading the pinned
 * model (about 99 MB, sha256-verified) into a caller-chosen cache directory on
 * first use, exactly as `burns render --auto-depth` does under
 * ~/Library/Caches/burns.
 *
 * Every function is safe to call from any thread, but one renderer must not be
 * used by two threads at once. Errors are malloc'd UTF-8 strings the caller
 * frees with gb_burns_string_free. Panics never cross the API. */
#ifndef GLITCHBOX_BURNS_H
#define GLITCHBOX_BURNS_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct gb_burns gb_burns;

typedef enum gb_burns_depth_mode {
    /* No depth map. A depth camera fails with a "needs a depth map" error. */
    GB_BURNS_DEPTH_NONE = 0,
    /* `burns render --depth FILE`: an 8- or 16-bit grayscale PNG, white is near. */
    GB_BURNS_DEPTH_FILE = 1,
    /* `burns render --auto-depth`: a map cached for this image under
       cache_dir/depth, else estimated (and cached) with the model in
       cache_dir/models, downloaded there first if missing or corrupt. */
    GB_BURNS_DEPTH_AUTO = 2,
} gb_burns_depth_mode;

/* Called during gb_burns_create while depth is estimated. phase is one of
   "cache-hit", "verifying", "downloading", "loading", "inferring", "saving",
   "warning" (message set: the map was made but could not be cached).
   received/total are model bytes while downloading, else 0. */
typedef void (*gb_burns_progress_fn)(void *context, const char *phase,
                                     uint64_t received, uint64_t total,
                                     const char *message);

typedef struct gb_burns_options {
    /* The source still: a PNG/JPEG/WebP file (image_path non-NULL), or
       tightly packed straight-alpha RGBA8 pixels of image_width x image_height. */
    const char *image_path;
    const uint8_t *image_rgba;
    uint32_t image_width;
    uint32_t image_height;
    /* A complete burns project document (strict: no unknown or missing fields). */
    const char *project_json;
    /* Overrides, as burns render's flags, applied in burns's order:
       fps_num/fps_den   --fps NUM/DEN (0 keeps the project's rate; den 0 means 1);
       duration          --duration SECONDS (> 0), converted at the final rate;
       frames            an exact frame count instead (> 0; wins over duration);
       width, height     --width/--height (0 keeps the project's). */
    uint32_t fps_num;
    uint32_t fps_den;
    double duration;
    uint32_t frames;
    uint32_t width;
    uint32_t height;
    gb_burns_depth_mode depth_mode;
    /* GB_BURNS_DEPTH_FILE: the depth PNG. */
    const char *depth_path;
    /* GB_BURNS_DEPTH_AUTO: burns's cache root (models/ and depth/ inside). */
    const char *cache_dir;
    /* GB_BURNS_DEPTH_AUTO: the ONNX Runtime (>= 1.27) library to dlopen. NULL
       means onnxruntime.framework beside GlitchboxBurns.framework. */
    const char *ort_library;
    gb_burns_progress_fn progress; /* optional */
    void *progress_context;
} gb_burns_options;

/* Loads the image, resolves depth, validates the project, and sets up the GPU
   renderer. If *cancel (optional) becomes nonzero, depth estimation or the
   model download stops and this returns NULL with the error "cancelled".
   On failure returns NULL and, if error is non-NULL, sets *error. */
gb_burns *gb_burns_create(const gb_burns_options *options, const atomic_int *cancel,
                          char **error);

/* The final output size and length. */
uint32_t gb_burns_width(const gb_burns *renderer);
uint32_t gb_burns_height(const gb_burns *renderer);
uint32_t gb_burns_frame_count(const gb_burns *renderer);
void gb_burns_fps(const gb_burns *renderer, uint32_t *num, uint32_t *den);
/* The resolved project (after overrides) as pretty JSON; free with gb_burns_string_free. */
char *gb_burns_project_json(const gb_burns *renderer);

/* Renders frame `index` (0-based, < frame count) into dst as RGBA8 (sRGB,
   opaque), rows `stride` bytes apart (stride >= width * 4; dst holds
   stride * (height - 1) + width * 4 bytes). Returns 0, or -1 with *error. */
int gb_burns_render_frame(gb_burns *renderer, uint32_t index, uint8_t *dst, size_t stride,
                          char **error);

void gb_burns_free(gb_burns *renderer);
void gb_burns_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
