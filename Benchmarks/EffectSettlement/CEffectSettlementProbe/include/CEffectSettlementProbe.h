#ifndef C_EFFECT_SETTLEMENT_PROBE_H
#define C_EFFECT_SETTLEMENT_PROBE_H
#include <stdint.h>
uint64_t settlement_cpu_nanoseconds(void);
int settlement_meter_available(void);
int settlement_meter_self_check(void);
void settlement_meter_begin(void);
void settlement_meter_end(void);
uint64_t settlement_meter_requests(void);
uint64_t settlement_meter_bytes(void);
#endif
