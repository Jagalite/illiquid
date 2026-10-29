#!/usr/bin/env python3
"""Native PiP working-storage lifetime research with a matched parent-behavior control.

Both variants compile the current production app/test graph. The control removes
one retirement call; its stop() body must exactly match the pinned parent's.
Instrumentation and all other source stay identical. This is not a claim to run
the parent's complete source tree or to measure whole-player memory savings.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
PARENT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
COMPOSITOR = Path("Sources/IlliquidNativePlayback/Presentation/PiPSubtitleCompositor.swift")
HARNESS = Path("Tests/IlliquidNativePlaybackTests/PiPVideoWorkingStorageMeasurements.swift")
INPUTS = [COMPOSITOR, HARNESS, Path("Package.swift"), Path("Package.resolved"),
          Path("BuildInputs/native-sdk.json"), Path("DependencySources/source-manifest.json")]
VARIANTS = ("control", "candidate")
MODES = ("sdr-1080p", "pq-4k")
MARKER = "PIP_VIDEO_WORKING_STORAGE_MEASUREMENT "


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def text_digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def swift_block(source: str, anchor: str) -> str:
    # The checked stop body contains no brace-bearing string or comment.
    if source.count(anchor) != 1:
        raise RuntimeError(f"Expected one source boundary: {anchor!r}")
    start = source.index(anchor)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise RuntimeError(f"Unclosed source boundary: {anchor!r}")


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.commands: list[dict] = []

    def run(self, argv: list, *, label: str, env: dict | None = None,
            timeout: int = 300) -> str:
        command = [str(value) for value in argv]
        log = f"{len(self.commands):03}-{label}.log"
        started = time.monotonic()
        try:
            process = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     timeout=timeout, check=False)
            raw, code = process.stdout, process.returncode
        except subprocess.TimeoutExpired as error:
            raw = error.stdout or ""
            if isinstance(raw, bytes):
                raw = raw.decode(errors="replace")
            raw += f"\nCommand timed out after {timeout} seconds.\n"
            code = None
        except OSError as error:
            raw, code = str(error) + "\n", None
        (self.output / log).write_text(raw)
        selected_env = {} if env is None else {
            key: env[key] for key in ("ILLIQUID_PIP_STORAGE_MEASURE",
                                     "ILLIQUID_PIP_STORAGE_MODE", "ILLIQUID_PIP_STORAGE_PASS")
            if key in env
        }
        self.commands.append(dict(argv=command, environment=selected_env, log=log, exit=code,
                                  elapsed_seconds=time.monotonic() - started,
                                  timeout_seconds=timeout))
        save(self.output / "commands.json", self.commands)
        if code != 0:
            raise RuntimeError(f"Command failed: {command!r}\n"
                               f"Full log: {self.output / log}\n{raw[-16000:]}")
        return raw


def validate_sample(sample: dict) -> None:
    for key in ("physical_footprint_bytes", "metal_current_allocated_bytes",
                "hdr_texture_allocated_bytes", "observed_output_buffers", "monotonic_ns"):
        if type(sample.get(key)) is not int or sample[key] < 0:
            raise RuntimeError(f"Invalid sample counter {key}: {sample}")
    if sample["physical_footprint_bytes"] == 0:
        raise RuntimeError("The native physical-footprint measurement was not populated.")
    for key in ("has_output_pool", "has_output_pool_observer", "has_hdr_texture",
                "has_prepared_subtitle_frame"):
        if type(sample.get(key)) is not bool:
            raise RuntimeError(f"Invalid sample state {key}: {sample}")
    if sample.get("latest_frame_seconds") != 1:
        raise RuntimeError("The cached paused frame changed or was lost.")


def validate_record(row: dict, variant: str, mode: str, pass_name: str) -> None:
    hdr = mode == "pq-4k"
    size = (3840, 2160) if hdr else (1920, 1080)
    if (row.get("schema_version"), row.get("mode"), row.get("pass")) != (1, mode, pass_name):
        raise RuntimeError(f"Measurement identity mismatch: {row}")
    if (row.get("width"), row.get("height"), row.get("is_hdr")) != (*size, hdr):
        raise RuntimeError("Measured dimensions or color mode differ from the requested workload.")
    if row.get("temporarily_held_outputs") != 4 or not row.get("metal_device"):
        raise RuntimeError("Expected four real retained outputs and a native Metal device.")
    for key in ("first_start_sample_ns", "reentry_first_sample_ns"):
        if type(row.get(key)) is not int or row[key] <= 0:
            raise RuntimeError(f"Missing first-sample timing: {key}")
    output = row.get("output", {})
    if (output.get("width"), output.get("height")) != size:
        raise RuntimeError("Composed output dimensions changed.")
    if not re.fullmatch(r"[0-9a-f]{64}", output.get("sha256", "")):
        raise RuntimeError("Missing complete output-pixel checksum.")
    if output.get("caption_component", -1) <= output.get("background_component", -1):
        raise RuntimeError("The expected bitmap subtitle was not rendered.")
    if output != row.get("reentry_output"):
        raise RuntimeError("Paused reentry changed the composed pixels or format.")
    if row.get("reentry_subtitle_texture_uploads") != 0:
        raise RuntimeError("Paused reentry unexpectedly discarded retained subtitle uploads.")
    if row.get("reentry_subtitle_resource_reuses", 0) < 1:
        raise RuntimeError("The preserved subtitle upload was not reused.")

    before, active, idle = row["before"], row["active"], row["idle"]
    if [sample["label"] for sample in idle] != ["after-stop", "idle-100ms", "idle-300ms"]:
        raise RuntimeError("Idle measurement phases are missing or out of order.")
    samples = [before, active, *idle, row["reentered"], row["second_stop"]]
    for sample in samples:
        validate_sample(sample)
    if before["has_output_pool"] or before["has_output_pool_observer"] or before["has_hdr_texture"]:
        raise RuntimeError("The measured compositor did not start with empty video storage.")
    if before["observed_output_buffers"] != 0 or before["hdr_texture_allocated_bytes"] != 0:
        raise RuntimeError("The initial video-storage counters were not empty.")
    for sample in [active, row["reentered"]]:
        if not sample["has_output_pool"] or not sample["has_output_pool_observer"]:
            raise RuntimeError("Actual native composition did not populate its pool.")
        if sample["has_hdr_texture"] != hdr or not sample["has_prepared_subtitle_frame"]:
            raise RuntimeError("Required HDR/caption storage was not populated.")
    if active["observed_output_buffers"] < 4:
        raise RuntimeError("The real output pool was not exercised with four distinct live outputs.")
    if hdr and active["hdr_texture_allocated_bytes"] < size[0] * size[1] * 8:
        raise RuntimeError("The real HDR intermediate was not allocated.")
    if not hdr and active["hdr_texture_allocated_bytes"] != 0:
        raise RuntimeError("SDR unexpectedly allocated an HDR intermediate.")

    for sample in [*idle, row["second_stop"]]:
        if not sample["has_prepared_subtitle_frame"]:
            raise RuntimeError("Stopping discarded the prepared caption.")
        if variant == "candidate":
            if any(sample[key] for key in ("has_output_pool", "has_output_pool_observer", "has_hdr_texture")):
                raise RuntimeError("Candidate retained stopped video working storage.")
            if sample["hdr_texture_allocated_bytes"] or sample["observed_output_buffers"]:
                raise RuntimeError("Candidate retained stopped allocation bookkeeping.")
        else:
            if not sample["has_output_pool"] or not sample["has_output_pool_observer"]:
                raise RuntimeError("Matched control no longer reproduces parent pool retention.")
            if sample["has_hdr_texture"] != hdr:
                raise RuntimeError("Matched control no longer reproduces parent HDR retention.")
            if sample["hdr_texture_allocated_bytes"] != active["hdr_texture_allocated_bytes"]:
                raise RuntimeError("Matched control's HDR allocation changed at stop.")
    if any(idle[index]["since_stop_ns"] >= idle[index + 1]["since_stop_ns"]
           for index in range(len(idle) - 1)):
        raise RuntimeError("Idle observation timestamps are not increasing.")


def measurements(row: dict) -> dict:
    before, active, idle = row["before"], row["active"], row["idle"][-1]
    return {
        "active_physical_footprint_bytes": active["physical_footprint_bytes"],
        "idle_physical_footprint_bytes": idle["physical_footprint_bytes"],
        "physical_footprint_drop_bytes": active["physical_footprint_bytes"] - idle["physical_footprint_bytes"],
        "idle_physical_footprint_above_before_bytes": idle["physical_footprint_bytes"] - before["physical_footprint_bytes"],
        "active_metal_current_allocated_bytes": active["metal_current_allocated_bytes"],
        "idle_metal_current_allocated_bytes": idle["metal_current_allocated_bytes"],
        "metal_current_allocated_drop_bytes": active["metal_current_allocated_bytes"] - idle["metal_current_allocated_bytes"],
        "active_hdr_texture_allocated_bytes": active["hdr_texture_allocated_bytes"],
        "idle_hdr_texture_allocated_bytes": idle["hdr_texture_allocated_bytes"],
        "active_observed_output_buffers": active["observed_output_buffers"],
        "idle_observed_output_buffers": idle["observed_output_buffers"],
        "first_start_sample_ns": row["first_start_sample_ns"],
        "reentry_first_sample_ns": row["reentry_first_sample_ns"],
    }


def summarize(rows: list[dict], pairs: int) -> dict:
    result = {"scope": "Native compositor component with one synthetic cached frame and bitmap subtitle; "
                       "four extra completed outputs temporarily populate its real pool. Physical footprint "
                       "and device allocation are process counters, not whole-player memory savings.",
              "comparison": "Matched parent-behavior control versus candidate, identical instrumentation",
              "pairs": pairs, "workloads": []}
    for mode in MODES:
        records = {variant: sorted((row for row in rows if row["mode"] == mode and row["variant"] == variant),
                                   key=lambda row: row["pair"]) for variant in VARIANTS}
        if any(len(values) != pairs for values in records.values()):
            raise RuntimeError("Incomplete paired dataset.")
        metrics = {variant: [measurements(row) for row in values]
                   for variant, values in records.items()}
        entry = {"mode": mode, "metrics": {}}
        for name in metrics["control"][0]:
            values = {variant: [row[name] for row in data] for variant, data in metrics.items()}
            stats = {variant: {"median": statistics.median(data), "min": min(data), "max": max(data)}
                     for variant, data in values.items()}
            stats["paired_candidate_minus_control_median"] = statistics.median(
                after - before for before, after in zip(values["control"], values["candidate"]))
            if name.endswith("_ns"):
                stats["paired_time_reduction_percent_median"] = statistics.median(
                    (1 - after / before) * 100
                    for before, after in zip(values["control"], values["candidate"]))
            entry["metrics"][name] = stats
        result["workloads"].append(entry)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New evidence/build directory")
    parser.add_argument("--pairs", type=int, default=6, help="Even number of alternating fresh-process pairs")
    parser.add_argument("--regression-filter",
                        help="Optional candidate Swift Testing filter, run once after the measured builds")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This qualification requires actual macOS CoreVideo/Metal; there is no simulated fallback.")
    if not 2 <= args.pairs <= 12 or args.pairs % 2:
        parser.error("--pairs must be an even integer from 2 through 12 (default 6).")
    if args.output.exists():
        parser.error("--output must be a new directory; evidence is never overwritten.")
    output = args.output.resolve()
    output.mkdir(parents=True)
    (output / "build").mkdir()
    shutil.copy2(Path(__file__), output / "runner.py")
    runner = Runner(output)
    completion = {"succeeded": False, "pinned_parent": PARENT}
    save(output / "completion.json", completion)
    try:
        revision = runner.run(["git", "rev-parse", "HEAD"], label="revision", timeout=30).strip()
        status = runner.run(["git", "status", "--porcelain", "--untracked-files=no"],
                            label="worktree-status", timeout=30).strip()
        if status:
            raise RuntimeError("Commit tracked candidate changes before measurement; the control is based on HEAD.")
        parent = runner.run(["git", "show", f"{PARENT}:{COMPOSITOR}"], label="parent-source", timeout=30)
        candidate = (ROOT / COMPOSITOR).read_text()
        call = "            retireVideoWorkingStorageIfInactive()\n"
        if candidate.count(call) != 1:
            raise RuntimeError("Expected exactly one stop-time retirement call.")
        if candidate.count("private func retireVideoWorkingStorageIfInactive()") != 1:
            raise RuntimeError("Expected the guarded retirement helper.")
        control = candidate.replace(call, "", 1)
        parent_stop = swift_block(parent, "    func stop() {")
        control_stop = swift_block(control, "    func stop() {")
        if control_stop != parent_stop:
            raise RuntimeError("Removing the one retirement call did not restore the exact parent stop() body.")

        control_root = output / "build" / "control-tree"
        runner.run(["git", "worktree", "add", "--detach", control_root, revision],
                   label="control-worktree", timeout=180)
        (control_root / COMPOSITOR).write_text(control)
        roots = {"control": control_root, "candidate": ROOT}
        receipts = {}
        for variant, root in roots.items():
            files = {str(path): digest(root / path) for path in INPUTS}
            production = {str(path.relative_to(root)): digest(path)
                          for path in sorted((root / "Sources").rglob("*")) if path.is_file()}
            receipts[variant] = {"files": files, "production": production}
            for path in INPUTS:
                destination = output / "sources" / variant / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(root / path, destination)
        differences = sorted(path for path in set(receipts["control"]["production"])
                             | set(receipts["candidate"]["production"])
                             if receipts["control"]["production"].get(path)
                             != receipts["candidate"]["production"].get(path))
        if differences != [str(COMPOSITOR)]:
            raise RuntimeError(f"Unexpected production differences in matched control: {differences}")
        for path in INPUTS[1:]:
            if receipts["control"]["files"][str(path)] != receipts["candidate"]["files"][str(path)]:
                raise RuntimeError(f"Shared measurement input differs: {path}")
        save(output / "sources.json", {"variants": receipts, "production_differences": differences,
                                      "comparison": "One removed retirement call; common candidate instrumentation",
                                      "pinned_parent": PARENT, "parent_source_sha256": text_digest(parent),
                                      "parent_stop_sha256": text_digest(parent_stop),
                                      "control_stop_sha256": text_digest(control_stop)})
        (output / "parent-stop.swift").write_text(parent_stop + "\n")
        environment = {
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "candidate_commit": revision, "pinned_parent": PARENT,
            "swift": runner.run(["swift", "--version"], label="swift", timeout=30).strip(),
            "xcode": runner.run(["xcodebuild", "-version"], label="xcode", timeout=30).strip(),
            "macos": runner.run(["sw_vers"], label="macos", timeout=30).strip(),
            "hardware": runner.run(["sysctl", "hw.model", "hw.memsize", "hw.ncpu"],
                                   label="hardware", timeout=30).strip(),
            "sdk": runner.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                              label="sdk", timeout=30).strip(),
            "machine": platform.machine(), "pairs": args.pairs,
            "build": "Full production SwiftPM application/test graph; release; two jobs; serial builds/tests",
            "sampling": "One fresh native test process per variant/mode/pair; AB/BA order; "
                        "real GPU completion, output release, stop queue barrier, 0/100/300ms idle observations",
            "runner_sha256": digest(Path(__file__)),
        }
        save(output / "environment.json", environment)
        if not Path("/Volumes/seed1/Projects/kyoto/kyoto.py").exists():
            print("Kyoto is unavailable on this host; running the two native builds directly and serially.", flush=True)

        base_env = os.environ.copy()
        base_env.update(TERM="dumb", NO_COLOR="1", ILLIQUID_PIP_STORAGE_MEASURE="1")

        def swift_command(variant: str, suite: str, *, skip_build: bool = True) -> list:
            command = ["swift", "test", "--package-path", roots[variant],
                       "--scratch-path", output / "build" / f"{variant}-build",
                       "--force-resolved-versions", "-c", "release", "--jobs", "2",
                       "--no-parallel", "--filter", suite]
            if skip_build:
                command.append("--skip-build")
            return command

        def measure(variant: str, mode: str, pass_name: str, *, build: bool = False) -> dict:
            env = base_env.copy()
            env.update(ILLIQUID_PIP_STORAGE_MODE=mode, ILLIQUID_PIP_STORAGE_PASS=pass_name)
            raw = runner.run(swift_command(variant, "PiPVideoWorkingStorageMeasurements", skip_build=not build),
                             label=pass_name, env=env, timeout=2400 if build else 180)
            counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", raw)
            matches = re.findall(r"^" + re.escape(MARKER) + r"(\{.*\})$", raw, re.MULTILINE)
            if counts != ["1"] or len(matches) != 1:
                raise RuntimeError("Expected one executed native test and one measurement; inspect discovery/enablement.")
            row = json.loads(matches[0])
            validate_record(row, variant, mode, pass_name)
            return row

        binaries = {}
        for variant in VARIANTS:
            print(f"Building {variant} application/test graph once", flush=True)
            probe = measure(variant, MODES[0], f"build-{variant}", build=True)
            save(output / f"{variant}-build-probe.json", probe)
            print("PIP_VIDEO_WORKING_STORAGE_BUILD_PROBE " + json.dumps(
                {**probe, "variant": variant}, sort_keys=True, allow_nan=False), flush=True)
            binary_path = Path(runner.run(
                ["swift", "build", "--package-path", roots[variant],
                 "--scratch-path", output / "build" / f"{variant}-build",
                 "-c", "release", "--show-bin-path"], label=f"{variant}-bin-path", timeout=60).strip())
            executables = [path for bundle in binary_path.glob("*.xctest")
                           for path in (bundle / "Contents" / "MacOS").glob("*") if path.is_file()]
            if not executables:
                raise RuntimeError(f"No native test executable in {binary_path}")
            binaries[variant] = [{"path": str(path), "sha256": digest(path)} for path in sorted(executables)]
            save(output / "binaries.json", binaries)

        if args.regression_filter:
            env = base_env.copy()
            env["ILLIQUID_PIP_STORAGE_MEASURE"] = "0"
            raw = runner.run(swift_command("candidate", args.regression_filter),
                             env=env, label="candidate-regressions", timeout=600)
            counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", raw)
            if len(counts) != 1 or int(counts[0]) == 0:
                raise RuntimeError("Expected a successful nonempty candidate regression suite.")
            save(output / "regressions.json",
                 {"filter": args.regression_filter, "passed_tests": int(counts[0]),
                  "log": runner.commands[-1]["log"]})

        observations = []
        for mode in MODES:
            for pair in range(args.pairs):
                order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
                pair_rows = {}
                for position, variant in enumerate(order):
                    pass_name = f"{mode}-pair-{pair:02}-{variant}"
                    row = measure(variant, mode, pass_name)
                    row.update(variant=variant, pair=pair, position=position,
                               ordinal=len(observations), log=runner.commands[-1]["log"])
                    pair_rows[variant] = row
                    observations.append(row)
                    with (output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
                    print("PIP_VIDEO_WORKING_STORAGE_OBSERVATION " + json.dumps(
                        row, sort_keys=True, allow_nan=False), flush=True)
                for key in ("mode", "width", "height", "is_hdr", "temporarily_held_outputs",
                            "metal_device", "metal_registry_id", "output", "reentry_output"):
                    if pair_rows["control"][key] != pair_rows["candidate"][key]:
                        raise RuntimeError(f"Paired native output/device mismatch: {mode}, {key}")

        summary = summarize(observations, args.pairs)
        save(output / "summary.json", summary)
        for variant in VARIANTS:
            for binary in binaries[variant]:
                if digest(Path(binary["path"])) != binary["sha256"]:
                    raise RuntimeError("The compiled native executable changed during measurement.")
            for path, expected in receipts[variant]["files"].items():
                if digest(roots[variant] / path) != expected:
                    raise RuntimeError(f"Measurement input changed during execution: {variant}/{path}")
            current_production = {str(path.relative_to(roots[variant])): digest(path)
                                  for path in sorted((roots[variant] / "Sources").rglob("*"))
                                  if path.is_file()}
            if current_production != receipts[variant]["production"]:
                raise RuntimeError(f"Production sources changed during execution: {variant}")
        completion.update(succeeded=True, candidate_commit=revision,
                          observations=len(observations),
                          expected_observations=len(MODES) * args.pairs * 2,
                          pairs=args.pairs, alternating_order=True,
                          native_gpu_and_pixel_output_verified=True,
                          stopped_resource_states_verified=True,
                          source_and_binary_hashes_unchanged=True,
                          control_stop_matches_parent=True)
        save(output / "completion.json", completion)
        print("PIP_VIDEO_WORKING_STORAGE_SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)
    except BaseException as error:
        completion["error"] = f"{type(error).__name__}: {error}"
        save(output / "completion.json", completion)
        raise


if __name__ == "__main__":
    main()
