#!/usr/bin/env python3
"""Serial, muted mpv/IINA process profiles. IPC timings are not display latency."""
import argparse
import ctypes
import json
import math
import os
from pathlib import Path
import socket
import plistlib
import signal
import statistics
import subprocess
import tempfile
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ("user", "system", "idle_wakeups", "interrupt_wakeups", "pageins", "wired",
         "resident", "footprint", "started", "exited")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = Timebase()
if ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(_timebase)) != 0:
    raise RuntimeError("Cannot read the Mach timebase")
CPU_SECONDS_PER_TICK = _timebase.numer / _timebase.denom / 1e9


def usage(pid):
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    value = Usage()
    if lib.proc_pid_rusage(pid, 0, ctypes.byref(value)) != 0:
        raise RuntimeError("Cannot read process resource counters")
    return {"cpu_s": (value.user + value.system) * CPU_SECONDS_PER_TICK,
            "cpu_seconds_per_tick": CPU_SECONDS_PER_TICK, "cpu_ticks": value.user + value.system,
            "footprint_mib": value.footprint / 2**20, "rss_mib": value.resident / 2**20,
            "idle_wakeups": value.idle_wakeups, "interrupt_wakeups": value.interrupt_wakeups}


def windows(pid):
    """Read window geometry/onscreen state without Accessibility input access."""
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_ulong, ctypes.c_void_p]
    cf.CFPropertyListCreateData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]; cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]; cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    listing = cg.CGWindowListCopyWindowInfo(16, 0)
    if not listing: return []
    data = cf.CFPropertyListCreateData(None, listing, 200, 0, None)
    try:
        if not data: return []
        records = plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
        return [{k: row.get(k) for k in ["kCGWindowNumber", "kCGWindowBounds", "kCGWindowIsOnscreen", "kCGWindowLayer", "kCGWindowAlpha"]}
                for row in records if row.get("kCGWindowOwnerPID") == pid]
    finally:
        if data: cf.CFRelease(data)
        cf.CFRelease(listing)


class IPC:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(15)
        self.socket.connect(str(path))
        self.buffer = b""
        self.sequence = 0
        self.events = []

    def read(self):
        while b"\n" not in self.buffer:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise RuntimeError("Player disconnected")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def command(self, command):
        self.sequence += 1
        self.socket.sendall((json.dumps({"command": command, "request_id": self.sequence}) + "\n").encode())
        while True:
            reply = self.read()
            if reply.get("request_id") == self.sequence:
                if reply.get("error") != "success":
                    raise RuntimeError(str(reply))
                return reply.get("data")
            if "event" in reply:
                self.events.append(reply)

    def get(self, name):
        try:
            return self.command(["get_property", name])
        except RuntimeError:
            return None

    def seek(self, target):
        # Drain prior replies/events using a round-trip barrier.
        self.get("time-pos")
        self.events.clear()
        start = time.monotonic()
        self.command(["seek", target, "absolute+exact"])
        while not any(e.get("event") == "playback-restart" for e in self.events):
            event = self.read()
            if "event" in event:
                self.events.append(event)
            if time.monotonic() - start > 15:
                raise TimeoutError("Seek did not reach playback-restart")
        elapsed = (time.monotonic() - start) * 1000
        return {"target_s": target, "playback_restart_ms": elapsed, "position_s": self.get("time-pos")}


def phase(pid, ipc, name, duration):
    start = time.monotonic()
    first = usage(pid)
    position = ipc.get("time-pos")
    samples = []
    while time.monotonic() - start < duration:
        time.sleep(.25)
        samples.append({"elapsed_s": time.monotonic() - start, **usage(pid)})
    wall = time.monotonic() - start
    return {"phase": name, "wall_s": wall,
            "cpu_percent_one_core": (samples[-1]["cpu_s"] - first["cpu_s"]) / wall * 100,
            "footprint_peak_mib": max(s["footprint_mib"] for s in samples),
            "footprint_growth_mib": samples[-1]["footprint_mib"] - first["footprint_mib"],
            "clock_advance_s": (ipc.get("time-pos") or 0) - (position or 0), "samples": samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player", choices=["mpv", "iina"], required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--backing-scale", type=int, choices=[1, 2], default=2,
        help="Retina backing scale of the test display (default: 2)")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 600:
        parser.error("seconds must be between 1 and 600")
    fixture = args.fixture.resolve(strict=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    args.output.write_text(json.dumps({"status": "running", "started_at": started_at}) + "\n")
    existing_iina = set(subprocess.run(["pgrep", "-x", "IINA"], capture_output=True, text=True).stdout.split())
    # Silence only the owned test player; leave the system output setting intact.
    with tempfile.TemporaryDirectory(prefix="illiquid-reference-") as temporary:
        ipc_path = Path(temporary) / "ipc"
        options = [f"--input-ipc-server={ipc_path}", "--pause=yes", "--keep-open=yes",
                   "--hwdec=videotoolbox", "--volume=0", "--resume-playback=no",
                   "--save-position-on-quit=no", "--geometry=960x540+100+100", "--osd-level=0"]
        if args.player == "mpv":
            # mpv geometry is in backing pixels on this Retina test display;
            # IINA interprets it in points. Both windows must be 960x540 points.
            options = [o.replace("960x540+100+100",
                f"{960 * args.backing_scale}x{540 * args.backing_scale}+{100 * args.backing_scale}+{100 * args.backing_scale}") for o in options]
            command = ["/opt/homebrew/bin/mpv", "--no-config", "--vo=gpu-next", *options, str(fixture)]
        else:
            command = ["/Applications/IINA.app/Contents/MacOS/iina-cli", "--no-stdin", "--keep-running",
                       *("--mpv-" + o[2:] for o in options), str(fixture)]
        with args.output.with_suffix(".log").open("w") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            ipc = None
            owns_ipc = args.player == "mpv"
            pid = process.pid
            try:
                deadline = time.monotonic() + 30
                while not ipc_path.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Player did not start its IPC endpoint")
                    time.sleep(.1)
                ipc = IPC(ipc_path)
                if args.player == "iina":
                    # Read the PID from our private IPC endpoint, never choose a user session.
                    pid = int(ipc.get("pid"))
                    if str(pid) in existing_iina:
                        raise RuntimeError("IPC unexpectedly belongs to an existing IINA session")
                    owns_ipc = True
                while ipc.get("duration") is None or ipc.get("time-pos") is None or ipc.get("video-out-params") is None:
                    if time.monotonic() > deadline:
                        raise TimeoutError("Media did not load")
                    time.sleep(.1)
                ipc.command(["set_property", "pause", True])
                ipc.seek(0)
                metadata = {name: ipc.get(name) for name in
                    ["mpv-version", "ffmpeg-version", "current-vo", "hwdec-current", "video-params",
                     "display-fps", "osd-dimensions", "duration", "audio-params"]}
                ipc.command(["set_property", "pause", False])
                time.sleep(2)
                playing = phase(pid, ipc, "playing-visible", args.seconds)
                metadata["windows-after-play"] = windows(pid)
                metadata["osd-dimensions-after-play"] = ipc.get("osd-dimensions")
                metadata["video-out-params-after-play"] = ipc.get("video-out-params")
                ipc.command(["set_property", "pause", True])
                time.sleep(1)
                paused = phase(pid, ipc, "paused-visible", 4)
                seeks = [ipc.seek(target) for target in [1.5, 8.5, 2.5, 9.5, 1.5, 8.5]]
                times = sorted(s["playback_restart_ms"] for s in seeks)
                result = {"player": args.player, "fixture": str(fixture), "command": command,
                    "metadata": metadata, "phases": [playing, paused], "seeks": seeks,
                    "seek_median_ms": statistics.median(times), "seek_p95_ms": times[math.ceil(.95 * len(times)) - 1],
                    "frame_drop_count": ipc.get("frame-drop-count"),
                    "decoder_frame_drop_count": ipc.get("decoder-frame-drop-count"),
                    "limitations": ["IPC playback-restart is not input-to-visible-frame latency",
                                     "Reference app chrome and renderer differ from the native runtime harness"]}
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
                if ipc and owns_ipc:
                    try:
                        ipc.command(["quit"])
                    except (OSError, RuntimeError):
                        pass
                    ipc.socket.close()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if args.player == "iina" and pid != process.pid and str(pid) not in existing_iina:
                        try:
                            os.kill(pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
