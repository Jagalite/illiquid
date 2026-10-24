"""Deterministic inputs for baseline/candidate AudioDelayTimeline comparison.

All non-finite values use the strings ``nan``, ``inf`` or ``-inf`` so the
serialized fixtures remain strict JSON. ``reject_at`` is a one-based emitter
callback number local to its operation. Retries are explicit later operations.
The constructors return independent dictionaries; callers may annotate cases
without changing another operation or a later call to ``make_cases``.
"""

from __future__ import annotations

from copy import deepcopy
import random


def _frame(
    *,
    time: float = 0.0,
    samples: int = 480,
    channels: int = 2,
    rate: int = 48_000,
    generation: int = 4,
    revision: int = 7,
    seed: int = 1,
    source_rate: int = 44_100,
    source_channels: int | None = None,
    layout: str | None = None,
    downmix: bool = False,
    conversion: bool = True,
) -> dict:
    source_channels = channels if source_channels is None else source_channels
    if layout is None:
        layout = {2: "stereo", 6: "5.1", 8: "7.1"}.get(source_channels, "unknown")
    return {
        "time": time,
        "samples": samples,
        "channels": channels,
        "rate": rate,
        "generation": generation,
        "revision": revision,
        "seed": seed,
        "source_rate": source_rate,
        "source_channels": source_channels,
        "layout": layout,
        "downmix": downmix,
        "conversion": conversion,
    }


def _consume(frame: dict, reject_at: int | None = None) -> dict:
    operation = {"kind": "consume", "frame": deepcopy(frame)}
    if reject_at is not None:
        operation["reject_at"] = reject_at
    return operation


def _finish(duration: float | str | None, reject_at: int | None = None) -> dict:
    operation = {"kind": "finish", "duration": duration}
    if reject_at is not None:
        operation["reject_at"] = reject_at
    return operation


def _case(
    name: str,
    delay: float | str,
    operations: list[dict],
    *,
    target: float = 0.0,
    fallback: dict | None = None,
) -> dict:
    return {
        "name": name,
        "delay": delay,
        "target": target,
        "fallback": deepcopy(fallback if fallback is not None else _frame(samples=0)),
        "operations": deepcopy(operations),
    }


def make_cases() -> list[dict]:
    """Return named boundary/rejection cases and 100 seeded random scenarios.

    Random scenarios use at most four source frames of 1,024 samples each,
    absolute delays at most 0.1 seconds, and bounded finite targets/timestamps.
    Larger clamped-delay boundary cases reject the third silence callback so
    the differential transcript never needs to retain a full 10-second gap.
    Full 10-second workloads live separately in ``measurement_cases``.
    """
    cases: list[dict] = []
    for channels in (2, 6, 8):
        source = _frame(channels=channels)
        fallback = _frame(channels=channels, samples=0)
        cases.append(_case(f"zero-consecutive-{channels}ch", 0.0, [
            _consume(source),
            _consume(_frame(time=0.01, samples=1_024, channels=channels, seed=2)),
            _finish(0.1),
        ], fallback=fallback))
        cases.append(_case(f"positive-full-and-partial-{channels}ch", 0.1, [
            _consume(source), _finish(0.11),
        ], fallback=fallback))
        cases.append(_case(f"positive-exact-chunks-{channels}ch", 0.064, [
            _consume(source), _finish(None),
        ], fallback=fallback))
        cases.append(_case(f"negative-partial-trim-tail-{channels}ch", -0.005, [
            _consume(source), _finish(0.1),
        ], fallback=fallback))

    cases.extend([
        _case("positive-subchunk", 0.001, [_consume(_frame()), _finish(None)]),
        _case("positive-one-rounded-sample", 1 / 48_000, [
            _consume(_frame(samples=1)), _finish(None),
        ]),
        _case("target-inside-initial-gap", 0.1, [
            _consume(_frame()), _finish(None),
        ], target=0.08),
        _case("late-source-does-not-extend-initial-gap", 0.1, [
            _consume(_frame(time=0.05)), _finish(None),
        ]),
        _case("seek-after-delay-trim-then-survive", 2.0, [
            _consume(_frame(time=2.0)),
            _consume(_frame(time=3.0, seed=2)),
            _finish(5.01),
        ], target=5.0),
        _case("negative-exact-source-frame-boundary", -1_024 / 48_000, [
            _consume(_frame(samples=1_024)),
            _consume(_frame(time=1_024 / 48_000, seed=2)),
            _finish(0.04),
        ]),
        _case("fractional-sample-target", -0.005, [
            _consume(_frame()), _finish(0.011),
        ], target=0.5 / 48_000),
        _case("trimmed-source-metadata-beats-fallback", -10.0, [
            _consume(_frame(samples=480, channels=8, generation=19,
                            revision=27, source_rate=96_000, source_channels=8,
                            layout="7.1-wide", conversion=False, seed=123)),
            _finish(0.02),
        ], fallback=_frame(samples=0, channels=2, generation=2, revision=3,
                           source_rate=32_000, source_channels=6,
                           layout="5.1-fallback", downmix=True)),
        _case("last-of-two-trimmed-formats-wins", -1.0, [
            _consume(_frame(channels=8, revision=8, source_rate=96_000)),
            _consume(_frame(time=0.01, channels=6, generation=9, revision=13,
                            source_channels=8, layout="7.1-source",
                            downmix=True, conversion=False, seed=12)),
            _finish(0.02),
        ]),
        _case("finish-at-or-before-cursor", -0.005, [
            _consume(_frame()), _finish(0.005), _finish(0.002),
            _finish(0.0), _finish(-1.0), _finish(None),
        ]),
        _case("repeated-finish-full-partial-full", -0.1, [
            _finish(1_024 / 48_000),
            _finish(1_025 / 48_000),
            _finish(2_049 / 48_000),
        ], fallback=_frame(samples=0, channels=8, revision=42)),
    ])

    for delay, label in ((0.0, "zero"), (0.1, "positive"), (-0.1, "negative")):
        cases.append(_case(f"empty-{label}-one-sample-fallback", delay, [
            _finish(None),
        ], fallback=_frame(samples=0, channels=6, generation=15, revision=23,
                           source_rate=32_000, source_channels=8,
                           layout="empty-source", downmix=True)))
    cases.append(_case("empty-negative-finite-duration", -0.1, [
        _finish(0.01),
    ], fallback=_frame(samples=0, channels=8)))

    for duration in ("nan", "inf", "-inf"):
        cases.append(_case(f"nonfinite-finish-after-output-{duration}", -0.005, [
            _consume(_frame()), _finish(duration),
        ]))
        cases.append(_case(f"nonfinite-finish-empty-{duration}", -0.005, [
            _finish(duration),
        ]))
    for delay, label in ((100.0, "above"), (-100.0, "below"),
                         ("nan", "nan"), ("inf", "inf"), ("-inf", "negative-inf")):
        cases.append(_case(f"bounded-delay-{label}", delay, [
            _consume(_frame(), reject_at=3), _finish(0.01),
        ]))

    # At 48 kHz, a 0.1-second delay emits five silent chunks, then source PCM.
    # Rejecting callback six therefore rejects the original PCM, not silence.
    for reject_at in (1, 3, 6):
        source = _frame(seed=91)
        cases.append(_case(f"consume-reject-{reject_at}-then-retry", 0.1, [
            _consume(source, reject_at=reject_at), _consume(source), _finish(None),
        ]))
    # The initial -5 ms trim leaves cursor=5 ms. Padding to 100 ms emits five
    # chunks; callbacks one, three and five cover start, middle and partial tail.
    for reject_at in (1, 3, 5):
        cases.append(_case(f"tail-reject-{reject_at}-then-retry", -0.005, [
            _consume(_frame(seed=92)),
            _finish(0.1, reject_at=reject_at), _finish(0.1),
        ]))
    cases.append(_case("empty-fallback-reject-then-retry", 0.0, [
        _finish(None, reject_at=1), _finish(None),
    ]))

    cases.append(_case("format-change-after-silence-cache", -0.005, [
        _consume(_frame()), _finish(0.05),
        _consume(_frame(time=0.055, channels=8, generation=9, revision=14,
                        source_rate=96_000, source_channels=8, seed=2)),
        _finish(0.1),
        _consume(_frame(time=0.105, channels=6, generation=10, revision=15,
                        source_channels=8, downmix=True, seed=3)),
        _finish(0.15),
    ]))
    cases.append(_case("same-byte-count-new-format-metadata", -0.005, [
        _consume(_frame()), _finish(0.05),
        _consume(_frame(time=0.055, channels=2, rate=44_100, generation=9,
                        revision=14, source_rate=96_000, source_channels=6,
                        layout="5.1-source", downmix=True, conversion=False,
                        seed=2)),
        _finish(0.1),
    ]))
    cases.append(_case("rejected-initial-silence-then-new-format", 0.1, [
        _consume(_frame(), reject_at=2),
        _consume(_frame(channels=8, generation=17, revision=18, seed=3)),
        _finish(None),
    ]))

    rng = random.Random(0xA0D10)
    sample_counts = (1, 2, 31, 127, 256, 480, 1_023, 1_024)
    for index in range(100):
        delay = rng.choice((-0.1, -0.033, -0.005, 0.0, 0.001, 0.017, 0.1))
        if index % 5 == 0:
            delay = rng.uniform(-0.1, 0.1)
        target = rng.choice((0.0, 0.0, 0.5 / 48_000, 0.003, 0.02, 0.09))
        channels = rng.choice((2, 6, 8))
        rate = rng.choice((44_100, 48_000, 48_000, 48_000, 96_000))
        next_time = rng.choice((0.0, 0.01, 0.05, 0.1))
        operations: list[dict] = []
        for frame_index in range(rng.randint(1, 4)):
            samples = rng.choice(sample_counts)
            source_channels = rng.choice((channels, 8))
            source = _frame(
                time=next_time,
                samples=samples,
                channels=channels,
                rate=rate,
                generation=4 + index % 5,
                revision=7 + frame_index,
                seed=rng.randint(1, 65_535),
                source_rate=rng.choice((32_000, 44_100, 48_000, 96_000)),
                source_channels=source_channels,
                layout=f"random-layout-{source_channels}",
                downmix=source_channels > channels,
                conversion=bool(rng.randrange(2)),
            )
            reject_at = rng.choice((None, None, None, 1, 2, 3))
            operations.append(_consume(source, reject_at=reject_at))
            if reject_at is not None and rng.randrange(2) == 0:
                operations.append(_consume(source))
            next_time += samples / rate
        duration = max(target, next_time, next_time + delay) + rng.choice((0.0, 0.003, 0.03))
        finish_reject = rng.choice((None, None, 1, 2))
        operations.append(_finish(duration, reject_at=finish_reject))
        if finish_reject is not None:
            operations.append(_finish(duration))
        fallback = _frame(samples=0, channels=2, generation=99, revision=101,
                          source_rate=32_000, layout="random-fallback")
        cases.append(_case(f"seeded-{index:03d}", delay, operations,
                           target=target, fallback=fallback))

    assert len(cases) < 200
    assert len({case["name"] for case in cases}) == len(cases)
    return cases


def measurement_cases() -> list[dict]:
    """Return the six separately named memory/throughput workloads."""
    stereo = _frame()
    surround = _frame(channels=8, source_rate=96_000)
    return [
        _case("zero-stereo", 0.0, [_consume(stereo), _finish(None)]),
        _case("positive-100ms-stereo", 0.1, [_consume(stereo), _finish(None)]),
        _case("positive-10s-stereo", 10.0, [_consume(stereo), _finish(None)]),
        _case("positive-10s-8ch", 10.0, [_consume(surround), _finish(None)],
              fallback=_frame(channels=8, samples=0)),
        _case("negative-tail-10s-8ch", -10.0, [
            _consume(surround), _finish(10.0),
        ], fallback=_frame(channels=8, samples=0)),
        _case("one-sample-fallback", 0.0, [_finish(None)]),
    ]
