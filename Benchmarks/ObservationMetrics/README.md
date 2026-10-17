# Runtime observation metrics

The runtime counts every audio, video, clock, subtitle, preroll, drain, and
renderer-failure observation. This experiment replaces its seven-key dictionary
with inline optional counters while keeping the existing snapshot semantics and
callback scheduling.

The baseline is `68274d1b09dcc866296321a5a8858efc297c4f19`, the integrated `main`
before this investigation. `run.py` extracts the complete contiguous production
observation region from that revision and the working tree. Both variants use
the same harness and compiler flags. No decoder, renderer, or operating-system
API is replaced by a shim.

## Reproduce

Use Python 3 and Swift 6.1 or newer, with the pinned baseline available in Git:

```sh
python3 Benchmarks/ObservationMetrics/run.py --mode all \
  --pairs 6 --iterations 4000000 \
  --output /tmp/illiquid-observation-results
```

The output directory must not exist. `--mode test` runs baseline and candidate
tests in debug and release; `--mode bench` builds and measures the optimized
binaries. All output, including generated Swift sources, test logs, raw JSONL
measurements, summaries, compiler commands, and hashes, stays in the output
directory. The runner uses only the Python standard library and does not fetch
dependencies. On macOS, both the temporary package and benchmark target macOS 26.

The canonical cloud Linux run adds `--ledger-only-tests`: that host can fail
libdispatch thread inspection in the unchanged asynchronous tests. This option
filters execution to the five ledger tests. The native macOS workflow leaves
it off. Its component job runs all eleven component tests; its integration job
builds the full app graph and runs focused observation tests.

## Workloads

| Case | Timed work | Reported unit |
| --- | --- | --- |
| `steady-1` | One request per delivery and retained publication | ns/request |
| `steady-4` | Four requests per delivery and retained publication | ns/request |
| `steady-16` | Sixteen requests per delivery and retained publication | ns/request |
| `batch-16` | Sixteen requests per delivery; no retained publication | ns/request |
| `retained-64` | Four requests per delivery, also retaining 64 snapshots | ns/request |
| `snapshot-only` | Source lookup and scalar read from an unchanged snapshot | ns/read |
| `control` | Checksum and function-call loop | ns/iteration |

The steady cases retain the previous publication **across the next ledger
mutation**, matching `NativePlaybackRuntime.lastObservationMetrics`. Reading it
after mutation makes its independence observable. Releasing it before the next
request would miss the dictionary's copy-on-write cost.

The workload is deterministic: each 256 requests includes 126 audio, 95 video,
31 clock, and one of each other source. These are fixture frequencies, not
observed player telemetry. Request/delivery accounting, source dispatch, loop
overhead, and a small read of the prior publication are inside timing. Warm-up,
the independent array oracle, and full result validation are outside timing.

Each of six rounds runs each variant in a fresh process, alternating their
order and the case order. Paired checksums must match. The harness also compares
all final, published, and retained counters, delays, and source presence against
the independent oracle. Raw timings are retained; the runner does not subtract
the control or enforce machine-dependent timing thresholds.

`snapshot-only` is a lookup control. The compiler may borrow or eliminate copies
of its unchanged aggregate, so it does not measure the full cost of copying a
snapshot. `retained-64` exercises actual snapshot storage, and each result records
the inline snapshot and ledger sizes/strides.

## Correctness and scope

The component package runs the dictionary-oracle regression suite and copies
the six existing Foundation-only coalescer test bodies unchanged. Tests cover
all seven sources, retained snapshot independence, zero versus absence, lazy
defaults, thrown inout writeback, delay windows, unsigned wrap, and 10,000 mixed
events, plus concurrent requests, reentrant follow-ups, and urgent preemption.

The [workflow](../../.github/workflows/observation-metrics-performance.yml) also
builds the complete macOS app graph and runs the native observation and periodic
diagnostic-formatting regressions. The [research report](../../Documentation/OBSERVATION_METRICS_PERFORMANCE.md)
records results and limitations. Component nanoseconds must not be presented as
whole-player CPU, playback throughput, latency, or energy savings.
