#include "gb_media.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>

static const char *default_scale_flags = "bicubic+accurate_rnd+full_chroma_int";

static char *dup_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static char *dup_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char *s = NULL;
    if (vasprintf(&s, fmt, ap) < 0) s = NULL;
    va_end(ap);
    return s;
}

static int fail(char **err, int code, const char *what) {
    if (err) {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(code, buf, sizeof buf);
        *err = dup_printf("%s: %s", what, buf);
    }
    return code;
}

char *gbm_error_string(int code) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buf, sizeof buf);
    return strdup(buf);
}

void gbm_string_free(char *s) { free(s); }

int gbm_pix_fmt(const char *name) {
    enum AVPixelFormat f = av_get_pix_fmt(name);
    return f == AV_PIX_FMT_NONE ? -1 : (int)f;
}

static gbm_rational from_av(AVRational r) { return (gbm_rational){r.num, r.den}; }
static AVRational to_av(gbm_rational r) { return (AVRational){r.num, r.den}; }

/* ---------------------------------------------------------------- Decoding */

struct gbm_decoder {
    AVFormatContext *fmt;
    AVCodecContext *dec;
    int stream;
    AVFilterGraph *graph;
    AVFilterContext *src, *sink;
    AVPacket *pkt;
    AVFrame *decoded, *out;
    gbm_video_info info;
    AVRational out_tb, out_rate;
    int out_w, out_h, out_fmt;
    int64_t index;
    int demux_eof, decoder_eof, graph_eof;
};

static int open_input(const char *path, enum AVMediaType type, int threads, AVFormatContext **fmt,
                      AVCodecContext **dec, int *stream, char **err) {
    int ret = avformat_open_input(fmt, path, NULL, NULL);
    if (ret < 0) return fail(err, ret, "open input");
    if ((ret = avformat_find_stream_info(*fmt, NULL)) < 0) return fail(err, ret, "read stream info");
    const AVCodec *codec = NULL;
    ret = av_find_best_stream(*fmt, type, -1, -1, &codec, 0);
    if (ret < 0) return fail(err, ret, type == AVMEDIA_TYPE_VIDEO ? "find video stream" : "find audio stream");
    *stream = ret;
    AVStream *st = (*fmt)->streams[ret];
    *dec = avcodec_alloc_context3(codec);
    if (!*dec) return fail(err, AVERROR(ENOMEM), "allocate decoder");
    if ((ret = avcodec_parameters_to_context(*dec, st->codecpar)) < 0) return fail(err, ret, "decoder parameters");
    (*dec)->pkt_timebase = st->time_base;
    (*dec)->thread_count = threads;
    if ((ret = avcodec_open2(*dec, codec, NULL)) < 0) return fail(err, ret, "open decoder");
    return 0;
}

static int build_graph(gbm_decoder *d, int width, int height, int pix_fmt, const char *scale_flags,
                       const char *filters, char **err) {
    AVStream *st = d->fmt->streams[d->stream];
    AVRational sar = d->dec->sample_aspect_ratio.num ? d->dec->sample_aspect_ratio : st->sample_aspect_ratio;
    if (!sar.num) sar = (AVRational){0, 1};
    d->graph = avfilter_graph_alloc();
    if (!d->graph) return fail(err, AVERROR(ENOMEM), "allocate filter graph");
    d->graph->nb_threads = 1; /* filters run in the caller's thread; results never depend on it */

    char args[512];
    snprintf(args, sizeof args, "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
             d->dec->width, d->dec->height, d->dec->pix_fmt, st->time_base.num, st->time_base.den,
             sar.num, sar.den);
    if (d->info.frame_rate.num) {
        size_t n = strlen(args);
        snprintf(args + n, sizeof args - n, ":frame_rate=%d/%d", d->info.frame_rate.num, d->info.frame_rate.den);
    }
    int ret = avfilter_graph_create_filter(&d->src, avfilter_get_by_name("buffer"), "in", args, NULL, d->graph);
    if (ret < 0) return fail(err, ret, "create buffer source");
    d->sink = avfilter_graph_alloc_filter(d->graph, avfilter_get_by_name("buffersink"), "out");
    if (!d->sink) return fail(err, AVERROR(ENOMEM), "create buffer sink");
    if ((ret = avfilter_init_dict(d->sink, NULL)) < 0) return fail(err, ret, "init buffer sink");

    const char *fmt_name = av_get_pix_fmt_name((enum AVPixelFormat)pix_fmt);
    if (!fmt_name) return fail(err, AVERROR(EINVAL), "unknown output pixel format");
    char w[16] = "iw", h[16] = "ih";
    if (width > 0) snprintf(w, sizeof w, "%d", width);
    if (height > 0) snprintf(h, sizeof h, "%d", height);
    int pre = filters && *filters;
    char *chain = dup_printf("%s%sscale=w=%s:h=%s:flags=%s,format=pix_fmts=%s", pre ? filters : "", pre ? "," : "",
                             w, h, scale_flags && *scale_flags ? scale_flags : default_scale_flags, fmt_name);
    if (!chain) return fail(err, AVERROR(ENOMEM), "filter chain");

    AVFilterInOut *outputs = avfilter_inout_alloc(), *inputs = avfilter_inout_alloc();
    if (!outputs || !inputs) {
        avfilter_inout_free(&outputs);
        avfilter_inout_free(&inputs);
        free(chain);
        return fail(err, AVERROR(ENOMEM), "filter endpoints");
    }
    outputs->name = av_strdup("in");
    outputs->filter_ctx = d->src;
    inputs->name = av_strdup("out");
    inputs->filter_ctx = d->sink;
    ret = avfilter_graph_parse_ptr(d->graph, chain, &inputs, &outputs, NULL);
    avfilter_inout_free(&outputs);
    avfilter_inout_free(&inputs);
    if (ret < 0) {
        if (err) {
            char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
            av_strerror(ret, buf, sizeof buf);
            *err = dup_printf("parse filters \"%s\": %s", chain, buf);
        }
        free(chain);
        return ret;
    }
    free(chain);
    if ((ret = avfilter_graph_config(d->graph, NULL)) < 0) return fail(err, ret, "configure filters");
    d->out_w = av_buffersink_get_w(d->sink);
    d->out_h = av_buffersink_get_h(d->sink);
    d->out_fmt = av_buffersink_get_format(d->sink);
    d->out_tb = av_buffersink_get_time_base(d->sink);
    d->out_rate = av_buffersink_get_frame_rate(d->sink);
    return 0;
}

int gbm_decoder_open(gbm_decoder **out, const char *path, int width, int height, int pix_fmt,
                     const char *scale_flags, const char *filters, int threads, char **err) {
    if (err) *err = NULL;
    *out = NULL;
    gbm_decoder *d = calloc(1, sizeof *d);
    if (!d) return fail(err, AVERROR(ENOMEM), "allocate decoder");
    int ret = open_input(path, AVMEDIA_TYPE_VIDEO, threads, &d->fmt, &d->dec, &d->stream, err);
    if (ret < 0) goto bad;
    AVStream *st = d->fmt->streams[d->stream];
    AVRational rate = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
    AVRational sar = d->dec->sample_aspect_ratio.num ? d->dec->sample_aspect_ratio : st->sample_aspect_ratio;
    d->info = (gbm_video_info){
        .width = d->dec->width, .height = d->dec->height, .pix_fmt = d->dec->pix_fmt,
        .frame_rate = rate.num ? from_av(rate) : (gbm_rational){0, 1},
        .time_base = from_av(st->time_base),
        .sar = sar.num ? from_av(sar) : (gbm_rational){0, 1},
        .color_space = d->dec->colorspace, .color_range = d->dec->color_range,
        .color_primaries = d->dec->color_primaries, .color_trc = d->dec->color_trc,
        .frame_count = st->nb_frames,
        .duration = d->fmt->duration != AV_NOPTS_VALUE ? d->fmt->duration / (double)AV_TIME_BASE : -1,
    };
    snprintf(d->info.codec_name, sizeof d->info.codec_name, "%s", avcodec_get_name(d->dec->codec_id));
    d->info.chroma_location = st->codecpar->chroma_location;
    if ((ret = build_graph(d, width, height, pix_fmt, scale_flags, filters, err)) < 0) goto bad;
    d->pkt = av_packet_alloc();
    d->decoded = av_frame_alloc();
    d->out = av_frame_alloc();
    if (!d->pkt || !d->decoded || !d->out) {
        ret = fail(err, AVERROR(ENOMEM), "allocate frames");
        goto bad;
    }
    *out = d;
    return 0;
bad:
    gbm_decoder_free(&d);
    return ret;
}

const gbm_video_info *gbm_decoder_info(const gbm_decoder *d) { return &d->info; }

void gbm_decoder_output(const gbm_decoder *d, int *width, int *height, int *pix_fmt, gbm_rational *time_base,
                        gbm_rational *frame_rate) {
    if (width) *width = d->out_w;
    if (height) *height = d->out_h;
    if (pix_fmt) *pix_fmt = d->out_fmt;
    if (time_base) *time_base = from_av(d->out_tb);
    if (frame_rate) *frame_rate = from_av(d->out_rate);
}

/* Feeds the graph one more decoded frame (or EOF). 0 = progress, < 0 = error. */
static int feed(gbm_decoder *d) {
    for (;;) {
        int ret = avcodec_receive_frame(d->dec, d->decoded);
        if (ret == 0) {
            d->decoded->pts = d->decoded->best_effort_timestamp;
            ret = av_buffersrc_add_frame_flags(d->src, d->decoded, AV_BUFFERSRC_FLAG_KEEP_REF);
            av_frame_unref(d->decoded);
            return ret;
        }
        if (ret == AVERROR_EOF) {
            d->decoder_eof = 1;
            return av_buffersrc_add_frame(d->src, NULL);
        }
        if (ret != AVERROR(EAGAIN)) return ret;
        if (d->demux_eof) {
            if ((ret = avcodec_send_packet(d->dec, NULL)) < 0 && ret != AVERROR_EOF) return ret;
            continue;
        }
        ret = av_read_frame(d->fmt, d->pkt);
        if (ret == AVERROR_EOF) {
            d->demux_eof = 1;
            continue;
        }
        if (ret < 0) return ret;
        if (d->pkt->stream_index == d->stream) ret = avcodec_send_packet(d->dec, d->pkt);
        av_packet_unref(d->pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) return ret;
    }
}

int gbm_decoder_next(gbm_decoder *d, gbm_frame *frame) {
    av_frame_unref(d->out);
    for (;;) {
        if (d->graph_eof) return 0;
        int ret = av_buffersink_get_frame(d->sink, d->out);
        if (ret == 0) break;
        if (ret == AVERROR_EOF) {
            d->graph_eof = 1;
            return 0;
        }
        if (ret != AVERROR(EAGAIN)) return ret;
        if (d->decoder_eof) return AVERROR_BUG; /* graph wants input after EOF was sent */
        if ((ret = feed(d)) < 0) return ret;
    }
    memset(frame, 0, sizeof *frame);
    for (int i = 0; i < 4; i++) {
        frame->data[i] = d->out->data[i];
        frame->linesize[i] = d->out->linesize[i];
    }
    frame->width = d->out->width;
    frame->height = d->out->height;
    frame->pix_fmt = d->out->format;
    frame->index = d->index++;
    frame->pts = d->out->pts;
    frame->time = d->out->pts == AV_NOPTS_VALUE ? -1 : d->out->pts * av_q2d(d->out_tb);
    return 1;
}

void gbm_decoder_free(gbm_decoder **pd) {
    gbm_decoder *d = *pd;
    if (!d) return;
    avfilter_graph_free(&d->graph);
    avcodec_free_context(&d->dec);
    avformat_close_input(&d->fmt);
    av_packet_free(&d->pkt);
    av_frame_free(&d->decoded);
    av_frame_free(&d->out);
    free(d);
    *pd = NULL;
}

/* ---------------------------------------------------------------- Audio */

typedef struct sample_buf {
    float *data;
    int64_t count, cap;
} sample_buf;

static int reserve(sample_buf *b, int64_t extra) {
    if (b->count + extra <= b->cap) return 0;
    int64_t cap = b->cap ? b->cap : 65536;
    while (cap < b->count + extra) cap *= 2;
    float *p = realloc(b->data, (size_t)cap * sizeof *p);
    if (!p) return AVERROR(ENOMEM);
    b->data = p;
    b->cap = cap;
    return 0;
}

static int convert(SwrContext *swr, AVFrame *f, sample_buf *b) {
    int in = f ? f->nb_samples : 0;
    int room = swr_get_out_samples(swr, in);
    if (room < 0) return room;
    int ret = reserve(b, room);
    if (ret < 0) return ret;
    uint8_t *dst = (uint8_t *)(b->data + b->count);
    int got = swr_convert(swr, &dst, room, f ? (const uint8_t **)f->extended_data : NULL, in);
    if (got < 0) return got;
    b->count += got;
    return got;
}

int gbm_decode_audio_mono(const char *path, int sample_rate, float **samples, int64_t *count, char **err) {
    if (err) *err = NULL;
    *samples = NULL;
    *count = 0;
    AVFormatContext *fmt = NULL;
    AVCodecContext *dec = NULL;
    SwrContext *swr = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    sample_buf buf = {0};
    int stream = -1;
    int ret = (pkt && frame) ? 0 : fail(err, AVERROR(ENOMEM), "allocate");
    if (ret < 0) goto done;
    if ((ret = open_input(path, AVMEDIA_TYPE_AUDIO, 1, &fmt, &dec, &stream, err)) < 0) goto done;
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
    if ((ret = swr_alloc_set_opts2(&swr, &mono, AV_SAMPLE_FMT_FLT, sample_rate, &dec->ch_layout, dec->sample_fmt,
                                   dec->sample_rate, 0, NULL)) < 0) {
        fail(err, ret, "configure resampler");
        goto done;
    }
    if ((ret = swr_init(swr)) < 0) {
        fail(err, ret, "init resampler");
        goto done;
    }
    int demux_eof = 0;
    for (;;) {
        ret = avcodec_receive_frame(dec, frame);
        if (ret == 0) {
            ret = convert(swr, frame, &buf);
            av_frame_unref(frame);
            if (ret < 0) {
                fail(err, ret, "resample");
                goto done;
            }
            continue;
        }
        if (ret == AVERROR_EOF) break;
        if (ret != AVERROR(EAGAIN)) {
            fail(err, ret, "decode audio");
            goto done;
        }
        if (demux_eof) {
            avcodec_send_packet(dec, NULL);
            continue;
        }
        ret = av_read_frame(fmt, pkt);
        if (ret == AVERROR_EOF) {
            demux_eof = 1;
            continue;
        }
        if (ret < 0) {
            fail(err, ret, "read audio");
            goto done;
        }
        if (pkt->stream_index == stream) ret = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            fail(err, ret, "decode audio");
            goto done;
        }
    }
    while ((ret = convert(swr, NULL, &buf)) > 0) {}
    if (ret < 0) {
        fail(err, ret, "flush resampler");
        goto done;
    }
    *samples = buf.data;
    *count = buf.count;
    buf.data = NULL;
    ret = 0;
done:
    free(buf.data);
    swr_free(&swr);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    return ret;
}

void gbm_samples_free(float *samples) { free(samples); }

/* ---------------------------------------------------------------- Converting */

struct gbm_converter {
    AVFilterGraph *graph;
    AVFilterContext *src, *sink;
    AVFrame *in, *out;
    int out_w, out_h, out_fmt;
    int64_t index;
};

int gbm_converter_open(gbm_converter **out, int src_w, int src_h, int src_pix_fmt, int src_color_space,
                       int src_color_range, const char *filters, char **err) {
    if (err) *err = NULL;
    *out = NULL;
    gbm_converter *c = calloc(1, sizeof *c);
    if (!c) return fail(err, AVERROR(ENOMEM), "allocate converter");
    int ret;
    c->graph = avfilter_graph_alloc();
    c->in = av_frame_alloc();
    c->out = av_frame_alloc();
    if (!c->graph || !c->in || !c->out) {
        ret = fail(err, AVERROR(ENOMEM), "allocate converter");
        goto bad;
    }
    c->graph->nb_threads = 1;
    c->src = avfilter_graph_alloc_filter(c->graph, avfilter_get_by_name("buffer"), "in");
    if (!c->src) {
        ret = fail(err, AVERROR(ENOMEM), "create buffer source");
        goto bad;
    }
    AVBufferSrcParameters *par = av_buffersrc_parameters_alloc();
    if (!par) {
        ret = fail(err, AVERROR(ENOMEM), "buffer source parameters");
        goto bad;
    }
    par->format = src_pix_fmt;
    par->width = src_w;
    par->height = src_h;
    par->time_base = (AVRational){1, 1};
    par->sample_aspect_ratio = (AVRational){1, 1};
    par->color_space = (enum AVColorSpace)src_color_space;
    par->color_range = (enum AVColorRange)src_color_range;
    ret = av_buffersrc_parameters_set(c->src, par);
    av_free(par);
    if (ret < 0 || (ret = avfilter_init_dict(c->src, NULL)) < 0) {
        fail(err, ret, "init buffer source");
        goto bad;
    }
    c->sink = avfilter_graph_alloc_filter(c->graph, avfilter_get_by_name("buffersink"), "out");
    if (!c->sink) {
        ret = fail(err, AVERROR(ENOMEM), "create buffer sink");
        goto bad;
    }
    if ((ret = avfilter_init_dict(c->sink, NULL)) < 0) {
        fail(err, ret, "init buffer sink");
        goto bad;
    }
    AVFilterInOut *outputs = avfilter_inout_alloc(), *inputs = avfilter_inout_alloc();
    if (!outputs || !inputs) {
        avfilter_inout_free(&outputs);
        avfilter_inout_free(&inputs);
        ret = fail(err, AVERROR(ENOMEM), "filter endpoints");
        goto bad;
    }
    outputs->name = av_strdup("in");
    outputs->filter_ctx = c->src;
    inputs->name = av_strdup("out");
    inputs->filter_ctx = c->sink;
    const char *chain = filters && *filters ? filters : "null";
    ret = avfilter_graph_parse_ptr(c->graph, chain, &inputs, &outputs, NULL);
    avfilter_inout_free(&outputs);
    avfilter_inout_free(&inputs);
    if (ret < 0) {
        if (err) {
            char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
            av_strerror(ret, buf, sizeof buf);
            *err = dup_printf("parse filters \"%s\": %s", chain, buf);
        }
        goto bad;
    }
    if ((ret = avfilter_graph_config(c->graph, NULL)) < 0) {
        fail(err, ret, "configure filters");
        goto bad;
    }
    c->out_w = av_buffersink_get_w(c->sink);
    c->out_h = av_buffersink_get_h(c->sink);
    c->out_fmt = av_buffersink_get_format(c->sink);
    c->in->format = src_pix_fmt;
    c->in->width = src_w;
    c->in->height = src_h;
    if ((ret = av_frame_get_buffer(c->in, 0)) < 0) {
        fail(err, ret, "allocate frame");
        goto bad;
    }
    *out = c;
    return 0;
bad:
    gbm_converter_free(&c);
    return ret;
}

void gbm_converter_output(const gbm_converter *c, int *width, int *height, int *pix_fmt) {
    if (width) *width = c->out_w;
    if (height) *height = c->out_h;
    if (pix_fmt) *pix_fmt = c->out_fmt;
}

int gbm_converter_run(gbm_converter *c, const uint8_t *const data[4], const int linesize[4], gbm_frame *frame) {
    av_frame_unref(c->out);
    int ret = av_frame_make_writable(c->in);
    if (ret < 0) return ret;
    av_image_copy2(c->in->data, c->in->linesize, (uint8_t *const *)data, linesize, (enum AVPixelFormat)c->in->format,
                   c->in->width, c->in->height);
    c->in->pts = c->index;
    c->in->sample_aspect_ratio = (AVRational){1, 1};
    if ((ret = av_buffersrc_add_frame_flags(c->src, c->in, AV_BUFFERSRC_FLAG_KEEP_REF)) < 0) return ret;
    if ((ret = av_buffersink_get_frame(c->sink, c->out)) < 0) return ret == AVERROR(EAGAIN) ? AVERROR_BUG : ret;
    memset(frame, 0, sizeof *frame);
    for (int i = 0; i < 4; i++) {
        frame->data[i] = c->out->data[i];
        frame->linesize[i] = c->out->linesize[i];
    }
    frame->width = c->out->width;
    frame->height = c->out->height;
    frame->pix_fmt = c->out->format;
    frame->index = c->index++;
    frame->pts = c->out->pts;
    frame->time = (double)c->out->pts;
    return 0;
}

void gbm_converter_free(gbm_converter **pc) {
    gbm_converter *c = *pc;
    if (!c) return;
    avfilter_graph_free(&c->graph);
    av_frame_free(&c->in);
    av_frame_free(&c->out);
    free(c);
    *pc = NULL;
}

/* ---------------------------------------------------------------- Encoding */

struct gbm_encoder {
    AVFormatContext *fmt;
    AVCodecContext *enc;
    AVStream *st;
    AVFrame *frame;
    AVPacket *pkt;
    int finished;
};

static const char *codec_name(int codec) {
    switch (codec) {
    case GBM_CODEC_FFV1: return "ffv1";
    case GBM_CODEC_FFVHUFF: return "ffvhuff";
    }
    return NULL;
}

int gbm_encoder_open(gbm_encoder **out, const char *path, const gbm_encoder_config *c, char **err) {
    if (err) *err = NULL;
    *out = NULL;
    gbm_encoder *e = calloc(1, sizeof *e);
    if (!e) return fail(err, AVERROR(ENOMEM), "allocate encoder");
    AVDictionary *opts = NULL;
    int ret;
    const char *name = codec_name(c->codec);
    const AVCodec *codec = name ? avcodec_find_encoder_by_name(name) : NULL;
    if (!codec) {
        ret = fail(err, AVERROR_ENCODER_NOT_FOUND, name ? name : "unknown codec");
        goto bad;
    }
    if ((ret = avformat_alloc_output_context2(&e->fmt, NULL, "matroska", path)) < 0) {
        fail(err, ret, "allocate muxer");
        goto bad;
    }
    e->fmt->flags |= AVFMT_FLAG_BITEXACT;
    e->enc = avcodec_alloc_context3(codec);
    e->st = avformat_new_stream(e->fmt, NULL);
    e->frame = av_frame_alloc();
    e->pkt = av_packet_alloc();
    if (!e->enc || !e->st || !e->frame || !e->pkt) {
        ret = fail(err, AVERROR(ENOMEM), "allocate encoder");
        goto bad;
    }
    AVRational rate = to_av(c->frame_rate);
    e->enc->width = c->width;
    e->enc->height = c->height;
    e->enc->pix_fmt = (enum AVPixelFormat)c->pix_fmt;
    e->enc->time_base = av_inv_q(rate);
    e->enc->framerate = rate;
    if (c->sar.num && c->sar.den) e->enc->sample_aspect_ratio = to_av(c->sar);
    e->enc->colorspace = (enum AVColorSpace)c->color_space;
    e->enc->color_range = (enum AVColorRange)c->color_range;
    e->enc->color_primaries = (enum AVColorPrimaries)c->color_primaries;
    e->enc->color_trc = (enum AVColorTransferCharacteristic)c->color_trc;
    e->enc->chroma_sample_location = (enum AVChromaLocation)c->chroma_location;
    e->enc->thread_count = c->threads;
    e->enc->flags |= AV_CODEC_FLAG_BITEXACT;
    if (e->fmt->oformat->flags & AVFMT_GLOBALHEADER) e->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (c->codec_options && *c->codec_options &&
        (ret = av_dict_parse_string(&opts, c->codec_options, "=", ":", 0)) < 0) {
        fail(err, ret, "parse codec options");
        goto bad;
    }
    if ((ret = avcodec_open2(e->enc, codec, &opts)) < 0) {
        fail(err, ret, "open encoder");
        goto bad;
    }
    if (av_dict_count(opts)) {
        const AVDictionaryEntry *t = av_dict_iterate(opts, NULL);
        if (err) *err = dup_printf("unknown codec option %s", t->key);
        ret = AVERROR_OPTION_NOT_FOUND;
        goto bad;
    }
    if ((ret = avcodec_parameters_from_context(e->st->codecpar, e->enc)) < 0) {
        fail(err, ret, "stream parameters");
        goto bad;
    }
    e->st->time_base = e->enc->time_base;
    e->st->avg_frame_rate = rate;
    e->st->sample_aspect_ratio = e->enc->sample_aspect_ratio;
    if ((ret = avio_open(&e->fmt->pb, path, AVIO_FLAG_WRITE)) < 0) {
        fail(err, ret, "open output");
        goto bad;
    }
    if ((ret = avformat_write_header(e->fmt, NULL)) < 0) {
        fail(err, ret, "write header");
        goto bad;
    }
    e->frame->format = c->pix_fmt;
    e->frame->width = c->width;
    e->frame->height = c->height;
    if ((ret = av_frame_get_buffer(e->frame, 0)) < 0) {
        fail(err, ret, "allocate frame");
        goto bad;
    }
    av_dict_free(&opts);
    *out = e;
    return 0;
bad:
    av_dict_free(&opts);
    gbm_encoder_free(&e);
    return ret;
}

static int drain(gbm_encoder *e) {
    for (;;) {
        int ret = avcodec_receive_packet(e->enc, e->pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
        if (ret < 0) return ret;
        av_packet_rescale_ts(e->pkt, e->enc->time_base, e->st->time_base);
        e->pkt->stream_index = e->st->index;
        if ((ret = av_interleaved_write_frame(e->fmt, e->pkt)) < 0) return ret;
    }
}

int gbm_encoder_write(gbm_encoder *e, const uint8_t *const data[4], const int linesize[4], int64_t index) {
    int ret = av_frame_make_writable(e->frame);
    if (ret < 0) return ret;
    av_image_copy2(e->frame->data, e->frame->linesize, (uint8_t *const *)data, linesize,
                   (enum AVPixelFormat)e->frame->format, e->frame->width, e->frame->height);
    e->frame->pts = index;
    e->frame->duration = 1;
    e->frame->sample_aspect_ratio = e->enc->sample_aspect_ratio;
    e->frame->colorspace = e->enc->colorspace;
    e->frame->color_range = e->enc->color_range;
    e->frame->color_primaries = e->enc->color_primaries;
    e->frame->color_trc = e->enc->color_trc;
    e->frame->chroma_location = e->enc->chroma_sample_location;
    if ((ret = avcodec_send_frame(e->enc, e->frame)) < 0) return ret;
    return drain(e);
}

int gbm_encoder_finish(gbm_encoder *e) {
    if (e->finished) return 0;
    int ret = avcodec_send_frame(e->enc, NULL);
    if (ret < 0 && ret != AVERROR_EOF) return ret;
    if ((ret = drain(e)) < 0) return ret;
    if ((ret = av_write_trailer(e->fmt)) < 0) return ret;
    e->finished = 1;
    return avio_closep(&e->fmt->pb);
}

void gbm_encoder_free(gbm_encoder **pe) {
    gbm_encoder *e = *pe;
    if (!e) return;
    if (e->fmt && e->fmt->pb) avio_closep(&e->fmt->pb);
    avformat_free_context(e->fmt);
    avcodec_free_context(&e->enc);
    av_frame_free(&e->frame);
    av_packet_free(&e->pkt);
    free(e);
    *pe = NULL;
}
