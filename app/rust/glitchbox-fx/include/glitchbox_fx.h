/*
 * glitchbox_fx.h — C API of GlitchboxFX (app/rust/glitchbox-fx): the
 * media-free effect cores behind three Glitchbox plugins, for hosts that
 * cannot spawn the macOS CLIs (iOS). The host decodes, scales, converts,
 * and encodes with libav; this library only transforms frames.
 *
 *   ntsc    ntsc-rs core @add90f5 (what ntsc-rs-cli 0.9.4 runs)  analog-pass
 *   bender  bender-rs core @1ddcf66 (bender 0.2.1)                bender
 *   reactive reactive-vcr core v0.4.1 (with its own ntsc-rs @88f2df9
 *            and bender @e5b754c)                                 reactive-vcr
 *
 * Each section says what the host must do around the call to reproduce the
 * CLI the macOS pipeline runs (pipelines/analog-pass, pipelines/bend,
 * pipelines/reactive-vcr). Measured against the real CLIs by
 * tests/oracle.rs; remaining differences come from libav's scaling and
 * RGB<->YUV conversion standing in for GStreamer's videoscale/videoconvert.
 *
 * Conventions
 * - Errors: functions taking `char **error` set *error to NULL on success and
 *   to a message on failure (when error is non-NULL). Free every string this
 *   library returns with gbfx_string_free, never free().
 * - Panics inside the cores are caught and reported as errors; nothing here
 *   aborts or unwinds into the caller.
 * - Strides are in bytes; each frame buffer is at least stride * height bytes;
 *   src and dst must not overlap.
 * - Handles are thread-safe: an ntsc handle may run several frames
 *   concurrently; bender and reactive handles serialize frames internally
 *   (they carry per-stream state, so feed one stream's frames in order).
 *   Freeing a handle while another thread uses it is undefined.
 * - Threads: bender and reactive handles each own a rayon pool (`threads`,
 *   0 = rayon's default: RAYON_NUM_THREADS or the logical core count). The
 *   ntsc-rs stages (ntsc handles and reactive's ntsc stage) run on ntsc-rs's
 *   own process-wide pool, sized once: see gbfx_ntsc_set_threads.
 */
#ifndef GLITCHBOX_FX_H
#define GLITCHBOX_FX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GBFX_OK 0
#define GBFX_ERROR (-1)
#define GBFX_DROPPED 1

typedef struct Ntsc GbfxNtsc;
typedef struct Bender GbfxBender;
typedef struct Reactive GbfxReactive;

/* Frees a string returned by this library. NULL is ignored. */
void gbfx_string_free(char *s);

/* Library version, a static string (do not free). */
const char *gbfx_version(void);

/* Frame index the ntsc-rs-cli and bender GStreamer filters derive from a
 * buffer timestamp: floor(fps_n * (pts_ns + 100) / fps_d / 1e9), in integer
 * arithmetic. Returns -1 for a non-positive rate. */
int64_t gbfx_pts_frame_index(uint64_t pts_ns, int32_t fps_n, int32_t fps_d);

/* ---------------------------------------------------------------------------
 * ntsc-rs (analog-pass)
 *
 * The CLI call being reproduced (pipelines/analog-pass):
 *   ntsc-rs-cli -i IN -o OUT -c ffv1 --chroma-subsampling -y -j SETTINGS [--scale N]
 * where SETTINGS is the preset JSON with `.random_seed = SEED` set (jq).
 *
 * Host pipeline per frame, as ntsc-rs-cli's GStreamer graph does it:
 *  1. Decode; convert to 16-bit RGB. 8-bit sources widen by replication
 *     (v * 257), as videoconvert does.
 *  2. Timing: ntsc-rs-cli runs videorate, so frames are retimed to the
 *     stream's nominal rate: frame k gets pts k * fps_d / fps_n and index
 *     gbfx_pts_frame_index(pts, fps_n, fps_d) == k (sequential from 0).
 *     Trailing frame: with Matroska input (every Glitchbox layer) the CLI
 *     outputs N + 1 frames for N input frames. The extra one is the last
 *     input frame run through the effect again with frame index N. Emit it.
 *  3. Scale (only with --scale N; analog-pass `scale` > 0): bilinear
 *     (GStreamer videoscale method=bilinear) to gbfx_ntsc_scaled_size()'s
 *     output size. Do this before the effect.
 *  4. gbfx_ntsc_apply.
 *  5. Encode like the CLI's FFV1 path: narrow to 8-bit RGB by truncation
 *     (v >> 8, as videoconvert does), then convert to yuv420p, limited
 *     range, with GStreamer's default colorimetry for the output height:
 *     BT.601 matrix (tagged smpte170m, chroma location center) up to 576
 *     lines, BT.709 above (tagged bt709, chroma location left);
 *     transfer/primaries untagged. At SD the CLI's chroma is a 2x2 box
 *     average: swscale `out_chroma_loc=center:flags=area+accurate_rnd+
 *     full_chroma_int` reproduces it within +-1 (tests/oracle.rs). Then
 *     FFV1 in Matroska, progressive, input frame rate. (Without
 *     --chroma-subsampling the CLI writes yuv444p; analog-pass always
 *     passes it.)
 * ------------------------------------------------------------------------- */

/* Parses settings exactly like `ntsc-rs-cli -j JSON`: `version: 1` presets
 * start from ntsc-rs's legacy values (not its defaults) for missing keys;
 * ntscQT presets are converted. Enum values are the Rust discriminants
 * (numbers). Set the seed in the JSON (random_seed) before calling, as the
 * pipeline does; there is no separate seed argument. NULL on error. */
GbfxNtsc *gbfx_ntsc_new(const char *settings_json, char **error);
void gbfx_ntsc_free(GbfxNtsc *ntsc);

/* The fully resolved settings (all keys) as ntsc-rs JSON. NULL on error. */
char *gbfx_ntsc_settings_json(const GbfxNtsc *ntsc, char **error);

/* ntsc-rs-cli --scale: height = scanlines, width = round(width * scanlines /
 * height) (f32 math; not forced even). GBFX_ERROR if any input is 0. */
int gbfx_ntsc_scaled_size(uint32_t width, uint32_t height, uint32_t scanlines,
                          uint32_t *out_width, uint32_t *out_height);

/* Applies the effect to one progressive frame. Pixel format both ways is
 * GStreamer ARGB64: four native-endian uint16 per pixel in the order X, R,
 * G, B (X ignored on input, unspecified on output); pointers 2-byte aligned,
 * strides even. Mirrors ntsc-rs-cli's progressive path: the field comes from
 * use_field and frame_index, effect scale [1, 1], written back with Bob
 * deinterlacing (each output row filled from the processed field). Returns
 * GBFX_OK or GBFX_ERROR. */
int gbfx_ntsc_apply(const GbfxNtsc *ntsc,
                    const uint16_t *src, size_t src_stride,
                    uint16_t *dst, size_t dst_stride,
                    uint32_t width, uint32_t height,
                    uint64_t frame_index, char **error);

/* Sizes ntsc-rs's process-wide worker pool (shared by every ntsc handle and
 * reactive's ntsc stage). 0 = ntsc-rs's default (physical core count).
 * Implemented through RAYON_NUM_THREADS, which ntsc-rs reads when it starts
 * the pool on the first frame. So call it once at startup, before any
 * ntsc/reactive frame and before other threads read the environment. Returns
 * GBFX_ERROR once the pool is running. A value set here also becomes rayon's
 * default for handles created with threads = 0. */
int gbfx_ntsc_set_threads(uint32_t threads, char **error);

/* ---------------------------------------------------------------------------
 * bender (bender plugin)
 *
 * The CLI calls being reproduced (pipelines/bend):
 *   bender [--preset P] [--set ID=VALUE]... [--seed N] --dump-preset > preset.json
 *   bender -i IN -o OUT --codec ffv1 --scanlines S --preset preset.json --overwrite
 *
 * Host pipeline per frame, as bender-gst does it:
 *  1. Decode; convert to RGBA8.
 *  2. Scale to gbfx_bender_scaled_size(w, h, S) with bilinear (videoscale's
 *     default method). S = 0 keeps the size but still rounds odd sizes to
 *     even.
 *  3. Frame index: there is no videorate, so the index comes from each
 *     decoded frame's own timestamp: gbfx_pts_frame_index(pts_ns, fps_n,
 *     fps_d) with the stream's nominal rate. Matroska timestamps are whole
 *     milliseconds, so at 30 fps the indices run 0,0,2,3,3,5,... Use the
 *     demuxed timestamp (pts * time_base, in ns) to match. Frames without a
 *     timestamp use a running counter of frames seen.
 *  4. gbfx_bender_apply, frames in decode order on one handle.
 *  5. Encode: the CLI's videoconvert feeds the FFV1 encoder yuv420p with the
 *     same colorimetry rule and chroma filter as ntsc step 5 (BT.601/center
 *     up to 576 lines, BT.709/left above, limited range). FFV1 in Matroska;
 *     same frame count and timestamps as the input (no extra frame).
 * ------------------------------------------------------------------------- */

/* Resolves the effect like the CLI flags: preset_json (NULL =
 * BendEffect::default(), no --preset), then each "ID=VALUE" in sets (order
 * matters, e.g. "order=sync,tape"), then *seed if seed is non-NULL. The
 * result is round-tripped through its --dump-preset JSON, as the pipeline
 * renders from that dump. threads sizes this handle's rayon pool (0 =
 * default). NULL on error (bad JSON, unknown setting id, bad value). */
GbfxBender *gbfx_bender_new(const char *preset_json,
                            const char *const *sets, size_t set_count,
                            const int32_t *seed, uint32_t threads,
                            char **error);
void gbfx_bender_free(GbfxBender *bender);

/* `bender --dump-preset` output without the trailing newline the CLI's
 * println adds. NULL on error. */
char *gbfx_bender_preset_json(const GbfxBender *bender, char **error);

/* Clears the per-stream memory (feedback, tape, frame stores), as the
 * GStreamer filter does when a stream stops. A new handle starts cleared. */
int gbfx_bender_reset(const GbfxBender *bender, char **error);

/* bender --scanlines: height = scanlines and width = width * scanlines /
 * height (scanlines 0 = source size), each rounded to the nearest even
 * number, at least 2. GBFX_ERROR for a zero source dimension. */
int gbfx_bender_scaled_size(uint32_t width, uint32_t height, uint32_t scanlines,
                            uint32_t *out_width, uint32_t *out_height);

/* Applies the effect to one RGBA8 frame (bytes R, G, B, A). Alpha is
 * ignored; the encoder drops it. The handle's stream state advances.
 * Returns GBFX_OK or GBFX_ERROR. */
int gbfx_bender_apply(const GbfxBender *bender,
                      const uint8_t *src, size_t src_stride,
                      uint8_t *dst, size_t dst_stride,
                      uint32_t width, uint32_t height,
                      uint64_t frame_index, char **error);

/* ---------------------------------------------------------------------------
 * reactive-vcr (reactive-vcr plugin)
 *
 * The CLI call being reproduced (plugins/reactive-vcr.json ->
 * pipelines/reactive-vcr):
 *   reactive-vcr render --video IN --audio AUDIO --map MAP --audio-mode none --output OUT.mkv
 * (AUDIO is the layer's source audio.wav unless the user picked a file.)
 *
 * Host pipeline:
 *  1. Audio: decode AUDIO's first audio stream to mono float32 at 48 kHz
 *     (GStreamer audioconvert ! audioresample: channels averaged, then
 *     resampled). Pass the whole file.
 *  2. Probe the video: width, height, frame rate (0/x -> 30/1), container
 *     duration in seconds (GStreamer Discoverer: the longest stream).
 *  3. gbfx_reactive_new; frames to render = gbfx_reactive_frame_count
 *     (round(duration * fps)); size = gbfx_reactive_frame_size (each
 *     dimension floored to even, at least 2).
 *  4. Video: decode, convert to RGB24, scale to that size (bilinear, as
 *     videoscale; a no-op for even sources), and retime to the constant
 *     rate (videorate: frame k at k * fps_d / fps_n, duplicating or dropping
 *     source frames by nearest timestamp). Index = gbfx_reactive_frame_index
 *     of that time, i.e. k. Stop at frame_count (gbfx_reactive_apply
 *     returns GBFX_DROPPED from there on; the CLI drops those frames).
 *  5. Encode: yuv444p, limited range, colour tags by output height: BT.601
 *     (smpte170m primaries/transfer/matrix) when height <= 576, BT.709
 *     (all three bt709) above; the CLI sets colorimetry explicitly on its
 *     Y444 caps. FFV1 in Matroska at the source rate, no audio
 *     (--audio-mode none), SAR 1:1 after the probe's size.
 * ------------------------------------------------------------------------- */

/* Compiles a mapping and precomputes the per-frame modulation schedule like
 * `reactive-vcr render`.
 *   mapping_toml   the mapping file's text.
 *   base_dir       the mapping file's directory; relative [base].preset
 *                  paths resolve against it (the preset is read here).
 *   samples        mono float32 48 kHz audio, sample_count samples.
 *   video_*        probed video facts (step 2 above); duration_s > 0.
 *   threads        this handle's rayon pool for the bender stage (0 = default).
 * NULL on error (bad mapping, unknown target, audio with no content, ...). */
GbfxReactive *gbfx_reactive_new(const char *mapping_toml, const char *base_dir,
                                const float *samples, size_t sample_count,
                                uint32_t video_width, uint32_t video_height,
                                int32_t fps_n, int32_t fps_d, double duration_s,
                                uint32_t threads, char **error);
void gbfx_reactive_free(GbfxReactive *reactive);

/* Number of frames the CLI renders (round(duration_s * fps)). 0 for NULL. */
uint64_t gbfx_reactive_frame_count(const GbfxReactive *reactive);

/* Processing size the CLI scales the video to. */
int gbfx_reactive_frame_size(const GbfxReactive *reactive,
                             uint32_t *out_width, uint32_t *out_height);

/* The CLI filter's frame index for a stream time: round(t * fps), at least 0.
 * -1 for a non-positive rate. */
int64_t gbfx_reactive_frame_index(uint64_t stream_time_ns, int32_t fps_n, int32_t fps_d);

/* Applies the frame's modulated ntsc-rs + bender effect to one packed RGB24
 * frame. Returns GBFX_OK, GBFX_DROPPED (frame_index >= frame count; dst
 * untouched, emit nothing), or GBFX_ERROR. Scratch buffers are reused
 * while the frame size stays the same. */
int gbfx_reactive_apply(const GbfxReactive *reactive,
                        const uint8_t *src, size_t src_stride,
                        uint8_t *dst, size_t dst_stride,
                        uint32_t width, uint32_t height,
                        uint64_t frame_index, char **error);

#ifdef __cplusplus
}
#endif

#endif /* GLITCHBOX_FX_H */
