#!/usr/bin/env python3
"""Compare two isolated Superplayr native output artifact manifests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def keyed(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {record["id"]: record for record in records}


def hamming(left: str, right: str) -> int:
    return (int(left, 16) ^ int(right, 16)).bit_count()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    baseline = json.loads(args.baseline.read_text())
    candidate = json.loads(args.candidate.read_text())
    failures: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []

    for field in ("schema_version", "harness_revision", "machine", "operating_system", "fixtures"):
        if baseline.get(field) != candidate.get(field):
            failures.append(
                {
                    "category": "environment",
                    "field": field,
                    "baseline": baseline.get(field),
                    "candidate": candidate.get(field),
                }
            )

    baseline_video = keyed(baseline["video"])
    candidate_video = keyed(candidate["video"])
    if baseline_video.keys() != candidate_video.keys():
        failures.append(
            {
                "category": "video",
                "field": "artifact_ids",
                "baseline": sorted(baseline_video),
                "candidate": sorted(candidate_video),
            }
        )
    for artifact_id in sorted(baseline_video.keys() & candidate_video.keys()):
        before = baseline_video[artifact_id]
        after = candidate_video[artifact_id]
        for field in (
            "actual_pts_seconds",
            "width",
            "height",
            "pixel_format",
            "ffmpeg_pixel_format",
            "hardware_decoded",
            "color_primaries",
            "transfer_characteristic",
            "matrix_coefficients",
            "full_range",
            "mastering_display_metadata",
            "content_light_metadata",
        ):
            if before[field] != after[field]:
                failures.append(
                    {
                        "category": "video",
                        "id": artifact_id,
                        "field": field,
                        "baseline": before[field],
                        "candidate": after[field],
                    }
                )
        if before["luma_sha256"] != after["luma_sha256"]:
            distance = hamming(before["perceptual_hash"], after["perceptual_hash"])
            finding = {
                "category": "video",
                "id": artifact_id,
                "field": "luma_sha256",
                "baseline": before["luma_sha256"],
                "candidate": after["luma_sha256"],
                "perceptual_hamming_distance": distance,
            }
            (warnings if distance <= 2 else failures).append(finding)

    for category, digest_field in (("subtitles", "rgba_sha256"), ("audio", "pcm_sha256")):
        before_records = keyed(baseline[category])
        after_records = keyed(candidate[category])
        if before_records.keys() != after_records.keys():
            failures.append(
                {
                    "category": category,
                    "field": "artifact_ids",
                    "baseline": sorted(before_records),
                    "candidate": sorted(after_records),
                }
            )
        for artifact_id in sorted(before_records.keys() & after_records.keys()):
            before = before_records[artifact_id]
            after = after_records[artifact_id]
            if before[digest_field] != after[digest_field]:
                failures.append(
                    {
                        "category": category,
                        "id": artifact_id,
                        "field": digest_field,
                        "baseline": before[digest_field],
                        "candidate": after[digest_field],
                    }
                )

    report = {
        "schema_version": 1,
        "baseline_source_revision": baseline.get("source_revision"),
        "candidate_source_revision": candidate.get("source_revision"),
        "harness_revision": baseline.get("harness_revision"),
        "passed": not failures,
        "failure_count": len(failures),
        "warning_count": len(warnings),
        "failures": failures,
        "warnings": warnings,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
