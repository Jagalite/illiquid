#!/usr/bin/env python3
"""Prepare the Linux-only packet API shim; invoke run-packet-probe.sh."""
import argparse
from pathlib import Path
HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
out=p.parse_args().output.resolve();out.mkdir(parents=True,exist_ok=True)
header=(HERE/'packet_ownership.c').read_text().split('static uint64_t now_ns')[0]
header+='''\nextern int av_new_packet(AVPacket *, int);
extern uint8_t *av_packet_new_side_data(AVPacket *, int, size_t);
extern void *av_malloc(size_t);
extern void av_free(void *);
extern AVBufferRef *av_buffer_create(uint8_t *, size_t, void (*)(void *, uint8_t *), void *, int);
extern AVBufferRef *av_buffer_ref(const AVBufferRef *);
extern void av_buffer_unref(AVBufferRef **);
static inline int illiquid_averror_nomem(void) { return -12; }
static inline int64_t illiquid_nopts_value(void) { return INT64_MIN; }
static inline int illiquid_packet_is_corrupt(const AVPacket *p) { return (p->flags & 2) != 0; }
static inline int illiquid_packet_is_keyframe(const AVPacket *p) { return (p->flags & 1) != 0; }
'''
(out/'packet_api.h').write_text(header)
(out/'module.modulemap').write_text('module CFFmpeg { header "packet_api.h" export * }\n')
