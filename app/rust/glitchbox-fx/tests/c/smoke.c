/* C smoke test for GlitchboxFX: every handle type through the C ABI.
 * Build against an xcframework slice, e.g. the simulator:
 *   S=build/ios/xcframeworks/GlitchboxFX.xcframework/ios-arm64-simulator
 *   xcrun -sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator \
 *     -fmodules -I"$S/Headers" app/rust/glitchbox-fx/tests/c/smoke.c \
 *     "$S/libglitchbox_fx.a" -liconv -o /tmp/gbfx-smoke
 *   xcrun simctl spawn booted /tmp/gbfx-smoke
 * Exits 0 and prints "glitchbox-fx smoke: ok" on success. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "glitchbox_fx.h"

#define W 64
#define H 48

static int fail(const char *what, char *error) {
    fprintf(stderr, "glitchbox-fx smoke: %s failed: %s\n", what, error ? error : "(no message)");
    gbfx_string_free(error);
    return 1;
}

static int differs(const void *a, const void *b, size_t n) { return memcmp(a, b, n) != 0; }

int main(void) {
    char *error = NULL;
    printf("glitchbox-fx %s\n", gbfx_version());

    if (gbfx_ntsc_set_threads(2, &error) != GBFX_OK) return fail("gbfx_ntsc_set_threads", error);

    /* ntsc: 16-bit xRGB gradient through a version-1 preset with a seed. */
    GbfxNtsc *ntsc = gbfx_ntsc_new("{\"version\": 1, \"random_seed\": 42}", &error);
    if (!ntsc) return fail("gbfx_ntsc_new", error);
    char *resolved = gbfx_ntsc_settings_json(ntsc, &error);
    if (!resolved || !strstr(resolved, "random_seed")) return fail("gbfx_ntsc_settings_json", error);
    gbfx_string_free(resolved);
    uint16_t *src16 = malloc(W * H * 8), *dst16 = calloc(W * H, 8);
    for (int i = 0; i < W * H; i++) {
        src16[i * 4] = 0xffff;
        src16[i * 4 + 1] = (uint16_t)((i % W) * 1000);
        src16[i * 4 + 2] = (uint16_t)((i / W) * 1300);
        src16[i * 4 + 3] = 30000;
    }
    for (uint64_t frame = 0; frame < 3; frame++) {
        int64_t index = gbfx_pts_frame_index(frame * 1000000000ull / 30, 30, 1);
        if (index != (int64_t)frame) return fail("gbfx_pts_frame_index", NULL);
        if (gbfx_ntsc_apply(ntsc, src16, W * 8, dst16, W * 8, W, H, (uint64_t)index, &error) != GBFX_OK)
            return fail("gbfx_ntsc_apply", error);
    }
    if (!differs(src16, dst16, W * H * 8)) return fail("ntsc output (unchanged frame)", NULL);
    gbfx_ntsc_free(ntsc);

    /* bender: default effect plus an override and a seed; RGBA8. */
    const char *sets[] = {"order=sync,tape"};
    int32_t seed = 7;
    GbfxBender *bender = gbfx_bender_new(NULL, sets, 1, &seed, 2, &error);
    if (!bender) return fail("gbfx_bender_new", error);
    char *preset = gbfx_bender_preset_json(bender, &error);
    if (!preset || !strstr(preset, "\"seed\"")) return fail("gbfx_bender_preset_json", error);
    gbfx_string_free(preset);
    uint32_t bw = 0, bh = 0;
    if (gbfx_bender_scaled_size(1920, 1080, 480, &bw, &bh) != GBFX_OK || bw != 854 || bh != 480)
        return fail("gbfx_bender_scaled_size", NULL);
    uint8_t *src8 = malloc(W * H * 4), *dst8 = calloc(W * H, 4);
    for (int i = 0; i < W * H * 4; i++) src8[i] = (uint8_t)(i * 7);
    for (uint64_t frame = 0; frame < 3; frame++)
        if (gbfx_bender_apply(bender, src8, W * 4, dst8, W * 4, W, H, frame, &error) != GBFX_OK)
            return fail("gbfx_bender_apply", error);
    if (gbfx_bender_reset(bender, &error) != GBFX_OK) return fail("gbfx_bender_reset", error);
    gbfx_bender_free(bender);

    /* Bad input reports an error string instead of crashing. */
    if (gbfx_bender_new("{not json", NULL, 0, NULL, 1, &error) != NULL || !error)
        return fail("gbfx_bender_new rejecting bad JSON", NULL);
    gbfx_string_free(error);
    error = NULL;

    /* reactive-vcr: a one-target mapping driven by a tone with a burst. */
    const char *mapping =
        "[audio]\nbands.bass = [20, 200]\n"
        "[[modulate]]\ntarget = \"snow_intensity\"\nsource = \"band:bass\"\nrange = [0.0, 1.0]\n";
    size_t n = 48000;
    float *audio = malloc(n * sizeof(float));
    for (size_t i = 0; i < n; i++)
        audio[i] = (float)(sin(2 * M_PI * 80.0 * (double)i / 48000.0) * (i > n / 2 ? 0.9 : 0.05));
    GbfxReactive *rv = gbfx_reactive_new(mapping, ".", audio, n, W, H, 30, 1, 1.0, 2, &error);
    if (!rv) return fail("gbfx_reactive_new", error);
    uint64_t frames = gbfx_reactive_frame_count(rv);
    uint32_t rw = 0, rh = 0;
    if (frames != 30 || gbfx_reactive_frame_size(rv, &rw, &rh) != GBFX_OK || rw != W || rh != H)
        return fail("gbfx_reactive_frame_count/size", NULL);
    uint8_t *rsrc = malloc(W * H * 3), *rdst = calloc(W * H, 3);
    for (int i = 0; i < W * H * 3; i++) rsrc[i] = (uint8_t)(i * 3);
    for (uint64_t frame = 0; frame < frames; frame++) {
        int64_t index = gbfx_reactive_frame_index(frame * 1000000000ull / 30, 30, 1);
        if (gbfx_reactive_apply(rv, rsrc, W * 3, rdst, W * 3, W, H, (uint64_t)index, &error) != GBFX_OK)
            return fail("gbfx_reactive_apply", error);
    }
    if (gbfx_reactive_apply(rv, rsrc, W * 3, rdst, W * 3, W, H, frames, &error) != GBFX_DROPPED)
        return fail("gbfx_reactive_apply past the end", error);
    gbfx_reactive_free(rv);

    free(src16); free(dst16); free(src8); free(dst8); free(audio); free(rsrc); free(rdst);
    printf("glitchbox-fx smoke: ok\n");
    return 0;
}
