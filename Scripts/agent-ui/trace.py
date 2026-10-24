#!/usr/bin/env python3
"""Bounded, standalone xctrace adapter (Python stdlib only).

doctor never records. start returns only after a Darwin tracing-started notification;
stop requests graceful finalization by the run's own bounded supervisor. Raw logs,
commands, identities, exit receipts and XML are retained under RUN/trace/CAPTURE.
The supervisor, not a later CLI invocation, signals its unreaped recorder child.

export inspects the TOC by default; --metrics opts into known-schema extraction.
The only initial metric is time_profile_samples, a diagnostic row count, not CPU
utilization, displayed FPS, or a correlated interaction measurement. Qualification
of the capture pipeline against slow/smooth controls remains a separate live task.
Callers should allow at least 70/110/25/100 seconds for doctor/start/stop/export;
the extra time allows the bounded owner to finish cleanup after a deadline.
"""

import argparse
import contextlib
import ctypes
import errno
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET


COMMAND_TIMEOUT = 10.0
DISCOVERY_COMMAND_TIMEOUT = 30.0
DISCOVERY_TIMEOUT = 60.0
START_TIMEOUT = 15.0
STOP_TIMEOUT = 20.0
EXPORT_COMMAND_TIMEOUT = 30.0
EXPORT_TIMEOUT = 90.0
FINALIZE_TIMEOUT = 10.0
KILL_GRACE = 2.0
MAX_SECONDS = 3600.0
MAX_XML_BYTES = 64 * 1024 * 1024
METRIC = "time_profile_samples"
RECOMMENDED_OUTER_TIMEOUTS = {"doctor": 70, "start": 110, "stop": 25, "export": 100}


class TraceError(Exception):
    def __init__(self, status, message, **data):
        super().__init__(message)
        self.status, self.data = status, data


def envelope(status="ok", data=None, error=None):
    result = {"schema_version": 1, "status": status, "data": data or {}}
    if error:
        result["error"] = error
    return result


def stamp():
    return {"monotonic": time.monotonic(), "unix": time.time()}


def save(path, value):
    """Atomic publication; readers never interpret half-written ownership state."""
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            json.dump(value, stream, allow_nan=False, indent=2)
            stream.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def stream_diagnostic(path):
    """Bound the error summary without discarding the complete raw stream."""
    path = Path(path)
    try:
        with path.open("rb") as stream:
            size = stream.seek(0, os.SEEK_END)
            stream.seek(max(0, size - 4096))
            tail = stream.read(4096).decode("utf-8", errors="replace")
        return {"path": str(path), "bytes": size, "tail": tail}
    except OSError as exc:
        return {"path": str(path), "error": str(exc)}


def process_identity(pid):
    """Kernel start identity and executable, never process-name matching.

    A missing PID returns None. Permission/inspection failures raise: inability to
    inspect must never be mistaken for proof that an owned process has exited.
    """
    if not isinstance(pid, int) or pid <= 0:
        raise ValueError("PID must be positive")
    try:
        if sys.platform == "darwin":
            class BSDInfo(ctypes.Structure):
                _fields_ = ([(name, ctypes.c_uint32) for name in (
                    "flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
                    "ruid", "rgid", "svuid", "svgid", "reserved")]
                    + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
                    + [(name, ctypes.c_uint32) for name in (
                        "nfiles", "pgid", "pjobc", "tdev", "tpgid")]
                    + [("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
                       ("start_usec", ctypes.c_uint64)])

            lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int,
                                        ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
            lib.proc_pidinfo.restype = ctypes.c_int
            lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            lib.proc_pidpath.restype = ctypes.c_int
            info = BSDInfo()
            size = lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
            if size != ctypes.sizeof(info):
                code = ctypes.get_errno()
                if code == errno.ESRCH:
                    return None
                raise OSError(code, "proc_pidinfo failed")
            if info.status == 5:  # SZOMB: no executable or signalable work remains.
                return None
            buffer = ctypes.create_string_buffer(4096)
            if lib.proc_pidpath(pid, buffer, len(buffer)) <= 0:
                code = ctypes.get_errno()
                if code == errno.ESRCH:
                    return None
                raise OSError(code, "proc_pidpath failed")
            executable = os.fsdecode(buffer.value)
            start = f"{info.start_sec}:{info.start_usec}"
        elif sys.platform.startswith("linux"):
            # /proc fields after comm (which may itself contain spaces/parens).
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            if fields[0] == "Z":
                return None
            start = fields[19]
            executable = os.readlink(f"/proc/{pid}/exe")
        else:
            raise TraceError("unsupported", "Kernel process identity is unsupported on this OS")
        return {"pid": pid, "start_identity": start,
                "executable": os.path.realpath(executable),
                "pgid": os.getpgid(pid), "sid": os.getsid(pid)}
    except (FileNotFoundError, ProcessLookupError):
        return None


class Notification:
    """Receive a posted event on a dedicated, nonblocking Darwin notification FD.

    notify_register_check/notify_check permit false positives (see notify.h), so
    their shared-memory state cannot establish tracing readiness. A private FD
    receives only this registration's token when the named event is posted.
    """
    def __init__(self, name):
        if sys.platform != "darwin":
            raise TraceError("unsupported", "Recording readiness requires Darwin notifications")
        self.lib = ctypes.CDLL("/usr/lib/system/libsystem_notify.dylib")
        self.lib.notify_register_file_descriptor.argtypes = [
            ctypes.c_char_p, ctypes.POINTER(ctypes.c_int), ctypes.c_int,
            ctypes.POINTER(ctypes.c_int)]
        self.lib.notify_register_file_descriptor.restype = ctypes.c_uint32
        self.lib.notify_cancel.argtypes = [ctypes.c_int]
        self.lib.notify_cancel.restype = ctypes.c_uint32
        token, descriptor = ctypes.c_int(), ctypes.c_int(-1)
        if self.lib.notify_register_file_descriptor(
                name.encode(), ctypes.byref(descriptor), 0, ctypes.byref(token)) != 0:
            raise TraceError("unsupported", "Cannot register tracing readiness notification")
        self.token, self.descriptor = token.value, descriptor.value
        self.pending = b""
        try:
            os.set_blocking(self.descriptor, False)
            os.set_inheritable(self.descriptor, False)
        except BaseException:
            self.close()
            raise

    def fired(self):
        try:
            part = os.read(self.descriptor, ctypes.sizeof(ctypes.c_int) - len(self.pending))
        except BlockingIOError:
            return False
        if not part:
            raise TraceError("error", "Tracing readiness notification descriptor closed")
        self.pending += part
        if len(self.pending) < ctypes.sizeof(ctypes.c_int):
            return False
        # This FD is not reused by other registrations, so every delivered token
        # belongs to our unique name. Retain partial reads between polls.
        self.pending = b""
        return True

    def close(self):
        if self.token is not None:
            if self.lib.notify_cancel(self.token) != 0:
                raise TraceError("error", "Cannot cancel tracing readiness notification")
            # notify_cancel owns and closes the descriptor; do not close it again.
            self.token = None


def same_process(expected):
    return expected is not None and process_identity(expected["pid"]) == expected


def signal_child(child, identity, sig):
    # poll() reaps first: a reused PID can never be signalled after our child exits.
    if child.poll() is not None:
        return False
    try:
        matches = same_process(identity)
    except OSError:
        # A still-unreaped Popen child pins the PID even if metadata inspection
        # fails. This fallback is only for this invocation's actual child, never
        # a PID reconstructed from disk. Session/group checks still apply.
        matches = identity is None
        if not matches:
            raise
    if identity is None:
        matches = True
        pgid, sid = os.getpgid(child.pid), os.getsid(child.pid)
    else:
        pgid, sid = identity["pgid"], identity["sid"]
    if not matches:
        if child.poll() is not None:
            return False
        raise TraceError("target-lost", "Recorder identity changed; refusing to signal",
                         recorder=identity)
    if pgid != child.pid or sid != child.pid:
        raise TraceError("error", "Recorder is not its owned process group/session leader")
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        return False
    return True


def finish_child(child, identity, graceful=True):
    """Bounded SIGINT -> TERM -> KILL, only while the owned child is unreaped."""
    forced = False
    stages = [(signal.SIGTERM, KILL_GRACE), (signal.SIGKILL, KILL_GRACE)]
    if graceful:
        stages.insert(0, (signal.SIGINT, FINALIZE_TIMEOUT))
    for sig, timeout in stages:
        if child.poll() is not None:
            return {"returncode": child.returncode, "forced": forced, "reaped": True}
        if sig != signal.SIGINT:
            forced = True
        signal_child(child, identity, sig)
        try:
            child.wait(timeout=timeout)
            return {"returncode": child.returncode, "forced": forced, "reaped": True}
        except subprocess.TimeoutExpired:
            pass
    raise TraceError("timed-out", "Owned recorder did not exit after bounded cleanup",
                     recorder=identity, cleanup_confirmed=False)


def run_command(command, directory, name, timeout=COMMAND_TIMEOUT):
    """Retain raw streams and receipt even on launch errors and timeouts."""
    directory = Path(directory)
    stdout, stderr = directory / (name + ".stdout"), directory / (name + ".stderr")
    receipt = {"command": command, "started": stamp(), "stdout": str(stdout),
               "stderr": str(stderr), "timeout_seconds": timeout}
    child = None
    try:
        with stdout.open("xb") as out, stderr.open("xb") as err:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out,
                                     stderr=err, start_new_session=True)
            identity = process_identity(child.pid)
            receipt["process"] = identity
            try:
                child.wait(timeout=timeout)
                receipt.update(returncode=child.returncode, status="ok" if child.returncode == 0 else "error")
            except subprocess.TimeoutExpired:
                receipt.update(finish_child(child, identity, graceful=False))
                receipt["status"] = "timed-out"
    except BaseException as exc:
        receipt.update(status="error", error=str(exc))
        if child is not None and child.poll() is None:
            try:
                receipt["cleanup"] = finish_child(child, receipt.get("process"), graceful=False)
            except Exception as cleanup_error:
                receipt["cleanup"] = {"confirmed": False, "error": str(cleanup_error)}
        if not isinstance(exc, Exception):
            raise
    finally:
        receipt["finished"] = stamp()
        save(directory / (name + ".receipt.json"), receipt)
    return receipt


def checked(receipt):
    if receipt["status"] != "ok":
        detail = Path(receipt["stderr"]).read_text(errors="replace")[-4096:]
        status = receipt["status"]
        if re.search(r"permission|not authorized|not permitted|access denied", detail, re.I):
            status = "permission-required"
        raise TraceError(status, "xctrace command failed", receipt=receipt, detail=detail)
    return Path(receipt["stdout"]).read_text(errors="replace")


def remaining(deadline, limit):
    seconds = limit if deadline is None else min(limit, deadline - time.monotonic())
    if seconds <= 0:
        raise TraceError("timed-out", "Operation exceeded its total deadline")
    return seconds


def discover(directory, deadline=None):
    try:
        return _discover(directory, deadline)
    except TraceError as exc:
        exc.data.setdefault("receipt_dir", str(directory))
        exc.data.setdefault("failure_phase", "tool-discovery")
        raise


def _discover(directory, deadline=None):
    deadline = min(deadline, time.monotonic() + DISCOVERY_TIMEOUT) if deadline is not None else time.monotonic() + DISCOVERY_TIMEOUT
    resolved = checked(run_command(["/usr/bin/xcrun", "--find", "xctrace"], directory, "find",
                                   remaining(deadline, DISCOVERY_COMMAND_TIMEOUT))).strip()
    if not resolved or not Path(resolved).is_absolute() or not Path(resolved).is_file():
        raise TraceError("unsupported", "xcrun did not resolve an installed xctrace executable")
    tool = os.path.realpath(resolved)
    results = {}
    for name, args in (("version", ["version"]), ("templates", ["list", "templates"]),
                       ("record-help", ["help", "record"]), ("export-help", ["help", "export"])):
        results[name] = checked(run_command([tool] + args, directory, name,
                                           remaining(deadline, DISCOVERY_COMMAND_TIMEOUT)))
    templates = [line.strip() for line in results["templates"].splitlines()
                 if line.strip() and not line.strip().startswith("==")]
    required_record = ("--attach", "--template", "--output", "--time-limit",
                       "--no-prompt", "--notify-tracing-started")
    return {"executable": tool, "version": results["version"].strip(),
            "templates": templates,
            "record_supported": all(opt in results["record-help"] for opt in required_record),
            "export_supported": all(opt in results["export-help"] for opt in ("--toc", "--xpath", "--output")),
            "known_metric_schemas": {"time-profile": [METRIC]},
            "readiness": "darwin-notification", "live_profile_validated": False,
            "timeouts": {"discovery_command": DISCOVERY_COMMAND_TIMEOUT,
                         "discovery_total": DISCOVERY_TIMEOUT,
                         "start_readiness": START_TIMEOUT,
                         "stop": STOP_TIMEOUT, "export_command": EXPORT_COMMAND_TIMEOUT,
                         "export_total": EXPORT_TIMEOUT,
                         "recommended_outer": RECOMMENDED_OUTER_TIMEOUTS}}


@contextlib.contextmanager
def locked(run_dir):
    root = Path(run_dir).resolve() / "trace"
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise TraceError("error", "Another trace operation owns this run")
        try:
            yield root
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def current(root):
    metadata = load(root / "current.json")
    capture_id = metadata["capture_id"]
    if not re.fullmatch(r"[0-9a-f]{32}", capture_id):
        raise TraceError("error", "Invalid capture identity")
    capture = root / capture_id
    if capture.is_symlink():
        raise TraceError("error", "Capture directory cannot be a symlink")
    request = load(capture / "request.json")
    if request["capture_id"] != capture_id:
        raise TraceError("error", "Capture ownership metadata disagrees")
    return capture, request


def request_stop(capture, request):
    save(capture / "stop.request.json", {"capture_id": request["capture_id"], "requested": stamp()})


def await_outcome(capture, timeout=STOP_TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if (capture / "outcome.json").exists():
            return load(capture / "outcome.json")
        time.sleep(0.05)
    raise TraceError("timed-out", "No final recorder receipt before stop deadline",
                     capture_dir=str(capture), cleanup_confirmed=False)


def start(root, pid, template, seconds):
    if not math.isfinite(seconds) or not 0 < seconds <= MAX_SECONDS:
        raise TraceError("error", f"seconds must be finite and in (0, {MAX_SECONDS:g}]")
    if (root / "current.json").exists():
        previous, _ = current(root)
        if not (previous / "outcome.json").exists():
            raise TraceError("error", "Previous recorder has no final receipt; stop it first",
                             capture_dir=str(previous))
        if not load(previous / "outcome.json")["data"].get("cleanup_confirmed"):
            raise TraceError("error", "Previous recorder cleanup is unconfirmed; refusing overlap")
    target = process_identity(pid)
    if target is None:
        raise TraceError("target-lost", "Target PID is not alive")
    manifest = root.parent / "manifest.json"
    run_manifest = load(manifest) if manifest.exists() else None
    if manifest.exists() and not isinstance(run_manifest, dict):
        raise TraceError("target-lost", "Runner manifest must contain a pinned identity object")
    if run_manifest is not None:
        expected = {"pid": run_manifest.get("pid"),
                    "start_identity": run_manifest.get("process_start_identity"),
                    "executable": run_manifest.get("executable_path")}
        if any(not value or target.get(key) != value for key, value in expected.items()):
            raise TraceError("target-lost", "Target differs from the runner's pinned identity",
                             expected=expected, observed=target)
    if sys.platform != "darwin":
        raise TraceError("unsupported", "xctrace recording requires macOS")
    capture = root / uuid.uuid4().hex
    capture.mkdir()
    capabilities = discover(capture)
    if not capabilities["record_supported"]:
        raise TraceError("unsupported", "Installed xctrace lacks required recording flags", capabilities=capabilities)
    if template not in capabilities["templates"]:
        raise TraceError("unsupported", "Requested template is not installed", capabilities=capabilities)
    run_id = run_manifest.get("run_id", root.parent.name) if run_manifest is not None else root.parent.name
    request = {"schema_version": 1, "capture_id": capture.name, "run_id": run_id,
               "target": target, "template": template, "seconds": seconds,
               "capabilities": capabilities, "created": stamp()}
    save(capture / "request.json", request)
    save(root / "current.json", {"capture_id": capture.name})
    supervisor = None
    try:
        with (capture / "supervisor.stdout").open("xb") as out, (capture / "supervisor.stderr").open("xb") as err:
            supervisor = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "_record", str(capture)],
                stdin=subprocess.DEVNULL, stdout=out, stderr=err, start_new_session=True,
                close_fds=True)
        deadline = time.monotonic() + START_TIMEOUT + 1
        while time.monotonic() < deadline:
            if (capture / "outcome.json").exists():
                outcome = load(capture / "outcome.json")
                raise TraceError(outcome["status"] if outcome["status"] != "ok" else "assertion-failed",
                                 outcome.get("error") or "Recorder ended before start could return readiness",
                                 outcome=outcome, capture_dir=str(capture),
                                 cleanup_confirmed=outcome["data"].get("cleanup_confirmed", False))
            if (capture / "ready.json").exists():
                ready = load(capture / "ready.json")
                if not same_process(target):
                    raise TraceError("target-lost", "Target changed during trace startup")
                if not same_process(ready["recorder"]):
                    raise TraceError("target-lost", "Recorder ended before readiness could be returned")
                return {"run_id": run_id, "capture_id": capture.name, "capture_dir": str(capture),
                        "target": target, "ready": ready,
                        "measurement_valid": False}
            if supervisor.poll() is not None:
                raise TraceError("error", "Recorder supervisor exited without a receipt", capture_dir=str(capture))
            time.sleep(0.05)
        raise TraceError("timed-out", "Recorder did not confirm tracing readiness", capture_dir=str(capture))
    except BaseException:
        request_stop(capture, request)
        if supervisor is not None:
            # The worker owns and reaps its recorder; never kill its supervisor
            # while that cleanup might still be in progress.
            try:
                supervisor.wait(timeout=STOP_TIMEOUT)
            except subprocess.TimeoutExpired:
                raise TraceError("timed-out", "Supervisor cleanup did not finish", cleanup_confirmed=False,
                                 capture_dir=str(capture))
        if supervisor is None:
            save(capture / "outcome.json", envelope("error", {
                "run_id": run_id, "capture_id": capture.name, "cleanup_confirmed": True,
                "measurement_valid": False}, "Supervisor could not be launched"))
        raise


def record_worker(capture):
    """Internal bounded owner. Only this process signals the recorder child."""
    capture = Path(capture)
    request = load(capture / "request.json")
    child, identity, notification = None, None, None
    cleanup_graceful = True
    started = stamp()
    data = {"run_id": request["run_id"], "capture_id": request["capture_id"],
            "target": request["target"], "capture_dir": str(capture),
            "cleanup_confirmed": True, "measurement_valid": False}
    result = envelope("error", data, "Recording did not finish")
    interrupted = []
    old_handlers = {}
    phase = "recorder-launch"
    try:
        for sig in (signal.SIGINT, signal.SIGTERM):
            old_handlers[sig] = signal.signal(sig, lambda number, frame: interrupted.append(number))
        save(capture / "supervisor.json", {"process": process_identity(os.getpid()), "started": started})
        if not same_process(request["target"]):
            raise TraceError("target-lost", "Target identity changed before recorder launch")
        name = "com.illiquid.agent-ui.trace." + request["capture_id"]
        notification = Notification(name)
        command = [request["capabilities"]["executable"], "record", "--template", request["template"],
                   "--attach", str(request["target"]["pid"]), "--time-limit", f'{request["seconds"]:g}s',
                   "--output", str(capture / "recording.trace"), "--no-prompt",
                   "--notify-tracing-started", name]
        with (capture / "record.stdout").open("xb") as out, (capture / "record.stderr").open("xb") as err:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                     start_new_session=True, close_fds=True)
            identity = process_identity(child.pid)
            save(capture / "recorder.json", {"process": identity, "command": command, "started": stamp()})
            if identity is None:
                raise TraceError("error", "Recorder exited or could not be identified at launch")
            phase = "tracing-readiness"
            ready = False
            start_deadline = time.monotonic() + START_TIMEOUT
            end_deadline = None
            stopping = False
            while True:
                code = child.poll()
                if code is not None:
                    data["returncode"] = code
                    if code != 0:
                        detail = (capture / "record.stderr").read_text(errors="replace")[-4096:]
                        status = "permission-required" if re.search(
                            r"permission|not authorized|not permitted|access denied", detail, re.I) else "error"
                        raise TraceError(status, "Recorder exited unsuccessfully", detail=detail)
                    if not ready:
                        raise TraceError("assertion-failed", "Recorder exited without tracing readiness")
                    if not same_process(request["target"]):
                        raise TraceError("target-lost", "Target exited or changed identity before recording completed")
                    if not (capture / "recording.trace").exists():
                        raise TraceError("assertion-failed", "Recorder produced no raw trace")
                    data.update(ready=True, stopped=stopping, trace=str(capture / "recording.trace"))
                    result = envelope("ok", data)
                    break
                now = time.monotonic()
                stop_file = capture / "stop.request.json"
                stop = bool(interrupted) or (stop_file.exists() and
                       load(stop_file).get("capture_id") == request["capture_id"])
                if stop and not stopping:
                    signal_child(child, identity, signal.SIGINT)
                    stopping = True
                    phase = "recorder-finalization"
                    end_deadline = now + FINALIZE_TIMEOUT
                if not stopping and not same_process(request["target"]):
                    raise TraceError("target-lost", "Target exited or changed identity during recording")
                if not ready and not stopping and now >= start_deadline:
                    raise TraceError("timed-out", "Tracing readiness notification did not arrive")
                if not ready and not stopping and notification.fired():
                    ready = True
                    phase = "recording"
                    end_deadline = now + request["seconds"] + FINALIZE_TIMEOUT
                    save(capture / "ready.json", {"confirmed": stamp(), "source": "darwin-notification",
                                                 "recorder": identity})
                if end_deadline is not None and now >= end_deadline:
                    # SIGINT/time-limit already had the finalization allowance;
                    # do not spend that grace period a second time in cleanup.
                    cleanup_graceful = False
                    raise TraceError("timed-out", "Recorder exceeded bounded recording/finalization deadline")
                time.sleep(0.05)
    except BaseException as exc:
        if isinstance(exc, TraceError):
            data.update(exc.data)
        result = envelope(exc.status if isinstance(exc, TraceError) else "error", data, str(exc))
    finally:
        try:
            if child is not None:
                cleanup = finish_child(child, identity, graceful=cleanup_graceful)
                data.update(cleanup=cleanup, returncode=child.returncode)
                if cleanup["forced"] and result["status"] == "ok":
                    result = envelope("timed-out", data, "Recorder required forced cleanup")
        except BaseException as exc:
            data["cleanup_confirmed"] = False
            result = envelope("error", data, "Recorder cleanup failed: " + str(exc))
        if notification is not None:
            try:
                notification.close()
            except Exception as exc:
                result = envelope("error", data, "Notification cleanup failed: " + str(exc))
        if result["status"] != "ok":
            data.update(failure_phase=phase, diagnostics={
                "stdout": stream_diagnostic(capture / "record.stdout"),
                "stderr": stream_diagnostic(capture / "record.stderr"),
                "readiness_received": (capture / "ready.json").exists()})
        data["finished"] = stamp()
        save(capture / "outcome.json", result)
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
    return result


def stop(root):
    capture, request = current(root)
    if (capture / "outcome.json").exists():
        return load(capture / "outcome.json")
    # File request is safe even if PID metadata is stale. No signal is ever sent
    # by a later invocation using a persisted PID alone.
    request_stop(capture, request)
    return await_outcome(capture)


def xml_root(path):
    if Path(path).stat().st_size > MAX_XML_BYTES:
        raise TraceError("unsupported", "XML exceeds bounded parser size", artifact=str(path))
    raw = Path(path).read_bytes()
    if not raw.strip():
        raise TraceError("assertion-failed", "Export XML is empty", artifact=str(path))
    if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
        raise TraceError("unsupported", "XML entity declarations are unsupported", artifact=str(path))
    try:
        return ET.fromstring(raw)
    except ET.ParseError as exc:
        raise TraceError("error", "Malformed xctrace XML: " + str(exc), artifact=str(path))


def inspect_toc(path):
    root = xml_root(path)
    if root.tag != "trace-toc":
        raise TraceError("unsupported", "Unrecognized table-of-contents XML root")
    tables = []
    for run in root.findall("run"):
        number = run.get("number", "")
        if not re.fullmatch(r"[1-9][0-9]*", number):
            raise TraceError("unsupported", "TOC has an unsupported run number")
        for table in run.findall("./data/table"):
            schema = table.get("schema", "")
            tables.append({"run": int(number), "schema": schema,
                           "attributes": dict(table.attrib),
                           "metrics_supported": schema == "time-profile"})
    return tables


def time_profile_metric(path):
    root = xml_root(path)
    if root.tag != "trace-query-result":
        raise TraceError("unsupported", "Unrecognized query XML root")
    nodes = root.findall("node")
    if len(nodes) != 1:
        raise TraceError("unsupported", "Expected one selected table in query export")
    node = nodes[0]
    schema = node.find("schema")
    if schema is None or schema.get("name") != "time-profile":
        raise TraceError("unsupported", "Export schema does not match time-profile")
    columns = schema.findall("col")
    # Instruments' Sampling.instrdst declares mnemonic="time" with
    # engineeringType="sample-time". The mnemonic and the XML value tag are
    # different: requiring a "sample-time" mnemonic rejects the installed schema.
    if (not columns or columns[0].findtext("mnemonic") != "time"
            or columns[0].findtext("engineering-type") != "sample-time"):
        raise TraceError("unsupported", "Unknown time-profile column layout")
    rows = node.findall("row")
    if not rows:
        raise TraceError("assertion-failed", "time-profile contains no sample rows")
    values = {}
    for row in rows:
        sample = row[0] if len(row) else None
        if sample is None or sample.tag != "sample-time":
            raise TraceError("unsupported", "Sample row lacks sample-time")
        if sample.get("ref"):
            value = values.get(sample.get("ref"))
        else:
            text = (sample.text or "").strip()
            value = int(text) if re.fullmatch(r"[0-9]+", text) else None
            if sample.get("id") and value is not None:
                values[sample.get("id")] = value
        if value is None:
            raise TraceError("unsupported", "Unrecognized sample-time encoding/reference")
    return {"name": METRIC, "value": len(rows), "unit": "samples", "sample_count": len(rows),
            "diagnostic": True,
            "schema": "time-profile", "scope": "exported table; no interaction or target-row attribution",
            "definition": "Count of rows with valid sample timestamps; not FPS or CPU utilization",
            "artifact": str(path)}


def export(root, metrics=False, required=()):
    deadline = time.monotonic() + EXPORT_TIMEOUT
    capture, request = current(root)
    if not (capture / "outcome.json").exists():
        raise TraceError("error", "Stop recorder before export; no final receipt exists")
    outcome = load(capture / "outcome.json")
    if not outcome["data"].get("cleanup_confirmed"):
        raise TraceError("error", "Recorder cleanup is unconfirmed; export refused")
    if not (capture / "recording.trace").exists():
        raise TraceError("assertion-failed", "Raw trace is missing", outcome=outcome)
    directory = capture / ("export-" + uuid.uuid4().hex)
    directory.mkdir()
    data = {"run_id": request["run_id"], "capture_id": capture.name, "export_dir": str(directory),
            "trace": str(capture / "recording.trace"), "recording_status": outcome["status"],
            "metrics": {}, "measurement_valid": False, "qualified": False,
            "measurement_status": "not-requested", "tables": []}
    result = None
    try:
        capabilities = discover(directory, deadline=deadline)
        if not capabilities["export_supported"]:
            raise TraceError("unsupported", "Installed xctrace lacks TOC/XPath export support")
        tool = capabilities["executable"]
        command = [tool, "export", "--input", str(capture / "recording.trace")]
        toc = directory / "toc.xml"
        checked(run_command(command + ["--toc", "--output", str(toc)], directory, "toc",
                            remaining(deadline, EXPORT_COMMAND_TIMEOUT)))
        data["toc"] = str(toc)
        tables = inspect_toc(toc)
        data["tables"] = tables
        if not tables:
            data["measurement_status"] = "empty"
            raise TraceError("assertion-failed", "Trace has no exportable data tables")
        if metrics or required:
            data["measurement_status"] = "unsupported"
            unknown = sorted(set(required) - {METRIC})
            if unknown:
                raise TraceError("unsupported", "Required metrics have no known extractor", missing_metrics=unknown)
            known = [table for table in tables if table["schema"] == "time-profile"]
            if not known:
                raise TraceError("unsupported", "No supported metric schema in trace", missing_metrics=list(required))
            # Multiple time-profile tables per run need additional table selectors.
            runs = [table["run"] for table in known]
            if len(set(runs)) != len(runs):
                raise TraceError("unsupported", "Ambiguous time-profile tables in TOC")
            observations = []
            for table in known:
                path = directory / f'time-profile-{table["run"]}.xml'
                xpath = f'/trace-toc/run[@number="{table["run"]}"]/data/table[@schema="time-profile"]'
                checked(run_command(command + ["--xpath", xpath, "--output", str(path)],
                                    directory, f'metric-{table["run"]}', remaining(deadline, EXPORT_COMMAND_TIMEOUT)))
                observation = time_profile_metric(path)
                observation["run"] = table["run"]
                observations.append(observation)
            data["metrics"][METRIC] = observations
            data["measurement_status"] = "available"
            data["measurement_valid"] = outcome["status"] == "ok"
        if outcome["status"] != "ok":
            raise TraceError("assertion-failed", "Export retained, but recording did not complete successfully")
        result = envelope("ok", data)
    except TraceError as exc:
        data.update(exc.data)
        data["measurement_valid"] = False
        if data["measurement_status"] != "not-requested":
            if data["measurement_status"] == "available" and outcome["status"] != "ok":
                data["measurement_status"] = "recording-incomplete"
            else:
                data["measurement_status"] = "empty" if exc.status == "assertion-failed" else "unsupported" if exc.status == "unsupported" else "error"
        result = envelope(exc.status, data, str(exc))
    except (OSError, ValueError) as exc:
        result = envelope("error", data, str(exc))
    finally:
        if result is not None:
            save(directory / "summary.json", result)
    return result


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise TraceError("error", message)


def main(argv=None):
    invoked = stamp()
    action_id = uuid.uuid4().hex
    try:
        parser = Parser(description=__doc__)
        commands = parser.add_subparsers(dest="command", required=True)
        doctor = commands.add_parser("doctor")
        doctor.add_argument("--run-dir", help="Directory retaining raw discovery receipts (default: retained temp directory)")
        begin = commands.add_parser("start")
        begin.add_argument("--run-dir", required=True)
        begin.add_argument("--pid", type=int, required=True)
        begin.add_argument("--template", required=True)
        begin.add_argument("--seconds", type=float, required=True)
        end = commands.add_parser("stop")
        end.add_argument("--run-dir", required=True)
        extract = commands.add_parser("export")
        extract.add_argument("--run-dir", required=True)
        extract.add_argument("--metrics", action="store_true")
        extract.add_argument("--require-metric", action="append", default=[])
        worker = commands.add_parser("_record", help=argparse.SUPPRESS)
        worker.add_argument("capture_dir")
        args = parser.parse_args(argv)
        if args.command == "_record":
            result = record_worker(args.capture_dir)
        else:
            run_dir = args.run_dir or tempfile.mkdtemp(prefix="agent-ui-trace-")
            with locked(run_dir) as root:
                if args.command == "doctor":
                    directory = root / ("doctor-" + uuid.uuid4().hex)
                    directory.mkdir()
                    result = envelope(data={"capabilities": discover(directory), "receipt_dir": str(directory)})
                elif args.command == "start":
                    result = envelope(data=start(root, args.pid, args.template, args.seconds))
                elif args.command == "stop":
                    result = stop(root)
                else:
                    result = export(root, args.metrics, args.require_metric)
    except TraceError as exc:
        result = envelope(exc.status, exc.data, str(exc))
    except KeyboardInterrupt:
        result = envelope("error", error="Interrupted; owned cleanup requested")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        result = envelope("error", error=str(exc))
    result["data"].update(action_id=action_id, started=invoked, finished=stamp())
    result["data"]["recommended_outer_timeouts_seconds"] = RECOMMENDED_OUTER_TIMEOUTS
    print(json.dumps(result, allow_nan=False))
    return 0 if result["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
