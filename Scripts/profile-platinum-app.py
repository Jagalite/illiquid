#!/usr/bin/env python3
"""Measure an isolated benchmark bundle through its existing control protocol."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import tempfile
import time
import uuid

spec = importlib.util.spec_from_file_location("reference_profile", Path(__file__).with_name("profile-reference-player.py"))
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--pin-chrome", action="store_true")
    parser.add_argument("--show-sidebar", action="store_true")
    parser.add_argument("--window-size", default="960x540")
    parser.add_argument("--capture-window", type=Path, help="Capture only the owned benchmark window")
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9][0-9]{2,3}x[1-9][0-9]{2,3}", args.window_size):
        parser.error("window-size must be WIDTHxHEIGHT in points")
    if not 1 <= args.seconds <= 1800:
        parser.error("seconds must be between 1 and 1800")
    app = args.app.resolve(strict=True)
    fixture = args.fixture.resolve(strict=True)
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if metadata["CFBundleIdentifier"] != "com.example.SuperplayrBenchmark":
        raise RuntimeError("Use a separate benchmark bundle; do not profile the user's app session")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    args.output.write_text(json.dumps({"status": "running", "started_at": started_at}) + "\n")
    log_path = args.output.with_suffix(".log")
    subprocess.run(["osascript", "-e", "set volume output muted true"], check=True)
    # Only the isolated benchmark app domain is changed. Silence audio before opening media.
    preferences = json.dumps({"isMuted": True, "volume": 0, "playbackSpeed": 1, "remembersPlaybackHistory": False}).encode().hex()
    subprocess.run(["defaults", "write", metadata["CFBundleIdentifier"],
        "Superplayr.playback-preferences.v1", "-data", preferences], check=True)
    subprocess.run(["defaults", "write", metadata["CFBundleIdentifier"],
        "Superplayr.playback-state.v1", "-data", b"{}".hex()], check=True)
    with tempfile.TemporaryDirectory(prefix="platinum-app-profile-") as temporary:
        command_file = Path(temporary) / "command.json"
        session = uuid.uuid4().hex
        environment = dict(os.environ, SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES="1",
            SUPERPLAYR_BENCHMARK_CONTROL_SESSION=session, SUPERPLAYR_BENCHMARK_CONTROL_FILE=str(command_file),
            SUPERPLAYR_BENCHMARK_WINDOW_SIZE=args.window_size, SUPERPLAYR_BENCHMARK_SOFTWARE_OUTPUT="planar", SUPERPLAYR_BENCHMARK_HIDE_SIDEBAR="0" if args.show_sidebar else "1",
            SUPERPLAYR_BENCHMARK_PIN_PLAYBACK_CHROME="1" if args.pin_chrome else "0")
        with log_path.open("w") as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/Illiquid")], env=environment,
                stdout=log, stderr=subprocess.STDOUT)

            def wait_line(predicate, timeout=20, sample=None):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError("Illiquid exited during profiling")
                    if sample is not None:
                        sample()
                    for line in reversed(log_path.read_text(errors="replace").splitlines()):
                        if predicate(line):
                            return line
                    time.sleep(.01)
                raise TimeoutError("Illiquid did not acknowledge its benchmark command")

            def command(action, target=None):
                identifier = uuid.uuid4().hex
                body = {"session": session, "id": identifier, "action": action}
                if target is not None:
                    body["targetSeconds"] = target
                pending = command_file.with_suffix(".pending")
                pending.write_text(json.dumps(body))
                pending.replace(command_file)
                start = time.monotonic()
                first_usage = reference.usage(process.pid)
                resource_samples = [first_usage]
                last_sample = start
                def sample_resources():
                    nonlocal last_sample
                    if time.monotonic() - last_sample >= .05:
                        resource_samples.append(reference.usage(process.pid))
                        last_sample = time.monotonic()
                os.kill(process.pid, signal.SIGUSR1)
                line = wait_line(lambda line: f"id={identifier} " in line and
                    ("phase=snapshot" in line or "phase=completed" in line or "accepted=no" in line),
                    sample=sample_resources if action == "seek-exact" else None)
                if "accepted=yes" not in line:
                    raise RuntimeError(line)
                fields = dict(re.findall(r"([\w-]+)=([^ ]+)", line))
                final_usage = reference.usage(process.pid)
                resource_samples.append(final_usage)
                return {"wall_ms": (time.monotonic() - start) * 1000, "response": fields,
                    "cpu_time_ms": (final_usage["cpu_s"] - first_usage["cpu_s"]) * 1000,
                    "footprint_peak_mib": max(s["footprint_mib"] for s in resource_samples)}

            def phase(name, duration):
                clock_start = float(command("snapshot")["response"]["renderer-time"])
                start = time.monotonic()
                first = reference.usage(process.pid)
                samples = []
                while time.monotonic() - start < duration:
                    time.sleep(.25)
                    samples.append({"elapsed_s": time.monotonic() - start, **reference.usage(process.pid)})
                wall = time.monotonic() - start
                clock_end = float(command("snapshot")["response"]["renderer-time"])
                return {"phase": name, "wall_s": wall,
                    "cpu_percent_one_core": (samples[-1]["cpu_s"] - first["cpu_s"]) / wall * 100,
                    "footprint_peak_mib": max(s["footprint_mib"] for s in samples),
                    "footprint_growth_mib": samples[-1]["footprint_mib"] - first["footprint_mib"],
                    "clock_advance_s": clock_end - clock_start, "samples": samples}

            try:
                wait_line(lambda line: f"session={session} phase=ready" in line)
                subprocess.run(["osascript", "-e", 'tell application id "com.example.SuperplayrBenchmark" to activate'], check=True)
                time.sleep(1)
                subprocess.run(["osascript", "-e", 'on run argv', "-e",
                    'tell application id "com.example.SuperplayrBenchmark" to open POSIX file (item 1 of argv)',
                    "-e", "end run", str(fixture)], check=True, timeout=20)
                wait_line(lambda line: "[native-presentation]" in line and "renderer-clock-advanced=yes" in line)
                if float(command("snapshot")["response"]["renderer-rate"]) != 0:
                    command("pause")
                command("seek-exact", 0)
                command("play")
                time.sleep(2)
                playing = phase("playing-visible", args.seconds)
                window_metadata = reference.windows(process.pid)
                if args.capture_window:
                    owned_window = next(row for row in window_metadata
                        if row["kCGWindowIsOnscreen"] and row["kCGWindowLayer"] == 0
                        and row["kCGWindowBounds"]["Width"] >= 600)
                    args.capture_window.parent.mkdir(parents=True, exist_ok=True)
                    subprocess.run(["screencapture", "-x", "-o", "-l", str(owned_window["kCGWindowNumber"]),
                                    str(args.capture_window.resolve())], check=True, timeout=15)
                command("pause")
                time.sleep(1)
                paused = phase("paused-visible", 4)
                seeks = [{"target_s": target, **command("seek-exact", target)}
                    for target in [1.5, 8.5, 2.5, 9.5, 1.5, 8.5]]
                result = {"player": "Illiquid full app", "fixture": str(fixture),
                    "bundle": str(app), "pinned_chrome": args.pin_chrome, "sidebar_requested": args.show_sidebar,
                    "window_size_requested": args.window_size, "windows_after_play": window_metadata,
                    "phases": [playing, paused], "seeks": seeks,
                    "limitations": ["Seek acknowledgments measure pipeline completion, not visible-frame latency",
                                     "Window/chrome visibility requires separate observation"]}
                result["status"] = "complete"
                result["started_at"] = started_at
                result["checks"] = {
                    "playing_clock_tracks_wall_time": .85 * playing["wall_s"] < playing["clock_advance_s"] < 1.15 * playing["wall_s"],
                    "paused_clock_holds": abs(paused["clock_advance_s"]) < .1,
                }
                args.output.write_text(json.dumps(result, indent=2) + "\n")
                if not all(result["checks"].values()):
                    raise RuntimeError(f"Clock validation failed: {result['checks']}")
            finally:
                # This identifier is unique to the owned benchmark copy.
                subprocess.run(["osascript", "-e", 'tell application id "com.example.SuperplayrBenchmark" to quit'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
