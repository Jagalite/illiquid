#ifndef AUDIO_PCM_PROBE_H
#define AUDIO_PCM_PROBE_H
#include <stdint.h>
uint64_t audio_pcm_heap_bytes(void);
uint64_t audio_pcm_process_cpu_ns(void);
#endif
