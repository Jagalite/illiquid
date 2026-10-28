#!/usr/bin/env python3
"""Deterministic full-conversion inputs for timestamp parser qualification.

The first 14,398 cases reproduce the 2026-10-28 exploratory corpus exactly
(id, format, source), including deliberate duplicate sources with distinct IDs.
The recipe, rather than a generated data file, is retained here. Its canonical
JSON fingerprint pins that initial coverage. Additional cases exercise every
millisecond rounding input, Unicode insertions, width changes, and integration
with cue filtering. No expected result is obtained by running either converter.

Expected dialogue strings are the complete suffix after defaultASSHeader,
including their initial newline. The Swift driver compares complete UTF-8 bytes
against the header plus this suffix. Unannotated cases are differential only.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import pathlib
import sys

ORIGINAL_CASE_COUNT = 14_398
ORIGINAL_CASE_SHA256 = "26a771930c05fafb69709d41f990d58e7e95809bfd892abbdb25a4f9e73f271f"
MAXIMUM_ASS_HOURS = 2_147_483_647
MAXIMUM_ACCEPTED_MILLISECONDS = (
    ((MAXIMUM_ASS_HOURS * 60 + 59) * 60 + 59) * 1_000 + 994
)


def _ass_time(milliseconds: int) -> str:
    """Arithmetic oracle: round nonnegative milliseconds to centiseconds."""
    centiseconds = (milliseconds + 5) // 10
    return (
        f"{centiseconds // 360_000}:"
        f"{(centiseconds // 6_000) % 60:02d}:"
        f"{(centiseconds // 100) % 60:02d}.{centiseconds % 100:02d}"
    )


def _dialogue(start: int, end: int, payload: str = "Caption") -> str:
    return (
        f"\nDialogue: 0,{_ass_time(start)},{_ass_time(end)},"
        f"Default,,0,0,0,,{payload}"
    )


def _no_cues(format_name: str) -> str:
    return "noValidCues.srt" if format_name == "srt" else "noValidCues.webVTT"


def _document(format_name: str, start: str, end: str, payload: str = "Caption") -> str:
    prefix = "1\n" if format_name == "srt" else "WEBVTT\n\n"
    return f"{prefix}{start} --> {end}\n{payload}"


def _original_cases() -> list[dict[str, str]]:
    cases: list[dict[str, str]] = []
    substitutions = [chr(value) for value in range(128)] + [
        "\u0301", "\u034f", "\u200d", "\u00a0", "\u2000",
        "\ufeff", "\u0661", "\uff11", "\u2028", "\u2029",
    ]
    wrappers_before = ["", " ", "\t", "\u00a0", "\u2000"]
    wrappers_after = [
        "", " ", "\t", "\u00a0", "\u2000", " align:start", "\talign:start",
    ]
    legacy_and_bounds = [
        "1:2:3", "1:2:3,1", "1:2:3.1",
        "01:02:03,005999", "01:02:03.005999",
        "2147483647:59:59.994", "2147483647:59:59.995",
        "2147483648:00:00.000", "0:01.000", "000:01.000",
    ]
    for format_name in ["srt", "vtt"]:
        separator = "," if format_name == "srt" else "."
        grid = list(itertools.product(
            [0, 1, 23, 59, 99],
            [0, 1, 58, 59, 60, 99],
            [0, 1, 58, 59, 60, 99],
            [0, 1, 4, 5, 994, 995, 999],
        ))
        tokens = [
            f"{hours:02d}:{minutes:02d}:{seconds:02d}{separator}{fraction:03d}"
            for hours, minutes, seconds, fraction in grid
        ]
        seeds = ["12:34:56,789"] if format_name == "srt" else [
            "12:34:56.789", "34:56.789",
        ]
        for seed in seeds:
            tokens.extend(
                seed[:offset] + replacement + seed[offset + 1:]
                for offset in range(len(seed))
                for replacement in substitutions
            )
            tokens.extend(
                before + seed + after
                for before in wrappers_before
                for after in wrappers_after
            )
        tokens.extend(legacy_and_bounds)

        maximum = f"2147483647:59:59{separator}994"
        zero = f"00:00:00{separator}000"
        for token_index, token in enumerate(tokens):
            for position in ["start", "end"]:
                start, end = (token, maximum) if position == "start" else (zero, token)
                case = {
                    "id": f"{format_name}-{token_index}-{position}",
                    "format": format_name,
                    "source": _document(format_name, start, end),
                }
                if token_index < len(grid):
                    hours, minutes, seconds, fraction = grid[token_index]
                    milliseconds = ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fraction
                    if minutes > 59 or seconds > 59 or (position == "end" and milliseconds == 0):
                        case["expected_error"] = _no_cues(format_name)
                    else:
                        expected_start, expected_end = (
                            (milliseconds, MAXIMUM_ACCEPTED_MILLISECONDS)
                            if position == "start" else (0, milliseconds)
                        )
                        case["expected_dialogue"] = _dialogue(expected_start, expected_end)
                cases.append(case)

    originals = [
        {key: case[key] for key in ["id", "format", "source"]}
        for case in cases
    ]
    fingerprint = hashlib.sha256(json.dumps(
        originals, ensure_ascii=True, sort_keys=True, separators=(",", ":"),
    ).encode("utf-8")).hexdigest()
    if len(cases) != ORIGINAL_CASE_COUNT or fingerprint != ORIGINAL_CASE_SHA256:
        raise ValueError("The pinned original differential corpus changed")
    return cases


def _rounding_cases() -> list[dict[str, str]]:
    """All 1,000 fractions at ordinary and hour-carry boundaries."""
    cases: list[dict[str, str]] = []
    for form in ["srt", "vtt-full", "vtt-short"]:
        format_name = "srt" if form == "srt" else "vtt"
        separator = "," if format_name == "srt" else "."
        for base_seconds in [0, 3_599]:
            hours, remainder = divmod(base_seconds, 3_600)
            minutes, seconds = divmod(remainder, 60)
            end_seconds = base_seconds + 2
            end_hours, end_remainder = divmod(end_seconds, 3_600)
            end_minutes, end_second = divmod(end_remainder, 60)
            end = f"{end_hours:02d}:{end_minutes:02d}:{end_second:02d}{separator}000"
            for fraction in range(1_000):
                start = f"{minutes:02d}:{seconds:02d}{separator}{fraction:03d}"
                if form != "vtt-short":
                    start = f"{hours:02d}:" + start
                cases.append({
                    "id": f"rounding-{form}-{base_seconds}-{fraction:03d}",
                    "format": format_name,
                    "source": _document(format_name, start, end),
                    "expected_dialogue": _dialogue(
                        base_seconds * 1_000 + fraction, end_seconds * 1_000,
                    ),
                })
    return cases


def _insertion_cases() -> list[dict[str, str]]:
    cases: list[dict[str, str]] = []
    inserted = [
        "\u0301", "\u034f", "\u200d", "\u200b", "\ufe0f", "\u00a0",
        "\t", " ", "\u0661", "\uff11", ":", ".", ",", "0", "9",
    ]
    for form, seed in [
        ("srt", "12:34:56,789"),
        ("vtt-full", "12:34:56.789"),
        ("vtt-short", "34:56.789"),
    ]:
        format_name = "srt" if form == "srt" else "vtt"
        separator = "," if format_name == "srt" else "."
        tokens = [
            seed[:offset] + value + seed[offset:]
            for offset in range(len(seed) + 1) for value in inserted
        ]
        tokens.extend(seed[:offset] + seed[offset + 1:] for offset in range(len(seed)))
        for token_index, token in enumerate(tokens):
            for position in ["start", "end"]:
                start, end = (
                    (token, f"2147483647:59:59{separator}994")
                    if position == "start" else (f"00:00:00{separator}000", token)
                )
                cases.append({
                    "id": f"insert-delete-{form}-{token_index}-{position}",
                    "format": format_name,
                    "source": _document(format_name, start, end),
                })
    return cases


def _logical_cases() -> list[dict[str, str]]:
    """Small explicit contracts independent of the general parser algorithm."""
    cases: list[dict[str, str]] = []

    def success(name: str, format_name: str, start: str, end: str,
                start_ms: int, end_ms: int, payload: str = "Caption") -> None:
        cases.append({
            "id": "logical-" + name, "format": format_name,
            "source": _document(format_name, start, end, payload),
            "expected_dialogue": _dialogue(start_ms, end_ms, payload),
        })

    def failure(name: str, format_name: str, start: str, end: str) -> None:
        cases.append({
            "id": "logical-" + name, "format": format_name,
            "source": _document(format_name, start, end),
            "expected_error": _no_cues(format_name),
        })

    success("srt-variable-width", "srt", "0:0:0", "0:0:1", 0, 1_000)
    success("srt-one-fraction-digit-is-millisecond", "srt", "0:0:0,1", "0:0:0,2", 1, 2)
    success("srt-two-fraction-digits", "srt", "0:0:0.12", "0:0:0.13", 12, 13)
    success("srt-long-fraction-truncation", "srt", "0:0:0,99999", "0:0:1", 999, 1_000)
    success("srt-mixed-decimal-separators", "srt", "00:00:00.005", "00:00:00,015", 5, 15)
    success("srt-leading-zero-widths", "srt", "000000:000:000,0005", "000000:000:001,000", 0, 1_000)
    success("vtt-two-field", "vtt", "00:00.001", "00:00.002", 1, 2)
    success("vtt-three-digit-hours", "vtt", "000:00:00.001", "000:00:00.002", 1, 2)
    success("vtt-end-settings", "vtt", "00:00:00.000", "00:00:01.000 align:start", 0, 1_000)
    success("vtt-tab-end-settings", "vtt", "00:00:00.000", "00:00:01.000\tline:20%", 0, 1_000)
    success("unicode-caption", "srt", "00:00:00,000", "00:00:01,000", 0, 1_000, "Café 日本語 👩‍💻")
    success("ascii-timestamp-whitespace", "srt", " \t00:00:00,005\t ", " \t00:00:01,005\t ", 5, 1_005)
    for format_name in ["srt", "vtt"]:
        separator = "," if format_name == "srt" else "."
        zero = f"00:00:00{separator}000"
        one = f"00:00:01{separator}000"
        success(
            format_name + "-maximum-accepted", format_name, zero,
            f"2147483647:59:59{separator}994", 0, MAXIMUM_ACCEPTED_MILLISECONDS,
        )
        failure(format_name + "-maximum-rounding-overflow", format_name, zero,
                f"2147483647:59:59{separator}995")
        failure(format_name + "-hours-overflow", format_name, zero,
                f"2147483648:00:00{separator}000")
        failure(format_name + "-equal-endpoints", format_name, one, one)
        failure(format_name + "-reversed-endpoints", format_name, one, zero)
        for name, token in [
            ("signed-hours", f"+00:00:00{separator}001"),
            ("negative-hours", f"-00:00:00{separator}001"),
            ("nan-seconds", f"00:00:nan{separator}001"),
            ("infinite-hours", f"inf:00:00{separator}001"),
            ("minute-limit", f"00:60:00{separator}001"),
            ("second-limit", f"00:00:60{separator}001"),
            ("arabic-digit", f"00:00:0١{separator}001"),
        ]:
            failure(format_name + "-" + name, format_name, token, one)

    for name, start, end in [
        ("srt-start-settings", "00:00:00,000 align:start", "00:00:01,000"),
        ("srt-end-settings", "00:00:00,000", "00:00:01,000 align:start"),
    ]:
        failure(name, "srt", start, end)
    for name, start, end in [
        ("vtt-start-settings", "00:00:00.000 align:start", "00:00:01.000"),
        ("vtt-one-digit-hours", "0:00:00.000", "00:00:01.000"),
        ("vtt-one-digit-minutes", "0:00.000", "00:00:01.000"),
        ("vtt-three-digit-minutes", "000:00.000", "00:00:01.000"),
        ("vtt-one-digit-seconds", "00:0.000", "00:00:01.000"),
        ("vtt-comma-fraction", "00:00:00,000", "00:00:01.000"),
        ("vtt-short-fraction", "00:00:00.00", "00:00:01.000"),
        ("vtt-long-fraction", "00:00:00.0000", "00:00:01.000"),
        ("vtt-missing-fraction", "00:00:00", "00:00:01.000"),
    ]:
        failure(name, "vtt", start, end)

    for signature in ["WEBVTT", "WEBVTT caption metadata", "WEBVTT\tmetadata", "\ufeffWEBVTT"]:
        cases.append({
            "id": f"logical-vtt-signature-{len(cases)}", "format": "vtt",
            "source": signature + "\n\n00:00.000 --> 00:01.000\nCaption",
            "expected_dialogue": _dialogue(0, 1_000),
        })
    for signature in ["", "webvtt", "WEBVTTx", " WEBVTT", "\nWEBVTT"]:
        cases.append({
            "id": f"logical-vtt-missing-signature-{len(cases)}", "format": "vtt",
            "source": signature + "\n\n00:00.000 --> 00:01.000\nCaption",
            "expected_error": "missingWebVTTSignature",
        })
    cases.extend([
        {
            "id": "logical-vtt-no-cues", "format": "vtt", "source": "WEBVTT",
            "expected_error": "noValidCues.webVTT",
        },
        {
            "id": "logical-vtt-comment-skipped", "format": "vtt",
            "source": "WEBVTT\n\nNOTE ignored\n00:00.000 --> 00:01.000\nIgnored\n\n"
                      "cue-id\n00:01.000 --> 00:02.000\nCaption",
            "expected_dialogue": _dialogue(1_000, 2_000),
        },
        {
            "id": "logical-srt-invalid-between-valid", "format": "srt",
            "source": "1\n00:00:00,000 --> 00:00:01,000\nFirst\n\n"
                      "2\n00:99:00,000 --> 00:99:01,000\nIgnored\n\n"
                      "3\n00:00:02,000 --> 00:00:03,000\nLast",
            "expected_dialogue": _dialogue(0, 1_000, "First") + _dialogue(2_000, 3_000, "Last"),
        },
        {
            "id": "logical-vtt-crlf", "format": "vtt",
            "source": "WEBVTT\r\n\r\n00:00.000 --> 00:01.000\r\nCaption",
            "expected_dialogue": _dialogue(0, 1_000),
        },
        {
            "id": "logical-srt-cr", "format": "srt",
            "source": "1\r00:00:00,000 --> 00:00:01,000\rCaption",
            "expected_dialogue": _dialogue(0, 1_000),
        },
    ])
    return cases


def generate_cases() -> list[dict[str, str]]:
    cases = _original_cases() + _rounding_cases() + _insertion_cases() + _logical_cases()
    if len(cases) >= 30_000 or len({case["id"] for case in cases}) != len(cases):
        raise ValueError("Differential corpus is oversized or has duplicate IDs")
    return cases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    text = json.dumps(generate_cases(), ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n"
    if args.output is None:
        sys.stdout.write(text)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
