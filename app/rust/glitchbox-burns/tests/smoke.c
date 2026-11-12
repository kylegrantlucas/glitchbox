/* Renders a clip through GlitchboxBurns and writes every frame as raw RGBA8.
 *   smoke IMAGE PROJECT.json OUT.rgba WIDTH HEIGHT FPS DURATION [file DEPTH.png | auto CACHE-DIR [ORT-LIB]]
 * IMAGE is a PNG/JPEG/WebP path, or gradient:WxH for synthetic pixels passed as RGBA.
 * Used by packaging/ios/burns.sh's checks (host and `xcrun simctl spawn`). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <GlitchboxBurns/glitchbox_burns.h>

static void progress(void *context, const char *phase, uint64_t received, uint64_t total,
                     const char *message) {
    (void)context;
    if (strcmp(phase, "downloading") == 0 && received != total && received % (16 << 20) >= 65536)
        return;
    fprintf(stderr, "depth: %s %llu/%llu%s%s\n", phase, (unsigned long long)received,
            (unsigned long long)total, message ? " " : "", message ? message : "");
}

static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *s = malloc((size_t)n + 1);
    if (fread(s, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(s); return NULL; }
    fclose(f);
    s[n] = 0;
    return s;
}

int main(int argc, char **argv) {
    if (argc < 8) {
        fprintf(stderr, "usage: %s IMAGE PROJECT OUT W H FPS DURATION [file D | auto CACHE ORT]\n", argv[0]);
        return 2;
    }
    char *json = slurp(argv[2]);
    if (!json) { fprintf(stderr, "cannot read %s\n", argv[2]); return 1; }
    gb_burns_options o;
    memset(&o, 0, sizeof o);
    o.project_json = json;
    o.width = (uint32_t)atoi(argv[4]);
    o.height = (uint32_t)atoi(argv[5]);
    unsigned gw, gh;
    uint8_t *pixels = NULL;
    if (sscanf(argv[1], "gradient:%ux%u", &gw, &gh) == 2) {
        pixels = malloc((size_t)gw * gh * 4);
        for (unsigned y = 0; y < gh; y++)
            for (unsigned x = 0; x < gw; x++) {
                uint8_t *p = pixels + ((size_t)y * gw + x) * 4;
                p[0] = (uint8_t)(x * 255 / gw);
                p[1] = (uint8_t)(y * 255 / gh);
                p[2] = (uint8_t)(((x / 16) + (y / 16)) % 2 ? 220 : 40);
                p[3] = 255;
            }
        o.image_rgba = pixels;
        o.image_width = gw;
        o.image_height = gh;
    } else {
        o.image_path = argv[1];
    }
    o.fps_num = (uint32_t)atoi(argv[6]);
    o.fps_den = 1;
    o.duration = atof(argv[7]);
    o.progress = progress;
    if (argc >= 10 && strcmp(argv[8], "file") == 0) {
        o.depth_mode = GB_BURNS_DEPTH_FILE;
        o.depth_path = argv[9];
    } else if (argc >= 10 && strcmp(argv[8], "auto") == 0) {
        o.depth_mode = GB_BURNS_DEPTH_AUTO;
        o.cache_dir = argv[9];
        o.ort_library = argc >= 11 ? argv[10] : NULL;
    }
    atomic_int cancel = 0;
    char *err = NULL;
    gb_burns *r = gb_burns_create(&o, &cancel, &err);
    if (!r) { fprintf(stderr, "create: %s\n", err); gb_burns_string_free(err); return 1; }
    uint32_t w = gb_burns_width(r), h = gb_burns_height(r), n = gb_burns_frame_count(r);
    size_t frame = (size_t)w * h * 4;
    uint8_t *buf = malloc(frame);
    FILE *out = fopen(argv[3], "wb");
    if (!out) { fprintf(stderr, "cannot write %s\n", argv[3]); return 1; }
    for (uint32_t i = 0; i < n; i++) {
        if (gb_burns_render_frame(r, i, buf, (size_t)w * 4, &err) != 0) {
            fprintf(stderr, "frame %u: %s\n", i, err);
            gb_burns_string_free(err);
            return 1;
        }
        fwrite(buf, 1, frame, out);
    }
    fclose(out);
    fprintf(stderr, "rendered %u frames of %ux%u\n", n, w, h);
    gb_burns_free(r);
    free(buf);
    free(json);
    free(pixels);
    return 0;
}
