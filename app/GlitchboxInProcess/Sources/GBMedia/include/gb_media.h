#ifndef GB_MEDIA_H
#define GB_MEDIA_H

/* Thread-safe libav helpers for native steps (decode → effect → encode). Every object is
   independent: no fftools globals, no process state, any number may run concurrently.
   Errors are returned as negative AVERROR codes plus, where an `err` out-parameter exists,
   a malloc'd message the caller frees with gbm_string_free (NULL on success). */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct gbm_rational { int num, den; } gbm_rational;

/* Stream properties of an opened video, as the demuxer/decoder report them. */
typedef struct gbm_video_info {
    int width, height;           /* coded size of the source */
    int pix_fmt;                 /* source AVPixelFormat */
    gbm_rational frame_rate;     /* avg (else r_frame_rate); 0/1 when unknown */
    gbm_rational time_base;      /* stream time base */
    gbm_rational sar;            /* 0/1 when unknown */
    int color_space, color_range, color_primaries, color_trc; /* AVColor* enums */
    int64_t frame_count;         /* container's nb_frames; 0 when unknown */
    double duration;             /* seconds; < 0 when unknown */
    char codec_name[32];         /* codec descriptor name of the stream ("ffvhuff", "ffv1", "h264", …) */
    int chroma_location;         /* AVChromaLocation of the stream, 0 = unspecified */
} gbm_video_info;

/* One decoded, converted frame. Planes are borrowed until the next gbm_decoder_next or
   gbm_decoder_free. */
typedef struct gbm_frame {
    uint8_t *data[4];
    int linesize[4];
    int width, height, pix_fmt;
    int64_t index;               /* 0-based decode order of output frames */
    int64_t pts;                 /* in the decoder's output time base (gbm_decoder_output): the stream
                                    time base unless `filters` change it (e.g. fps=) */
    double time;                 /* pts in seconds */
} gbm_frame;

typedef struct gbm_decoder gbm_decoder;

/* Opens the first video stream of `path` and converts every frame to `pix_fmt` at
   `width`×`height` (0 keeps the source size) with swscale `scale_flags` (a libswscale
   flags string such as "lanczos+accurate_rnd"; NULL = "bicubic+accurate_rnd+full_chroma_int").
   `filters` is an optional libavfilter chain run before the scale/format (e.g. "fps=30"),
   NULL or "" for none. Input colour matrix/range come from the frames; output keeps the
   source's tags. `threads`: decoder threads, 0 = auto. */
int gbm_decoder_open(gbm_decoder **out, const char *path, int width, int height, int pix_fmt,
                     const char *scale_flags, const char *filters, int threads, char **err);
const gbm_video_info *gbm_decoder_info(const gbm_decoder *d);
/* The converted output: size, format, and the output time base of the filter graph. */
void gbm_decoder_output(const gbm_decoder *d, int *width, int *height, int *pix_fmt, gbm_rational *time_base,
                        gbm_rational *frame_rate);
/* 1 = *frame filled, 0 = end of stream, < 0 = error. */
int gbm_decoder_next(gbm_decoder *d, gbm_frame *frame);
void gbm_decoder_free(gbm_decoder **d);

/* Decodes the first audio stream of `path` to mono float samples at `sample_rate`
   (channels averaged by swresample's default downmix matrix). *samples is malloc'd
   (free with gbm_samples_free); *count is its length. Starts at the stream's first sample. */
int gbm_decode_audio_mono(const char *path, int sample_rate, float **samples, int64_t *count, char **err);
void gbm_samples_free(float *samples);

enum gbm_codec {
    GBM_CODEC_FFV1 = 0,
    GBM_CODEC_FFVHUFF = 1,
};

typedef struct gbm_encoder_config {
    int codec;                   /* enum gbm_codec */
    int width, height, pix_fmt;
    gbm_rational frame_rate;     /* also the encoder time base (inverted), like the ffmpeg CLI */
    gbm_rational sar;            /* 0/1 = unset */
    int color_space, color_range, color_primaries, color_trc; /* AVColor* enums, 0/2 = unspecified */
    int chroma_location;         /* AVChromaLocation, 0 = unspecified */
    int threads;                 /* encoder threads, 0 = auto */
    const char *codec_options;   /* "key=value:key=value" AVOptions for the encoder, or NULL */
} gbm_encoder_config;

typedef struct gbm_encoder gbm_encoder;

/* Opens a Matroska writer at `path` (replaced) with +bitexact format and codec flags, so
   identical frames give identical bytes. */
int gbm_encoder_open(gbm_encoder **out, const char *path, const gbm_encoder_config *config, char **err);
/* Encodes one frame in the configured format/size; `index` is its frame number (pts in
   1/frame_rate units). Planes are copied; the caller keeps ownership. */
int gbm_encoder_write(gbm_encoder *e, const uint8_t *const data[4], const int linesize[4], int64_t index);
/* Flushes the encoder and writes the trailer. */
int gbm_encoder_finish(gbm_encoder *e);
/* Frees (and, if not finished, abandons) the writer. */
void gbm_encoder_free(gbm_encoder **e);

/* One-in/one-out libavfilter graph over raw frames: buffer (src_w×src_h src_pix_fmt, colour
   tags src_color_space/src_color_range as AVCOL_*, time base 1/1, SAR 1:1) → `filters`
   (e.g. "scale=out_range=tv:out_color_matrix=bt601:flags=area+accurate_rnd,format=yuv420p";
   NULL or "" = "null") → buffersink. The filters must emit exactly one frame per input. */
typedef struct gbm_converter gbm_converter;
int gbm_converter_open(gbm_converter **out, int src_w, int src_h, int src_pix_fmt, int src_color_space,
                       int src_color_range, const char *filters, char **err);
/* Output size/format after configuration. */
void gbm_converter_output(const gbm_converter *c, int *width, int *height, int *pix_fmt);
/* Converts one frame (planes copied in); *frame's planes are borrowed until the next run or
   free; frame->index counts runs. Returns 0 or < 0 (AVERROR). */
int gbm_converter_run(gbm_converter *c, const uint8_t *const data[4], const int linesize[4], gbm_frame *frame);
void gbm_converter_free(gbm_converter **c);

/* The message for a negative return code. */
char *gbm_error_string(int code);
void gbm_string_free(char *s);

/* AVPixelFormat for a name ("rgba", "rgb48le", "yuv420p", …), or -1. */
int gbm_pix_fmt(const char *name);

#ifdef __cplusplus
}
#endif

#endif
