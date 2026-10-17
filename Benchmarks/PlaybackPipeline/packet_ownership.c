/* Standalone FFmpeg ownership experiment, NOT the native Swift playback runtime.
 * A version-gated, public AVPacket declaration supports this Linux lab when
 * development headers are absent. AVFormatContext remains opaque; no private
 * layout is used. Production builds must use their actual FFmpeg SDK headers.
 * With FFmpeg development packages installed, define USE_FFMPEG_HEADERS.
 * Public contracts: libavformat/avformat.h and libavcodec/packet.h (7.1 / 8.x).
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef USE_FFMPEG_HEADERS
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/packet.h>
#include <libavutil/avutil.h>
#else
typedef struct AVBufferRef AVBufferRef;
typedef struct AVFormatContext AVFormatContext;
typedef struct AVInputFormat AVInputFormat;
typedef struct AVDictionary AVDictionary;
typedef struct AVRational { int num; int den; } AVRational;
/* Public AVPacket/AVPacketSideData declaration from FFmpeg n7.1.5 packet.h,
 * lines 359-363 and 478-543 (comments omitted). Used only with the exact
 * libavcodec version gate below. Allocate/free through FFmpeg, never sizeof. */
typedef struct AVPacketSideData { uint8_t *data; size_t size; int type; } AVPacketSideData;
typedef struct AVPacket {
    AVBufferRef *buf;
    int64_t pts, dts;
    uint8_t *data;
    int size, stream_index, flags;
    AVPacketSideData *side_data;
    int side_data_elems;
    int64_t duration, pos;
    void *opaque;
    AVBufferRef *opaque_ref;
    AVRational time_base;
} AVPacket;
extern AVPacket *av_packet_alloc(void);
extern void av_packet_free(AVPacket **pkt);
extern void av_packet_unref(AVPacket *pkt);
extern void av_packet_move_ref(AVPacket *dst, AVPacket *src);
extern uint8_t *av_packet_get_side_data(const AVPacket *, int, size_t *);
extern unsigned avformat_version(void);
extern unsigned avcodec_version(void);
extern const char *av_version_info(void);
extern int avformat_open_input(AVFormatContext **, const char *, const AVInputFormat *, AVDictionary **);
extern int avformat_find_stream_info(AVFormatContext *, AVDictionary **);
extern int av_read_frame(AVFormatContext *, AVPacket *);
extern int avformat_seek_file(AVFormatContext *, int, int64_t, int64_t, int64_t, int);
extern int avformat_flush(AVFormatContext *);
extern void avformat_close_input(AVFormatContext **);
extern void av_log_set_level(int);
#define AVERROR_EOF (-541478725)
#endif
static uint64_t now_ns(clockid_t c) {
    struct timespec t;
    if (clock_gettime(c, &t)) { perror("clock_gettime"); exit(2); }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static void fail(const char *op, int code) { fprintf(stderr, "%s: %d\n", op, code); exit(2); }
static AVPacket *allocate(uint64_t *count) {
    AVPacket *p = av_packet_alloc();
    if (!p) fail("av_packet_alloc", -12);
    ++*count; return p;
}
static void receipt(FILE *f, const AVPacket *p) {
    if (!f || !p) return;
    fprintf(f, "packet:%d:%" PRId64 ":%" PRId64 ":%" PRId64 ":%" PRId64 ":%d:%d:%d:%d:%d\n",
            p->stream_index, p->pts, p->dts, p->duration, p->pos,
            p->flags, p->size, p->side_data_elems, p->time_base.num, p->time_base.den);
    if (p->size > 0 && fwrite(p->data, 1, (size_t)p->size, f) != (size_t)p->size) fail("payload receipt", errno);
    for (int i = 0; i < p->side_data_elems; ++i) {
        const AVPacketSideData *sd = &p->side_data[i];
        fprintf(f, "\nside-data:%d:%zu\n", sd->type, sd->size);
        if (fwrite(sd->data, 1, sd->size, f) != sd->size) fail("side-data receipt", errno);
    }
}
int main(int argc, char **argv) {
    if (argc < 5 || argc > 7) {
        fprintf(stderr, "usage: %s baseline|adopt|scratch input rounds retention [trace-file|-] [seek-seconds]\n", argv[0]); return 2;
    }
    int mode = !strcmp(argv[1], "baseline") ? 0 : !strcmp(argv[1], "adopt") ? 1 : !strcmp(argv[1], "scratch") ? 2 : -1;
    char *end = NULL;
    long rounds = strtol(argv[3], &end, 10);
    if (mode < 0 || *end || rounds < 1 || rounds > 10000) return 2;
    long retention = strtol(argv[4], &end, 10);
    if (*end || retention < 1 || retention > 1024) return 2;
    double seek = -1;
    if (argc == 7) { seek = strtod(argv[6], &end); if (*end || !(seek >= 0 && seek <= 86400)) return 2; }
    unsigned fm = avformat_version() >> 16, cm = avcodec_version() >> 16;
    if (!((fm == 61 && cm == 61) || (fm == 62 && cm == 62))) fail("qualify this FFmpeg ABI first", (int)fm);
#ifndef USE_FFMPEG_HEADERS
    if (avcodec_version() != ((61u << 16) | (19u << 8) | 101u))
        fail("No matching SDK headers: qualify this public AVPacket declaration first", (int)avcodec_version());
#endif
    av_log_set_level(-8);
    FILE *trace = argc >= 6 && strcmp(argv[5], "-") ? fopen(argv[5], "wb") : NULL;
    if (argc >= 6 && strcmp(argv[5], "-") && !trace) { perror("trace"); return 2; }
    AVPacket **held = calloc((size_t)retention, sizeof(*held));
    if (!held) fail("calloc", -12);
    uint64_t packets = 0, allocations = 0, moves = 0, read_wall = 0, read_cpu = 0, setup_wall = 0;
    for (long round = 0; round < rounds; ++round) {
        AVFormatContext *context = NULL;
        uint64_t s = now_ns(CLOCK_MONOTONIC);
        int r = avformat_open_input(&context, argv[2], NULL, NULL);
        if (r < 0) fail("open", r);
        if ((r = avformat_find_stream_info(context, NULL)) < 0) fail("probe", r);
        if (seek >= 0) {
            r = avformat_seek_file(context, -1, INT64_MIN, (int64_t)(seek * 1000000), INT64_MAX, 1);
            if (r < 0) fail("seek", r);
            avformat_flush(context);
        }
        setup_wall += now_ns(CLOCK_MONOTONIC) - s;
        uint64_t c = now_ns(CLOCK_PROCESS_CPUTIME_ID), w = now_ns(CLOCK_MONOTONIC);
        AVPacket *scratch = mode == 2 ? allocate(&allocations) : NULL;
        size_t slot = 0;
        for (;;) {
            AVPacket *temporary = mode == 2 ? scratch : allocate(&allocations);
            r = av_read_frame(context, temporary);
            if (r < 0) {
                if (mode != 2) av_packet_free(&temporary);
                if (r != AVERROR_EOF) fail("read", r);
                break;
            }
            AVPacket *owned;
            if (mode == 1) { owned = temporary; temporary = NULL; }
            else {
                owned = allocate(&allocations);
                av_packet_move_ref(owned, temporary); ++moves;
                if (mode == 0) av_packet_free(&temporary);
            }
            /* Model bounded queued ownership: previous objects survive later
             * reads until their ring slot is revisited. No output is discarded. */
            receipt(trace, held[slot]);
            av_packet_free(&held[slot]);
            held[slot] = owned;
            slot = (slot + 1) % (size_t)retention;
            ++packets;
        }
        /* Drain in FIFO order, including partially populated rings. */
        for (long i = 0; i < retention; ++i) {
            size_t j = (slot + (size_t)i) % (size_t)retention;
            receipt(trace, held[j]); av_packet_free(&held[j]);
        }
        av_packet_free(&scratch);
        read_wall += now_ns(CLOCK_MONOTONIC) - w;
        read_cpu += now_ns(CLOCK_PROCESS_CPUTIME_ID) - c;
        avformat_close_input(&context);
    }
    free(held);
    if (trace && fclose(trace)) fail("close receipt", errno);
    printf("{\"variant\":\"%s\",\"ffmpeg\":\"%s\",\"rounds\":%ld,\"retention\":%ld,\"packets\":%" PRIu64 ",\"explicit_header_allocations\":%" PRIu64 ",\"explicit_moves\":%" PRIu64 ",\"open_probe_seek_ns\":%" PRIu64 ",\"demux_wall_ns\":%" PRIu64 ",\"demux_cpu_ns\":%" PRIu64 ",\"receipt_mode\":%s}\n", argv[1], av_version_info(), rounds, retention, packets, allocations, moves, setup_wall, read_wall, read_cpu, trace ? "true" : "false");
    return 0;
}
