#!/usr/bin/env python3
"""Measure obsolete restoration snapshots in the real macOS coordinator.

Build two isolated copies of the current package. The baseline changes only
PlaybackController.swift back to the pinned revision; both use the same current
tests and probe. No production source is rewritten or instrumented.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CONTROLLER = Path("Sources/IlliquidPlayer/Player/PlaybackController.swift")
TESTS = Path("Tests/IlliquidPlayerTests/PlaybackCoordinatorTests.swift")
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
PROBE_FILTER = "PlaybackCoordinatorTests/restoreSessionMemoryProbe"
NEGATIVE_FILTER = "PlaybackCoordinatorTests/restorationSnapshotRetiresAfterDirectCommitAndReplacement"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def execute(command: list[str | Path], output: Path, label: str,
            *, env: dict[str, str] | None = None, timeout: int = 1200,
            expect_success: bool = True) -> subprocess.CompletedProcess[str]:
    arguments = [str(part) for part in command]
    print(label, flush=True)
    started = datetime.now(timezone.utc).isoformat()
    result = subprocess.run(arguments, capture_output=True, text=True,
                            env=env, timeout=timeout, check=False)
    (output / f"{label}.log").write_text(result.stdout + result.stderr)
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({
            "label": label, "started_utc": started,
            "command": arguments, "returncode": result.returncode,
        }) + "\n")
    if expect_success and result.returncode:
        raise RuntimeError(f"{label} failed ({result.returncode})\n"
                           + result.stdout[-12000:] + result.stderr[-12000:])
    return result


def stage(package: Path, controller: bytes) -> dict[str, str]:
    package.mkdir()
    for directory in ("Sources", "Tests", "Validation"):
        shutil.copytree(ROOT / directory, package / directory)
    for filename in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / filename, package / filename)
    (package / CONTROLLER).write_bytes(controller)
    original_tests = (ROOT / TESTS).read_bytes()
    probe = (HERE / "Probe.swift").read_bytes()
    # Same-file extension lets the probe reuse existing private fake-runtime
    # helpers. It does not expose or alter any production API.
    (package / TESTS).write_bytes(original_tests + b"\n" + probe)
    return {
        str(path.relative_to(package)): digest(path.read_bytes())
        for path in sorted(package.rglob("*")) if path.is_file()
    }


def swift_arguments(package: Path, jobs: int) -> list[str | Path]:
    return ["--package-path", package, "--scratch-path", package / ".build",
            "--cache-path", package.parent / "cache",
            "--config-path", package.parent / "config",
            "--security-path", package.parent / "security",
            "--configuration", "release", "--jobs", str(jobs),
            "-Xswiftc", "-enable-testing"]


def summarize(rows: list[dict]) -> list[dict]:
    summaries = []
    for mode, count in sorted({(row["mode"], row["item_count"]) for row in rows}):
        selected = [row for row in rows
                    if row["mode"] == mode and row["item_count"] == count]
        pairs = sorted({row["pair"] for row in selected})
        before, after, changes = [], [], []
        for pair in pairs:
            baseline = next(row for row in selected
                            if row["pair"] == pair and row["variant"] == "baseline")
            candidate = next(row for row in selected
                             if row["pair"] == pair and row["variant"] == "candidate")
            b = baseline["snapshots"]["final"]["live_malloc_bytes"]
            c = candidate["snapshots"]["final"]["live_malloc_bytes"]
            before.append(b)
            after.append(c)
            changes.append(b - c)
        summaries.append({
            "mode": mode, "item_count": count, "pairs": len(pairs),
            "baseline_final_live_malloc_bytes_median": statistics.median(before),
            "candidate_final_live_malloc_bytes_median": statistics.median(after),
            "paired_live_malloc_bytes_reduction_median": statistics.median(changes),
            "paired_live_malloc_bytes_reduction_min": min(changes),
            "paired_live_malloc_bytes_reduction_max": max(changes),
        })
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--counts", type=int, nargs="+", default=[1, 1000, 10000])
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--prepare-only", action="store_true",
                        help="Validate source staging without native builds")
    args = parser.parse_args()
    if not args.prepare_only and platform.system() != "Darwin":
        parser.error("The real coordinator probe requires macOS and the native SDK")
    if args.pairs < 2 or args.pairs % 2 or args.jobs < 1:
        parser.error("--pairs must be positive/even (at least two), --jobs positive")
    if not args.counts or len(set(args.counts)) != len(args.counts) or any(
        count < 1 or count > 100000 for count in args.counts
    ):
        parser.error("--counts must be unique values from 1 through 100000")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    baseline_revision = git("rev-parse", "--verify", "--end-of-options",
                            args.baseline_ref + "^{commit}").decode().strip()
    baseline = git("show", f"{baseline_revision}:{CONTROLLER}")
    candidate = (ROOT / CONTROLLER).read_bytes()
    if baseline == candidate:
        parser.error("Baseline and candidate controllers are identical")
    manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "checkout_head": git("rev-parse", "HEAD").decode().strip(),
        "baseline_controller_revision": baseline_revision,
        "baseline_controller_sha256": digest(baseline),
        "candidate_controller_sha256": digest(candidate),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "probe_sha256": digest((HERE / "Probe.swift").read_bytes()),
        "counts": args.counts, "pairs": args.pairs,
        "measurement": "malloc_zone_statistics(nil).size_in_use, all malloc zones",
        "limitations": [
            "Real native coordinator/package with a fake playback runtime; no media decode",
            "Live malloc storage includes the test process; it is neither RSS nor peak memory",
            "Saved playlist fixtures are synthetic; large counts are scaling stress cases",
            "Both variants stage the current package; only the baseline controller is historical",
            "Active playlist and saved shuffle identities can legitimately share storage",
        ],
    }
    write_json(output / "manifest.json", manifest)
    try:
        with tempfile.TemporaryDirectory(prefix="illiquid-restore-memory-") as temporary:
            workspace = Path(temporary)
            packages = {name: workspace / name for name in ("baseline", "candidate")}
            hashes = {
                "baseline": stage(packages["baseline"], baseline),
                "candidate": stage(packages["candidate"], candidate),
            }
            differing = [path for path in hashes["candidate"]
                         if hashes["baseline"].get(path) != hashes["candidate"][path]]
            if differing != [str(CONTROLLER)]:
                raise RuntimeError(f"Unexpected staged production differences: {differing}")
            write_json(output / "source-hashes.json", hashes)
            manifest["source_difference"] = differing
            if args.prepare_only:
                manifest["status"] = "staging_verified_only"
                write_json(output / "manifest.json", manifest)
                print("Both packages staged; only the measured controller differs.", flush=True)
                return
            manifest["compiler"] = execute([args.swift, "--version"], output,
                                           "compiler-version").stdout.strip()
            for variant, package in packages.items():
                execute([args.swift, "build", "--build-tests", "--force-resolved-versions",
                         *swift_arguments(package, args.jobs)], output, f"{variant}-build")
            def test_command(variant: str, test_filter: str) -> list[str | Path]:
                return [args.swift, "test", "--skip-build", "--no-parallel",
                        *swift_arguments(packages[variant], args.jobs),
                        "--filter", test_filter]
            # Run the complete coordinator suite with the changed source.
            execute(test_command("candidate", "PlaybackCoordinatorTests"), output,
                    "candidate-coordinator-tests", timeout=600)
            negative = execute(test_command("baseline", NEGATIVE_FILTER), output,
                               "baseline-negative-control", expect_success=False, timeout=120)
            negative_text = negative.stdout + negative.stderr
            if (negative.returncode == 0 or "Expectation failed" not in negative_text
                    or "retainedPreparedRestorePlaylistCount" not in negative_text):
                raise RuntimeError("Baseline did not reproduce the expected ownership failure")
            rows = []
            for mode in ("direct", "folder"):
                for count in args.counts:
                    for pair in range(args.pairs):
                        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                        for order_index, variant in enumerate(order):
                            label = f"{mode}-{count}-pair{pair}-{variant}"
                            receipt = output / f"{label}.json"
                            env = dict(os.environ)
                            env.update({
                                "ILLIQUID_RESTORE_PROBE_OUTPUT": str(receipt),
                                "ILLIQUID_RESTORE_PROBE_COUNT": str(count),
                                "ILLIQUID_RESTORE_PROBE_MODE": mode,
                            })
                            execute(test_command(variant, PROBE_FILTER), output,
                                    label, env=env, timeout=180)
                            row = json.loads(receipt.read_text())
                            if row["mode"] != mode or row["item_count"] != count:
                                raise RuntimeError(f"Wrong workload in {label}")
                            snapshots = row["snapshots"]
                            if snapshots["prepared"]["retained_playlist_count"] != count:
                                raise RuntimeError(f"Prepared snapshot was not observed: {label}")
                            expected = count if variant == "baseline" else None
                            for phase in ("committed", "final"):
                                if snapshots[phase]["retained_playlist_count"] != expected:
                                    raise RuntimeError(f"Unexpected {phase} ownership: {label}")
                            if snapshots["final"]["active_playlist_count"] != 1:
                                raise RuntimeError(f"Final playlist was not replaced: {label}")
                            row.update(variant=variant, pair=pair, order_index=order_index,
                                       controller_sha256=manifest[f"{variant}_controller_sha256"])
                            rows.append(row)
                            with (output / "measurements.jsonl").open("a") as stream:
                                stream.write(json.dumps(row) + "\n")
            summary = summarize(rows)
            write_json(output / "summary.json", summary)
            manifest["observations"] = len(rows)
            manifest["status"] = "passed"
            print(json.dumps(summary, indent=2), flush=True)
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        write_json(output / "manifest.json", manifest)


if __name__ == "__main__":
    main()
