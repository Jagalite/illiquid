#!/usr/bin/env python3
"""Replay the independent audit of the retained native experiment.

Uses the standard library, reads the archived binaries as data, and runs no
build or benchmark. Optional --repository checks pinned Git source objects.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import zipfile

ARTIFACT_SHA256 = "1b1ebc11ec33c6f9b57d28d86d811c0e0d4c5e6b7a952364ababfec0ff070583"
ARTIFACT_BYTES = 1221430
HERE = Path(__file__).resolve().parent
DEFAULT_ARTIFACT = (HERE.parent.parent / "Documentation" / "PerformanceEvidence"
                    / "AuxiliaryFontNativeAudit" / "native-run-40101084730.zip")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unpack(artifact: Path, destination: Path) -> int:
    """Validate member paths before extracting the exact, digest-pinned archive."""
    with zipfile.ZipFile(artifact) as archive:
        for member in archive.infolist():
            target = (destination / member.filename).resolve()
            if not target.is_relative_to(destination.resolve()):
                raise ValueError(f"Archive path escapes the temporary directory: {member.filename}")
            if stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError(f"Unexpected archive symlink: {member.filename}")
        archive.extractall(destination)
        return len(archive.infolist())


def run_audit(script: str, artifact_root: Path, output: Path,
              repository: Path | None, archive: Path | None = None) -> dict:
    command = [sys.executable, str(HERE / script), "--evidence", str(artifact_root),
               "--output", str(output)]
    if repository is not None:
        command.extend(["--repository", str(repository)])
    if archive is not None:
        command.extend(["--archive", str(archive)])
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{script} failed:\n{result.stdout}\n{result.stderr}")
    report = json.loads(output.read_text())
    if report.get("status") != "passed":
        raise ValueError(f"{script} did not report a passing audit")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, default=DEFAULT_ARTIFACT)
    parser.add_argument("--repository", type=Path,
                        help="Optional checkout containing both pinned Git commits")
    parser.add_argument("--output", type=Path, required=True,
                        help="New or empty directory for the three audit receipts")
    args = parser.parse_args()
    artifact = args.artifact.resolve()
    output = args.output.resolve()
    repository = args.repository.resolve() if args.repository else None
    if artifact.stat().st_size != ARTIFACT_BYTES or digest(artifact) != ARTIFACT_SHA256:
        raise ValueError("Artifact size or SHA-256 differs from the recorded GitHub artifact")
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"Output directory must be new or empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="illiquid-font-native-audit-") as temporary:
        members = unpack(artifact, Path(temporary))
        metrics = run_audit("metrics_audit.py", Path(temporary),
                            output / "audit-metrics.json", repository)
        traces = run_audit("verify_traces.py", Path(temporary),
                           output / "audit-traces.json", repository, artifact)
    combined = {
        "status": "passed",
        "meaning": "Independent replay of recorded component evidence; not a new native run or application-test pass.",
        "run_id": 40101084730,
        "run_url": "https://github.com/Jagalite/illiquid/actions/runs/40101084730",
        "candidate_revision": "4e64b3d2b6098536c61710dca2354442c718961c",
        "baseline_revision": "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635",
        "artifact_sha256": ARTIFACT_SHA256,
        "artifact_bytes": ARTIFACT_BYTES,
        "archive_members": members,
        "git_source_verification_requested": repository is not None,
        "script_sha256": {name: digest(HERE / name) for name in
                          ("audit.py", "metrics_audit.py", "verify_traces.py")},
        "report_sha256": {name: digest(output / name) for name in
                          ("audit-metrics.json", "audit-traces.json")},
        "metrics_counts": metrics["counts"],
        "trace_audit_status": traces["status"],
        "application_tests": "Compilation failed in the measured run; selected tests did not execute.",
        "pr_101_qualification": "Not established: this artifact measures a different prototype revision.",
    }
    (output / "audit.json").write_text(json.dumps(combined, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"status": "passed", "output": str(output),
                      "measurement_processes": metrics["counts"]["measurement_processes"],
                      "metric_records": metrics["counts"]["paired_metric_records_recomputed_exactly"],
                      "application_tests": "did not execute"}, sort_keys=True))


if __name__ == "__main__":
    main()
