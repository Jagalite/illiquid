#!/usr/bin/env python3
"""Bounded, PID-scoped Illiquid UI automation. Python standard library only.

Launch accepts an already packaged benchmark .app; it never builds the product.
Every operation returns a JSON envelope and retains its receipts in --run-dir.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DOMAIN = "com.example.IlliquidBenchmark"
STATUSES = {"ok", "unsupported", "permission-required", "timed-out", "target-lost",
            "assertion-failed", "error"}
# Includes discovery, readiness and the adapter's own finalization deadlines.
# Keep an outer safety margin so subprocess.run cannot interrupt normal cleanup.
TRACE_TIMEOUTS = {"doctor": 180, "start": 240, "stop": 60, "export": 120}
LIMITATIONS = [
    "Input dispatch and hook acknowledgements do not establish presentation latency.",
    "CPU samples, screenshots and display-link callbacks do not establish displayed FPS.",
    "No live UI, permission or trace qualification is implied by unit tests.",
    "Preference initialization is isolated only when a session-bound app receipt is validated; attach does not establish isolation or live Settings behavior.",
]


class Failure(Exception):
    def __init__(self, status, message, data=None):
        super().__init__(message)
        self.status = status
        self.data = data or {}


def envelope(status="ok", data=None, error=None):
    result = {"schema_version": 1, "status": status, "data": data or {}}
    if error is not None:
        result["error"] = str(error)
    return result


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def json_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, allow_nan=False).encode()).hexdigest()


def atomic_json(path, value):
    path = Path(path)
    # Unique temporary names allow readers to see only complete JSON documents.
    pending = path.with_name(path.name + "." + uuid.uuid4().hex + ".pending")
    try:
        pending.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
        pending.replace(path)
    finally:
        pending.unlink(missing_ok=True)


def read_json(path):
    return json.loads(Path(path).read_text())


def preference_json(text):
    """Reject ambiguous/non-finite JSON at the preference evidence boundary."""
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate preference JSON key")
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError("non-finite preference JSON value")
    return json.loads(text, object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def preference_seed_values(data):
    if len(data) > 1024 * 1024:
        raise ValueError("preference seed exceeds 1 MiB")
    values = preference_json(data.decode("utf-8"))
    def plist_value(value):
        if isinstance(value, dict):
            return all(plist_value(v) for v in value.values())
        if isinstance(value, list):
            return all(plist_value(v) for v in value)
        return (isinstance(value, (str, bool, int)) or
                isinstance(value, float) and math.isfinite(value))
    if (not isinstance(values, dict) or not all(k.startswith("Illiquid.") and
            k != "Illiquid.agent-ui-preference-suite.v1" for k in values) or not plist_value(values)):
        raise ValueError("preference seed requires Illiquid property-list values without null")
    return values


def preference_json_identity(value):
    """Compare JSON structure without treating true as 1 or re-encoding numbers."""
    if isinstance(value, dict):
        return ("object", tuple((k, preference_json_identity(v)) for k, v in sorted(value.items())))
    if isinstance(value, list):
        return ("array", tuple(preference_json_identity(v) for v in value))
    if isinstance(value, bool):
        return ("bool", value)
    if isinstance(value, (int, float)):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("non-finite preference JSON number")
        return ("number", value)
    return (type(value).__name__, value)


def request_json(value):
    """Accept inline JSON, a path, or @path (useful for paths starting with '{')."""
    if value is None:
        return {}
    if isinstance(value, dict):
        return value.copy()
    value = value.strip()
    result = json.loads(value) if value.startswith("{") else read_json(value.removeprefix("@"))
    if not isinstance(result, dict):
        raise Failure("error", "request must be a JSON object")
    return result


def bounded(value, name="timeout", maximum=120):
    if isinstance(value, bool):
        raise Failure("error", f"{name} must be a positive finite number <= {maximum}")
    try:
        value = float(value)
    except (ValueError, TypeError):
        raise Failure("error", f"invalid {name}")
    if not math.isfinite(value) or not 0 < value <= maximum:
        raise Failure("error", f"{name} must be a positive finite number <= {maximum}")
    return value


def subprocess_run(argv, timeout, **kwargs):
    """No shell; every external operation has a deadline, including compilation."""
    try:
        return subprocess.run([str(a) for a in argv], timeout=bounded(timeout, maximum=300),
                              capture_output=True, text=True, **kwargs)
    except subprocess.TimeoutExpired as exc:
        raise Failure("timed-out", f"subprocess deadline: {argv[0]}", {
            "command": [str(a) for a in argv],
            "stdout": _text(exc.stdout), "stderr": _text(exc.stderr)}) from exc
    except FileNotFoundError as exc:
        raise Failure("unsupported", f"tool unavailable: {argv[0]}") from exc


def native_subprocess(argv, request, timeout):
    """Give the helper a bounded chance to release input on timeout/interruption.

    subprocess.run kills a timed-out child immediately. This helper instead gets
    SIGTERM first, which native.swift handles by releasing held keys/buttons.
    Escalation is restricted to this still-owned Popen child, never persisted PIDs.
    """
    child = subprocess.Popen([str(x) for x in argv], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = child.communicate(json.dumps(request), timeout=timeout)
        return subprocess.CompletedProcess(argv, child.returncode, stdout, stderr)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
        child.terminate()
        forced = False
        try:
            stdout, stderr = child.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            forced = True
            child.kill()
            try:
                stdout, stderr = child.communicate(timeout=2)
            except subprocess.TimeoutExpired as final:
                child.stdout.close()
                child.stderr.close()
                raise Failure("timed-out", "native helper cleanup unconfirmed", {
                    "stdout": _text(final.stdout), "stderr": _text(final.stderr),
                    "held_inputs_released": "unconfirmed"}) from final
        raise Failure("timed-out" if isinstance(exc, subprocess.TimeoutExpired) else "error",
                      "native helper timed out" if isinstance(exc, subprocess.TimeoutExpired) else "native request interrupted",
                      {"stdout": stdout, "stderr": stderr, "forced": forced,
                       "held_inputs_released": "unconfirmed; inspect retained helper output"}) from exc


def _text(value):
    return value.decode(errors="replace") if isinstance(value, bytes) else value or ""


def decode_response(result):
    try:
        response = json.loads(result.stdout)
        if (response.get("schema_version") != 1 or response.get("status") not in STATUSES
                or not isinstance(response.get("data"), dict)):
            raise ValueError("invalid envelope")
    except (ValueError, AttributeError) as exc:
        raise Failure("error", "adapter returned invalid JSON envelope", {
            "returncode": result.returncode, "stdout": result.stdout,
            "stderr": result.stderr}) from exc
    if response["status"] != "ok":
        raise Failure(response["status"], response.get("error", "adapter failed"), response["data"])
    if result.returncode:
        raise Failure("error", "adapter exited nonzero with ok envelope", {
            "returncode": result.returncode, "response": response, "stderr": result.stderr})
    return response["data"]


@contextlib.contextmanager
def file_lock(path, timeout=10):
    with Path(path).open("a") as stream:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Failure("timed-out", f"another operation owns lock: {path}")
                time.sleep(.05)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


class Adapter:
    """OS boundary; injectable for unit tests. Does not select targets by name."""
    def __init__(self, cache=None):
        self.cache = Path(cache or Path.home() / "Library/Caches/IlliquidAgentUI/helpers")
        self.compiler_identity = None

    def compile(self, source):
        source = Path(source)
        if not source.is_file():
            raise Failure("unsupported", f"helper source unavailable: {source}")
        if platform.system() != "Darwin":
            raise Failure("unsupported", "native helper requires macOS")
        compiler = shutil.which("swiftc")
        if not compiler:
            raise Failure("unsupported", "swiftc is unavailable; select Xcode/Command Line Tools")
        if self.compiler_identity is None:
            version = subprocess_run([compiler, "--version"], 10)
            if version.returncode:
                raise Failure("error", "swiftc version discovery failed", {"stderr": version.stderr})
            self.compiler_identity = version.stdout
        source_hash = digest(source)
        key = json_hash({"source": source_hash, "compiler": compiler,
                         "version": self.compiler_identity, "machine": platform.machine(),
                         "developer_dir": os.environ.get("DEVELOPER_DIR"), "sdkroot": os.environ.get("SDKROOT"),
                         "os": platform.platform(), "flags": ["-O"]})
        self.cache.mkdir(parents=True, exist_ok=True)
        output = self.cache / (source.stem + "-" + key)
        with file_lock(self.cache / (key + ".lock"), timeout=120):
            if digest(source) != source_hash:
                raise Failure("error", "helper source changed during cache lookup; prepare helpers again")
            if output.is_file() and os.access(output, os.X_OK):
                return output
            pending = output.with_suffix(".pending")
            evidence = {"source": str(source), "source_sha256": source_hash}
            try:
                pending.unlink(missing_ok=True)
                result = subprocess_run([compiler, "-O", source, "-o", pending], 120)
                evidence.update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
                if result.returncode or digest(source) != source_hash:
                    raise Failure("error", "helper compilation failed or source changed", {
                        "stderr": result.stderr, "cache": str(self.cache)})
                pending.chmod(0o700)
                pending.replace(output)
                evidence["status"] = "ok"
            except Failure as exc:
                evidence.update(status=exc.status, error=str(exc), failure_data=exc.data)
                raise
            except OSError as exc:
                evidence.update(status="error", error=str(exc))
                raise
            except KeyboardInterrupt:
                evidence.update(status="error", error="helper compilation interrupted")
                raise
            finally:
                # Interrupted/failed compilation must never leave a reusable binary.
                pending.unlink(missing_ok=True)
                atomic_json(self.cache / (key + ".compile.json"), evidence)
        return output

    def native(self, request, timeout=15):
        helper = self.compile(HERE / "native.swift")
        # Native's internal watchdog should fire before the outer watchdog.
        request = dict(request, timeout=min(30, max(.1, timeout - .25)))
        return decode_response(native_subprocess([helper], request, timeout))

    def identity(self, pid, timeout=10):
        return self.native({"operation": "identity", "pid": pid}, timeout)

    def trace(self, command, directory, pid=None, args=None, timeout=None):
        script = HERE / "trace.py"
        if not script.is_file():
            raise Failure("unsupported", "trace.py is not available")
        timeout = TRACE_TIMEOUTS[command] if timeout is None else bounded(timeout, maximum=300)
        if timeout < TRACE_TIMEOUTS[command]:
            raise Failure("error", f"trace {command} outer timeout must be >= {TRACE_TIMEOUTS[command]} seconds to allow cleanup")
        argv = [sys.executable, script, command]
        if directory is not None:
            argv += ["--run-dir", directory]
        args = args or {}
        if command == "start":
            unknown = set(args) - {"template", "seconds"}
            if unknown:
                raise Failure("error", f"unsupported trace arguments: {sorted(unknown)}")
            argv += ["--pid", str(pid), "--template", args.get("template", "Time Profiler"),
                     "--seconds", str(bounded(args.get("seconds", 10), "seconds", 300))]
        elif command == "export":
            if set(args) - {"metrics", "require_metric"}:
                raise Failure("error", "unsupported trace export arguments")
            if args.get("metrics"):
                argv += ["--metrics"]
            required = args.get("require_metric", [])
            if not isinstance(required, list) or not all(isinstance(x, str) for x in required):
                raise Failure("error", "require_metric must be a list of metric names")
            for metric in required:
                argv += ["--require-metric", metric]
        elif args:
            raise Failure("error", "trace arguments are supported only for start")
        return decode_response(subprocess_run(argv, timeout))

    def quit(self, pid, expected, timeout=15):
        # NSRunningApplication.terminate sends a normal application termination event.
        # The existing helper addresses the PID; no bundle-name AppleScript resolution.
        helper = self.compile(ROOT / "Scripts/performance-app-control.swift")
        live = normalize_identity(self.identity(pid, min(timeout, 10)))
        if any(live.get(key) != value for key, value in expected.items()):
            raise Failure("target-lost", "target identity changed before graceful quit", live)
        result = subprocess_run([helper, str(pid), "quit"], timeout)
        if result.returncode or result.stdout.strip() != "accepted":
            raise Failure("error", "PID-targeted graceful quit was rejected", {
                "stdout": result.stdout, "stderr": result.stderr})

    def spawn(self, executable, environment, log):
        return subprocess.Popen([str(executable)], env=environment, stdout=log,
                                stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                start_new_session=True)

    def signal(self, pid, sig):
        os.kill(pid, sig)


def normalize_identity(data):
    """Retain the native start token verbatim; never replace it with host time."""
    executable = data.get("executable_path") or data.get("executable")
    start = next((data[k] for k in ("process_start_identity", "process_start", "start_identity",
                                   "start_time") if data.get(k) is not None), None)
    if data.get("alive") is not True or not executable or start in (None, "", 0):
        raise Failure("target-lost", "native helper could not establish live executable/start identity", data)
    return {"executable_path": str(Path(executable).resolve(strict=True)),
            "process_start_identity": start, "bundle_id": data.get("bundle_id")}


MISSING = object()


def resolve_path(value, path):
    """Dotted object/list path or RFC6901 JSON pointer; no eval or expressions."""
    if not isinstance(path, str):
        raise Failure("error", "assertion path must be a string")
    keys = ([p.replace("~1", "/").replace("~0", "~") for p in path[1:].split("/")]
            if path.startswith("/") else path.split(".") if path else [])
    for key in keys:
        if isinstance(value, dict):
            value = value.get(key, MISSING)
        elif isinstance(value, list) and key.isdigit() and int(key) < len(value):
            value = value[int(key)]
        else:
            return MISSING
    return value


def condition(value, spec):
    if not isinstance(spec, dict) or "path" not in spec:
        raise Failure("error", "condition requires path and op")
    actual = resolve_path(value, spec["path"])
    op = spec.get("op", "eq")
    expected = spec.get("value")
    if op not in {"eq", "ne", "exists", "gt", "gte", "lt", "lte", "contains"}:
        raise Failure("unsupported", f"unsupported assertion operator: {op}")
    if op == "exists":
        return actual is not MISSING
    if actual is MISSING:
        return False
    try:
        return {"eq": lambda: actual == expected, "ne": lambda: actual != expected,
                "gt": lambda: actual > expected, "gte": lambda: actual >= expected,
                "lt": lambda: actual < expected, "lte": lambda: actual <= expected,
                "contains": lambda: expected in actual}[op]()
    except (TypeError, ValueError):
        return False


GRIP_IDENTIFIER = "illiquid.timeline.grip"


def grip_snapshot(observation, max_age=.75):
    """Validate a correlated app snapshot; never interpret local bounds as input."""
    state = observation.get("state", {}).get("data", {})
    source, window, chrome = (state.get(k, {}) for k in ("source", "window", "chrome"))
    if not all(isinstance(x, dict) for x in (source, window, chrome)):
        raise Failure("unsupported", "diagnostic source/window/chrome snapshot unavailable")
    targets = state.get("targets", [])
    if not isinstance(targets, list):
        raise Failure("unsupported", "diagnostic targets unavailable")
    matches = [t for t in targets if isinstance(t, dict) and t.get("identifier") == GRIP_IDENTIFIER]
    if len(matches) != 1:
        raise Failure("assertion-failed", "grip diagnostic target missing or ambiguous", {"match_count": len(matches)})
    target = matches[0]
    screen = target.get("screen_geometry", {})
    if not isinstance(screen, dict) or screen.get("coordinate_space") != "quartz-global-logical-points":
        raise Failure("unsupported", "grip has no converted Quartz screen geometry")
    if (not isinstance(source.get("revision"), int) or isinstance(source["revision"], bool)
            or not source.get("url") or target.get("source_revision") != source["revision"]):
        raise Failure("assertion-failed", "grip source revision is stale or unknown")
    if (not isinstance(window.get("id"), int) or isinstance(window["id"], bool) or window["id"] <= 0
            or screen.get("window_id") != window["id"] or window.get("visible") is not True
            or window.get("key") is not True or window.get("miniaturized") is not False):
        raise Failure("assertion-failed", "grip window is stale, hidden, minimized or unfocused")
    timestamp = target.get("sampled_monotonic_ns")
    age = (time.monotonic_ns() - timestamp) / 1e9 if isinstance(timestamp, int) and not isinstance(timestamp, bool) else math.inf
    if not 0 <= age <= max_age:
        raise Failure("assertion-failed", "grip screen geometry sample expired", {"age_seconds": age if math.isfinite(age) else None})
    bounds = screen.get("bounds", {})
    if (not isinstance(bounds, dict) or not all(isinstance(bounds.get(k), (int, float))
            and not isinstance(bounds[k], bool) and math.isfinite(bounds[k]) for k in ("x", "y", "width", "height"))
            or bounds["width"] <= 0 or bounds["height"] <= 0):
        raise Failure("error", "invalid grip screen bounds")
    if not isinstance(target.get("enabled"), bool) or not isinstance(chrome.get("controls_position_locked"), bool):
        raise Failure("unsupported", "grip lock state is unknown")
    if target["enabled"] == chrome["controls_position_locked"]:
        raise Failure("assertion-failed", "grip lock state disagrees with target enabled state")
    for key in ("interaction_cancellation_revision", "controls_position_revision"):
        if not isinstance(chrome.get(key), int) or isinstance(chrome[key], bool):
            raise Failure("unsupported", "grip interaction revision unavailable")
    # Layout-only coordinates and timestamps never enter the input selector.
    pin = {"source": source, "window": {k: window.get(k) for k in
           ("id", "frame", "interface_scale", "sidebar_presented", "backing_scale", "fullscreen")},
           "screen": screen, "enabled": target["enabled"],
           "cancellation_revision": chrome["interaction_cancellation_revision"],
           "position_revision": chrome["controls_position_revision"]}
    return {"state": state, "target": target, "pin": pin,
            "point": {"x": bounds["x"] + bounds["width"] / 2,
                      "y": bounds["y"] + bounds["height"] / 2}}


class Runner:
    def __init__(self, directory=None, adapter=None):
        self.directory = Path(directory).resolve() if directory else None
        self.adapter = adapter or Adapter()
        self.manifest = None
        self.child = None

    def load(self):
        if self.manifest is None:
            if self.directory is None:
                raise Failure("error", "--run-dir is required")
            self.manifest = read_json(self.directory / "manifest.json")
            if self.manifest.get("schema_version") != 1:
                raise Failure("unsupported", "unsupported manifest schema")
        return self.manifest

    def save(self):
        atomic_json(self.directory / "manifest.json", self.manifest)

    def checked_identity(self, timeout=10):
        manifest = self.load()
        if isinstance(manifest.get("pid"), bool) or not isinstance(manifest.get("pid"), int) or manifest["pid"] <= 1:
            raise Failure("target-lost", "manifest has no safe target PID")
        live = normalize_identity(self.adapter.identity(manifest["pid"], timeout))
        for key in ("executable_path", "process_start_identity", "bundle_id"):
            if live[key] != manifest.get(key):
                raise Failure("target-lost", f"target {key} changed; refusing PID reuse", {"observed": live})
        if digest(live["executable_path"]) != manifest["executable_sha256"]:
            raise Failure("target-lost", "target executable bytes changed")
        return live

    def init_run(self, executable, bundle, bundle_id, owned, context):
        if self.directory is None:
            self.directory = ROOT / "QualificationArtifacts/AgentUI" / (
                time.strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:10])
        self.directory.mkdir(parents=True, exist_ok=False)
        self.directory.chmod(0o700)
        for name in ("artifacts", "state", "state/home", "state/tmp", "state/thumbnails"):
            (self.directory / name).mkdir(exist_ok=True)
        self.manifest = {"schema_version": 1, "run_id": self.directory.name,
                         "run_dir": str(self.directory), "pid": None, "owned": owned,
                         "executable_path": str(executable), "executable_sha256": digest(executable),
                         "process_start_identity": None, "bundle_path": str(bundle) if bundle else None,
                         "bundle_id": bundle_id, "session_token": uuid.uuid4().hex if owned else None,
                         "control_file": str(self.directory / "state/control.json") if owned else None,
                         "session_file": str(self.directory / "state/session.json") if owned else None,
                         "preferences": {"status": "unverified", "isolation_mode": None},
                         "log_file": str(self.directory / "app.log") if owned else None,
                         "environment": {"os": platform.platform(), "machine": platform.machine()},
                         "comparison_context": context or {}, "created_wall_time": time.time(),
                         "created_monotonic": time.monotonic(), "lifecycle": "preparing",
                         "limitations": LIMITATIONS}
        self.manifest["source_metadata_errors"] = []
        def source_metadata(argv, timeout):
            try:
                result = subprocess_run(argv, timeout, cwd=ROOT)
                if result.returncode:
                    self.manifest["source_metadata_errors"].append({
                        "command": argv, "status": "error", "returncode": result.returncode,
                        "stdout": result.stdout, "stderr": result.stderr})
                return result
            except Failure as exc:
                # Checkout provenance is supplementary to mandatory executable
                # and process identity. Keep partial evidence and its failure;
                # a slow checkout must not prevent inspecting a known binary.
                self.manifest["source_metadata_errors"].append({
                    "command": argv, "status": exc.status, "error": str(exc), "data": exc.data})
                return subprocess.CompletedProcess(argv, 1, exc.data.get("stdout", ""), str(exc))
        revision = source_metadata(["git", "rev-parse", "HEAD"], 5)
        patch = source_metadata(["git", "diff", "--binary", "HEAD"], 10)
        self.manifest["source_revision"] = revision.stdout.strip() if revision.returncode == 0 else None
        self.manifest["source_identity_scope"] = "runner checkout; association with packaged binary is unverified"
        self.manifest["build_flags"] = "not-provided"
        (self.directory / "artifacts/source.patch").write_text(patch.stdout)
        self.manifest["source_patch_sha256"] = digest(self.directory / "artifacts/source.patch")
        self.manifest["source_patch_complete"] = patch.returncode == 0
        self.manifest["source_patch_scope"] = "tracked checkout diff only; untracked source is not in this patch"
        self.manifest["source_provenance_complete"] = False
        self.manifest["source_provenance_incomplete_reason"] = (
            "Tracked source.patch and scoped adapter hashes omit untracked Sources and Tests/AgentUI files; "
            "no complete source inventory or association with the packaged executable has been verified.")
        self.manifest["adapter_sha256"] = {str(path.relative_to(ROOT)): digest(path)
            for path in (Path(__file__), HERE / "native.swift", HERE / "trace.py",
                         ROOT / "Scripts/performance-app-control.swift") if path.is_file()}
        self.manifest["dependency_manifests"] = {
            name: digest(ROOT / name) for name in ("Package.swift", "Package.resolved")
            if (ROOT / name).is_file()}
        self.save()

    def launch(self, args):
        app = Path(args["app"]).resolve(strict=True)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != DOMAIN:
            raise Failure("error", f"launch requires isolated benchmark bundle id {DOMAIN}")
        executable_name = info.get("CFBundleExecutable", "")
        if not executable_name or Path(executable_name).name != executable_name:
            raise Failure("error", "invalid CFBundleExecutable")
        executable = (app / "Contents/MacOS" / executable_name).resolve(strict=True)
        if not executable.is_relative_to(app) or not os.access(executable, os.X_OK):
            raise Failure("error", "bundle executable must be executable and contained in the bundle")
        timeout = bounded(args.get("timeout", 30))
        seed_bytes, seed_source, seed_values = None, None, {}
        if args.get("preferences_seed_file") is not None:
            try:
                seed_source = str(Path(args["preferences_seed_file"]).resolve(strict=True))
                with Path(seed_source).open("rb") as stream:
                    seed_bytes = stream.read(1024 * 1024 + 1)
                seed_values = preference_seed_values(seed_bytes)
            except (OSError, ValueError, RecursionError) as exc:
                raise Failure("error", f"invalid preference seed: {exc}") from exc
        # Compile/validate identity adapter before spawning a process we must own.
        if isinstance(self.adapter, Adapter):
            self.adapter.compile(HERE / "native.swift")
            self.adapter.compile(ROOT / "Scripts/performance-app-control.swift")
        self.init_run(executable, app, DOMAIN, True, args.get("context"))
        preferences = self.manifest["preferences"]
        receipt = self.directory / "artifacts/preferences.json"
        if receipt.exists() or receipt.is_symlink():
            raise Failure("error", "preference receipt must be absent before launch")
        seed_path = self.directory / "state/preferences-seed.json" if seed_bytes is not None else None
        if seed_path:
            with seed_path.open("xb") as stream:
                stream.write(seed_bytes)
        preferences.update(status="pending", suite=DOMAIN + ".AgentUI." + self.manifest["session_token"],
                           receipt_file=str(receipt), seed_path=str(seed_path) if seed_path else None,
                           seed_source=seed_source, seed_values=seed_values,
                           seed_sha256=hashlib.sha256(seed_bytes).hexdigest() if seed_bytes is not None else None)
        home = str(self.directory / "state/home")
        isolated = {
            "CFFIXED_USER_HOME": home, "TMPDIR": str(self.directory / "state/tmp") + "/",
            "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES": "1", "ILLIQUID_BENCHMARK_LIFECYCLE": "1",
            "ILLIQUID_BENCHMARK_HEARTBEAT": "0",
            "ILLIQUID_BENCHMARK_CONTROL_SESSION": self.manifest["session_token"],
            "ILLIQUID_BENCHMARK_CONTROL_FILE": self.manifest["control_file"],
            "ILLIQUID_BENCHMARK_SESSION_FILE": self.manifest["session_file"],
            "ILLIQUID_BENCHMARK_PREFERENCES_SUITE": preferences["suite"],
            "ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT": preferences["receipt_file"],
            "ILLIQUID_BENCHMARK_THUMBNAIL_CACHE": str(self.directory / "state/thumbnails"),
            # Match the production decoder selection rather than benchmark BGRA default.
            "ILLIQUID_BENCHMARK_SOFTWARE_OUTPUT": "planar",
        }
        if seed_path:
            isolated["ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE"] = str(seed_path)
        environment = {k: v for k, v in os.environ.items() if not k.startswith("ILLIQUID_")}
        environment.update(isolated)
        self.manifest["environment"]["launch_overrides"] = isolated
        self.save()
        with (self.directory / "app.log").open("ab", buffering=0) as log:
            self.child = self.adapter.spawn(executable, environment, log)
        self.manifest["pid"] = self.child.pid
        self.manifest["lifecycle"] = "starting"
        self.save()  # Preserve PID even if identity/readiness fails.
        deadline = time.monotonic() + timeout
        windows = None
        def remaining_timeout(limit):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("timed-out", "benchmark launch deadline expired; app.log retained", {
                    "last_inspection": windows})
            return min(limit, remaining)
        live = normalize_identity(self.adapter.identity(self.child.pid, remaining_timeout(10)))
        if live["executable_path"] != str(executable):
            raise Failure("target-lost", "launched executable does not match benchmark bundle", live)
        pinned_start = live["process_start_identity"]
        self.manifest["process_start_identity"] = pinned_start
        self.save()
        # NSRunningApplication can briefly have no bundle identifier before the
        # new AppKit process registers. Wait without relaxing its kernel identity.
        while live["bundle_id"] is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("timed-out", "benchmark app never registered its bundle identity")
            if self.child.poll() is not None:
                raise Failure("target-lost", "app exited before bundle registration")
            time.sleep(min(.05, remaining))
            live = normalize_identity(self.adapter.identity(self.child.pid, remaining_timeout(5)))
            if live["executable_path"] != str(executable) or live["process_start_identity"] != pinned_start:
                raise Failure("target-lost", "process changed during bundle registration", live)
        if live["executable_path"] != str(executable) or live["bundle_id"] != DOMAIN:
            raise Failure("target-lost", "launched process identity does not match benchmark bundle", live)
        self.manifest.update(live)
        self.save()
        # Do not deliver SIGUSR1 until the channel has installed its signal handler.
        activation = None
        while time.monotonic() < deadline:
            self.checked_identity(remaining_timeout(5))
            isolation_ready = self.validate_preference_receipt()
            if self.channel_ready() and isolation_ready:
                if activation is None:
                    activation = self.adapter.native({
                        "operation": "act", "action": "focus", "mode": "accessibility",
                        "pid": self.child.pid,
                        "expected_identity": {k: self.manifest[k] for k in
                                              ("executable_path", "process_start_identity")}},
                        remaining_timeout(15))
                    self.manifest["launch_activation"] = activation
                    self.save()
                try:
                    windows = self.adapter.native({
                        "operation": "inspect", "pid": self.child.pid,
                        "windows_only": True,
                        "expected_identity": {k: self.manifest[k] for k in
                                              ("executable_path", "process_start_identity")}},
                        remaining_timeout(15))
                except Failure as exc:
                    if exc.status != "timed-out":
                        raise
                    # Read-only window discovery may be temporarily unavailable
                    # during startup. Preserve and retry only
                    # this observation inside the original launch deadline.
                    windows = {"windows": [], "last_error": envelope(exc.status, exc.data, str(exc))}
                if any(window.get("visible") is True and window.get("layer", 0) == 0
                       for window in windows.get("windows", [])):
                    remaining_timeout(15)  # A late observation cannot qualify readiness.
                    break
            if self.child.poll() is not None:
                raise Failure("target-lost", "launched app exited before hook readiness")
            time.sleep(min(.1, max(0, deadline - time.monotonic())))
        else:
            raise Failure("timed-out", "benchmark channel/visible window/preference receipt never became ready; app.log retained", {
                "last_inspection": windows, "preferences": dict(preferences)})
        self.manifest["lifecycle"] = "ready"
        self.manifest["initial_windows"] = windows["windows"]
        self.save()
        return {"manifest": self.manifest, "readiness": "channel-ready-and-window-observed"}

    def validate_preference_receipt(self):
        """Only app evidence matching this owned launch can establish isolation."""
        preferences = self.manifest["preferences"]
        if preferences["status"] == "validated":
            return True
        path = Path(preferences["receipt_file"])
        if not path.exists() and not path.is_symlink():
            return False
        try:
            if path.is_symlink() or not path.is_file():
                raise ValueError("receipt must be a regular run-owned file")
            data = path.read_bytes()
            receipt = preference_json(data.decode("utf-8"))
            if not isinstance(receipt, dict):
                raise ValueError("receipt must be an object")
            if type(receipt.get("schema_version")) is not int or type(receipt.get("pid")) is not int:
                raise ValueError("receipt schema/PID must be integers")
            expected = {"schema_version": 1, "session": self.manifest["session_token"],
                        "suite": preferences["suite"], "pid": self.manifest["pid"],
                        "isolation_mode": "session-suite-only", "fallback_domains": [],
                        "seed_path": preferences["seed_path"], "seed_sha256": preferences["seed_sha256"],
                        "seed_values": preferences["seed_values"], "session_file": self.manifest["session_file"]}
            for key, value in expected.items():
                if key not in receipt or preference_json_identity(receipt[key]) != preference_json_identity(value):
                    raise ValueError(f"receipt {key} does not match owned launch")
            canonical = receipt.get("effective_initial_canonical_json")
            effective = receipt.get("effective_initial_values")
            if not isinstance(canonical, str) or not isinstance(effective, dict):
                raise ValueError("effective preference snapshot/canonical JSON is missing")
            if preference_json_identity(preference_json(canonical)) != preference_json_identity(effective):
                raise ValueError("canonical JSON does not match effective preference snapshot")
            effective_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
            if receipt.get("effective_initial_sha256") != effective_hash:
                raise ValueError("effective preference hash does not match canonical JSON")
            if preferences["seed_path"] and digest(preferences["seed_path"]) != preferences["seed_sha256"]:
                raise ValueError("retained preference seed bytes changed")
            preferences.update(status="validated", isolation_mode=receipt["isolation_mode"],
                               fallback_domains=[], receipt_sha256=hashlib.sha256(data).hexdigest(),
                               effective_initial_sha256=effective_hash,
                               effective_initial_values=effective,
                               evidence_scope="preference initialization; no live UI qualification")
            self.save()
            return True
        except (OSError, ValueError, RecursionError) as exc:
            preferences.update(status="failed", isolation_mode=None, error=str(exc))
            self.save()
            raise Failure("assertion-failed", f"invalid preference receipt: {exc}",
                          {"preferences": dict(preferences)}) from exc

    def attach(self, args):
        pid = args["pid"]
        if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
            raise Failure("error", "PID must be an integer greater than 1")
        expected = str(Path(args["executable"]).resolve(strict=True))
        live = normalize_identity(self.adapter.identity(pid))
        if live["executable_path"] != expected:
            raise Failure("target-lost", "PID executable does not match --executable", live)
        self.init_run(Path(expected), None, live["bundle_id"], False, args.get("context"))
        self.manifest.update(live, pid=pid, lifecycle="attached")
        self.save()
        return {"manifest": self.manifest, "readiness": "identity-verified; windows not yet inspected"}

    def channel_ready(self):
        log = Path(self.load().get("log_file") or self.directory / "absent.log")
        if not log.is_file():
            return False
        token = self.manifest.get("session_token")
        # Read a bounded tail; old sessions and partial lines cannot authorize a signal.
        with log.open("rb") as stream:
            stream.seek(max(0, log.stat().st_size - 1024 * 1024))
            return any(line.startswith("[benchmark-control-channel] ") and
                       dict(re.findall(r"([\w-]+)=([^ ]+)", line)).get("session") == token and
                       "phase=ready" in line.split()
                       for line in stream.read().decode(errors="replace").splitlines())

    def hook(self, args):
        manifest = self.load()
        if (not manifest.get("owned") or manifest.get("bundle_id") != DOMAIN
                or not manifest.get("session_token") or not self.channel_ready()):
            raise Failure("unsupported", "hooks require this run's ready, isolated benchmark channel")
        timeout = bounded(args.get("timeout", 15))
        payload = {k: v for k, v in args.items() if k != "timeout"}
        if not isinstance(payload.get("action"), str) or set(payload) & {"session", "id"}:
            raise Failure("error", "hook needs action; session/id are runner-owned")
        identifier = uuid.uuid4().hex
        payload.update(session=manifest["session_token"], id=identifier)
        if len(json.dumps(payload).encode()) > 4096:
            raise Failure("error", "hook payload exceeds benchmark controller's 4096 byte limit")
        self.checked_identity()
        log = Path(manifest["log_file"])
        offset = log.stat().st_size
        atomic_json(manifest["control_file"], payload)
        self.checked_identity()  # Revalidate immediately before the signal; never blindly retry.
        self.adapter.signal(manifest["pid"], signal.SIGUSR1)
        start = time.monotonic()
        deadline = start + timeout
        pending = b""
        state = None
        while time.monotonic() < deadline:
            self.checked_identity(min(5, max(.01, deadline - time.monotonic())))
            with log.open("rb") as stream:
                stream.seek(offset)
                chunk = stream.read(1024 * 1024)
                offset = stream.tell()
            pending += chunk
            lines = pending.split(b"\n")
            pending = lines.pop()
            for raw in lines:
                line = raw.decode(errors="replace")
                if line.startswith("[agent-ui-state] "):
                    try:
                        candidate = json.loads(line[len("[agent-ui-state] "):])
                    except ValueError:
                        continue
                    if candidate.get("session") == payload["session"] and candidate.get("id") == identifier:
                        state = candidate
                if not line.startswith(("[benchmark-control-channel] ", "[benchmark-control] ")):
                    continue
                fields = dict(re.findall(r"([\w-]+)=([^ ]+)", line))
                if fields.get("session") != payload["session"] or fields.get("id") != identifier:
                    continue
                if fields.get("accepted") == "no" or fields.get("phase") == "rejected":
                    raise Failure("assertion-failed", "hook rejected", {"acknowledgement": fields})
                if fields.get("accepted") == "yes" and fields.get("phase") in {"completed", "snapshot"}:
                    if payload["action"] in {"capabilities", "agent-state"} and state is None:
                        # Structured state must precede the completion line in this protocol.
                        raise Failure("unsupported", "hook acknowledged without correlated structured state")
                    structured = state.get("data", {}) if state else {}
                    if state and (state.get("schema_version") != 1 or state.get("status") != "ok"
                                  or state.get("pid") != manifest["pid"] or not isinstance(structured, dict)):
                        raise Failure("error", "invalid correlated structured hook response", {"state": state})
                    return {**structured, "mode": "app-hook", "command_id": identifier,
                            "acknowledgement": fields, "state": state,
                            "roundtrip_ms": (time.monotonic() - start) * 1000,
                            "endpoint": "command-acknowledgement; not visible presentation"}
            if len(pending) > 1024 * 1024:
                raise Failure("error", "oversized unterminated app log line")
            time.sleep(min(.05, max(0, deadline - time.monotonic())))
        raise Failure("timed-out", "no correlated hook acknowledgement; command was not retried", {
            "command_id": identifier, "state": state})

    def diagnostic_grip_drag(self, args):
        """Fresh target resolution + one real native drag + bounded outcome checks.

        Existing native input owns press/release cleanup, exact process identity,
        focus checks, route/window bounds and AX occlusion checks. This operation
        never retries input or substitutes an AX press/hook for the gesture.
        """
        allowed = {"action", "mode", "diagnostic_target", "delta", "duration", "expected_outcome", "timeout"}
        if set(args) - allowed or args.get("action") != "drag" or args.get("mode") != "input":
            raise Failure("error", "diagnostic target supports input drag with delta only")
        if args.get("diagnostic_target") != {"identifier": GRIP_IDENTIFIER}:
            raise Failure("unsupported", "unsupported diagnostic drag target")
        expected = args.get("expected_outcome", "moved")
        if expected not in {"moved", "locked"}:
            raise Failure("unsupported", "diagnostic drag supports moved/locked outcomes; mid-drag cancellation requires native helper support")
        delta = args.get("delta", {})
        if (not isinstance(delta, dict) or set(delta) != {"x", "y"}
                or not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                           and math.isfinite(v) and abs(v) <= 500 for v in delta.values())
                or not 8 <= math.hypot(delta["x"], delta["y"]) <= 500):
            raise Failure("error", "drag delta must be finite, 8..500 logical points")
        duration = bounded(args.get("duration", .6), "duration", 5)
        timeout = bounded(args.get("timeout", 10), maximum=30)
        if timeout < duration + 1:
            raise Failure("error", "drag timeout must leave at least one second for outcome observation")
        deadline = time.monotonic() + timeout
        def observe(label):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure("timed-out", "diagnostic grip deadline expired")
            response = self.execute("hook", {"action": "agent-state", "timeout": min(3, remaining)}, label)
            if response["status"] != "ok":
                raise Failure(response["status"], "diagnostic grip observation failed", response)
            return grip_snapshot(response["data"])

        before = observe("grip-resolve")
        # Separate correlated observations must agree across an event-loop turn.
        time.sleep(.05)
        current = observe("grip-confirm")
        if current["pin"] != before["pin"]:
            raise Failure("assertion-failed", "grip geometry/source/window changed before input", {
                "before": before["pin"], "current": current["pin"]})
        if before["target"]["enabled"] != (expected == "moved"):
            raise Failure("assertion-failed", "grip lock state does not match requested outcome")
        playback = before["state"].get("playback", {})
        position = playback.get("position_seconds")
        if (playback.get("pause_desired") is not True or playback.get("loading") is not False
                or playback.get("buffering") is not False or not isinstance(position, (float, int))
                or isinstance(position, bool) or not math.isfinite(position)):
            raise Failure("assertion-failed", "grip outcome requires paused, loaded, nonbuffering media with known position")
        if before["state"]["chrome"].get("interaction_pins") != []:
            raise Failure("assertion-failed", "another interaction already owns the controls")
        origin = current["point"]
        destination = {k: origin[k] + delta[k] for k in ("x", "y")}
        self.checked_identity(min(3, max(.01, deadline - time.monotonic())))
        # Recheck sample age after identity I/O, immediately before native dispatch.
        timestamp = current["target"]["sampled_monotonic_ns"]
        if (time.monotonic_ns() - timestamp) / 1e9 > .75:
            raise Failure("assertion-failed", "grip geometry expired before native dispatch")
        request = {"action": "drag", "mode": "input", "from": origin, "to": destination,
                   "duration": duration, "target": {"window_id": before["pin"]["window"]["id"]},
                   "operation": "act", "pid": self.manifest["pid"],
                   "expected_identity": {k: self.manifest[k] for k in ("executable_path", "process_start_identity")}}
        try:
            native = self.adapter.native(request, max(.1, deadline - time.monotonic()))
        except Failure as exc:
            raise Failure(exc.status, str(exc), {"before": before, "input_attempted": True,
                                                "native_failure": exc.data}) from exc
        previous = None
        last = None
        while time.monotonic() < deadline:
            try:
                after = observe("grip-outcome")
                last = after
                before_context = {k: v for k, v in before["pin"].items() if k != "screen"}
                after_context = {k: v for k, v in after["pin"].items() if k != "screen"}
                # A movement may change target bounds, never its containing root,
                # source, window, display conversion or lock/cancellation state.
                before_context["screen"] = {k: v for k, v in before["pin"]["screen"].items() if k != "bounds"}
                after_context["screen"] = {k: v for k, v in after["pin"]["screen"].items() if k != "bounds"}
                if before_context != after_context:
                    raise Failure("assertion-failed", "grip source/window/geometry context changed during drag")
                observed_position = after["state"].get("playback", {}).get("position_seconds")
                if (not isinstance(observed_position, (int, float)) or isinstance(observed_position, bool)
                        or not math.isfinite(observed_position) or abs(observed_position - position) > .1
                        or after["state"].get("playback", {}).get("pause_desired") is not True):
                    raise Failure("assertion-failed", "grip drag changed playback position or pause intent")
                released = after["state"]["chrome"].get("interaction_pins") == []
                dx, dy = (after["point"][k] - origin[k] for k in ("x", "y"))
                movement = math.hypot(dx, dy)
                passed = (movement >= 5 and dx * delta["x"] + dy * delta["y"] > 0) if expected == "moved" else movement <= 1
                if released and passed and previous == after["pin"]:
                    return {"mode": "input", "action": "drag", "diagnostic_target": args["diagnostic_target"],
                            "native": native, "from": origin, "to": destination,
                            "coordinate_space": "quartz-global-logical-points", "before": before, "after": after,
                            "outcome": expected, "outcome_verified": True, "movement_points": movement,
                            "no_seek": True, "interaction_released": True,
                            "endpoint": "input-dispatched-and-model-geometry-outcome; presentation-unverified"}
                previous = after["pin"]
            except Failure as exc:
                # Missing post-release layout may be transient. Context/seek
                # failures are final and must not be erased by a later snapshot.
                if str(exc) != "grip diagnostic target missing or ambiguous":
                    raise Failure(exc.status, str(exc), {"native": native, "before": before, "last": last, **exc.data})
            time.sleep(min(.05, max(0, deadline - time.monotonic())))
        raise Failure("assertion-failed", "grip drag outcome was not observed; input was not retried", {
            "expected_outcome": expected, "native": native, "before": before, "last": last})

    def artifact(self, name):
        path = (self.directory / "artifacts" / name).resolve()
        if not path.is_relative_to((self.directory / "artifacts").resolve()):
            raise Failure("error", "artifact path must stay inside run artifacts directory")
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            raise Failure("error", "artifact exists; choose a new output name")
        return path

    def wait(self, args):
        command = args.get("command", "inspect")
        if command not in {"inspect", "hook"}:
            raise Failure("unsupported", "wait supports inspect or read-only hook queries")
        inner = args.get("args", {})
        if not isinstance(inner, dict):
            raise Failure("error", "wait args must be an object")
        if command == "hook" and inner.get("action") not in {"agent-state", "capabilities", "snapshot", "ping"}:
            raise Failure("error", "wait may not repeat mutating hook commands")
        timeout = bounded(args.get("timeout", 15))
        interval = bounded(args.get("interval", .2), "interval", 10)
        spec = args.get("condition")
        condition({}, spec)  # Validate before executing anything.
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            last = self.execute(command, dict(inner, timeout=min(inner.get("timeout", remaining), remaining)))
            if last["status"] != "ok":
                raise Failure(last["status"], last.get("error", "wait observation failed"), {"last": last})
            if condition(last, spec):
                return {**last["data"], "wait": {"condition": spec, "observation_action_id": last["action_id"]}}
            time.sleep(min(interval, max(0, deadline - time.monotonic())))
        raise Failure("timed-out", "wait condition not observed", {"condition": spec, "last": last})

    def close(self, args):
        manifest = self.load()
        trace_result = (self.execute("trace-stop", {}) if self.manifest.get("trace_requested")
                        or (self.directory / "trace/current.json").exists()
                        else envelope(data={"recorder": "none"}))
        if trace_result["status"] != "ok":
            manifest["trace_cleanup_failure"] = trace_result
            self.save()
        if not manifest.get("owned") and not args.get("terminate_unowned"):
            manifest["lifecycle"] = "detached"
            self.save()
            if trace_result["status"] != "ok":
                raise Failure(trace_result["status"], "detached; profiler cleanup failed", {"trace_cleanup": trace_result})
            return {"detached": True, "terminated": False, "artifacts_preserved": True,
                    "trace_cleanup": trace_result}
        timeout = bounded(args.get("timeout", 15))
        # Never turn an identity error into success or signal a replacement process.
        self.checked_identity()
        self.checked_identity()
        self.adapter.quit(manifest["pid"], {k: manifest[k] for k in
                          ("executable_path", "process_start_identity", "bundle_id")}, min(timeout, 15))
        deadline = time.monotonic() + timeout
        forced = False
        while time.monotonic() < deadline:
            identity = self.adapter.identity(manifest["pid"], min(5, max(.01, deadline-time.monotonic())))
            if identity.get("alive") is False:
                if self.child is not None:
                    self.child.poll()  # Reap only our actual child if this invocation launched it.
                manifest["lifecycle"] = "closed"
                self.save()
                result = {"terminated": True, "forced": forced, "artifacts_preserved": True,
                          "trace_cleanup": trace_result}
                if trace_result["status"] != "ok":
                    raise Failure(trace_result["status"], "app closed; profiler operation failed (see trace_cleanup receipt)", result)
                return result
            self.checked_identity(min(5, max(.01, deadline-time.monotonic())))
            time.sleep(min(.1, max(0, deadline-time.monotonic())))
        if args.get("force"):
            self.checked_identity()
            self.adapter.signal(manifest["pid"], signal.SIGTERM)
            # No SIGKILL; retain evidence and require an observed exit.
            return self.finish_forced_close(trace_result)
        raise Failure("timed-out", "graceful quit did not exit; target retained (use --force for SIGTERM)")

    def finish_forced_close(self, trace_result):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            live = self.adapter.identity(self.manifest["pid"], 2)
            if live.get("alive") is False:
                self.manifest["lifecycle"] = "closed"
                self.save()
                if trace_result["status"] != "ok":
                    raise Failure(trace_result["status"], "app terminated; profiler cleanup failed", trace_result)
                return {"terminated": True, "forced": True, "artifacts_preserved": True}
            self.checked_identity(2)
            time.sleep(.1)
        raise Failure("timed-out", "SIGTERM did not produce an observed exit; no SIGKILL sent")

    def dispatch(self, command, args):
        if command == "launch":
            return self.launch(args)
        if command == "attach":
            return self.attach(args)
        if command == "doctor":
            native = self.adapter.native({"operation": "doctor"}, 15)
            try:
                trace = envelope(data=self.adapter.trace("doctor", None, timeout=TRACE_TIMEOUTS["doctor"]))
            except Failure as exc:
                trace = envelope(exc.status, exc.data, str(exc))
            tools = {}
            for name, argv in {"os": ["sw_vers"], "developer_directory": ["xcode-select", "-p"]}.items():
                try:
                    result = subprocess_run(argv, 5)
                    tools[name] = {"returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
                except Failure as exc:
                    tools[name] = envelope(exc.status, exc.data, str(exc))
            return {"native": native, "trace": trace, "tools": tools, "limitations": LIMITATIONS}
        if command == "compare":
            return compare_runs(args["baseline"], args["candidate"])
        self.load()
        if command == "assert":
            last = read_json(self.directory / "last.json")
            passed = condition(last, args)
            if not passed:
                raise Failure("assertion-failed", "condition failed", {"condition": args, "observation": last})
            return {"condition": args, "passed": True, "observed_action_id": last.get("action_id")}
        if command == "wait":
            return self.wait(args)
        if command == "hook":
            return self.hook(args)
        if command == "close":
            return self.close(args)
        if command == "run":
            return self.scenario(args)
        if command == "act" and "diagnostic_target" in args:
            return self.diagnostic_grip_drag(args)
        timeout = bounded(args.get("timeout", 15), maximum=300 if command.startswith("trace-") else 120)
        if command in {"inspect", "act", "capture"}:
            if set(args) & {"pid", "operation", "expected_identity"}:
                raise Failure("error", "pid/operation/expected_identity are runner-owned")
            if command == "act" and args.get("mode") not in {"input", "accessibility"}:
                raise Failure("error", "act requires explicit mode: input or accessibility")
            self.checked_identity(min(10, timeout))
            request = {k: v for k, v in args.items() if k != "timeout"}
            if command == "capture":
                request["output"] = str(self.artifact(request.get("output", uuid.uuid4().hex + ".png")))
            request.update(operation=command, pid=self.manifest["pid"])
            request["expected_identity"] = {k: self.manifest[k] for k in
                                            ("executable_path", "process_start_identity")}
            data = self.adapter.native(request, timeout)
            if command == "capture":
                data["output"] = request["output"]
            if command == "act":
                data["mode"] = args["mode"]
            return data
        if command in {"trace-start", "trace-stop", "trace-export"}:
            if command == "trace-start":
                self.checked_identity()
                self.manifest["trace_requested"] = True
                self.save()
            # Recorder owns and verifies its PID; export/stop work after the app exits.
            values = {k: v for k, v in args.items() if k != "timeout"}
            verb = command.removeprefix("trace-")
            trace_timeout = args.get("timeout", TRACE_TIMEOUTS[verb])
            try:
                data = self.adapter.trace(verb, self.directory, self.manifest["pid"], values, trace_timeout)
            except Failure as exc:
                if command == "trace-start":
                    cleanup = self.execute("trace-stop", {})
                    exc.data["startup_cleanup"] = cleanup
                raise
            if command == "trace-export":
                self.import_trace_metrics(data)
            return data
        raise Failure("unsupported", f"unsupported command: {command}")

    def execute(self, command, args=None, step_id=None):
        args = args or {}
        receipt_request = args
        action_id = uuid.uuid4().hex
        start = time.monotonic()
        try:
            if not isinstance(args, dict):
                raise Failure("error", "command args must be an object")
            try:
                json.dumps(args, allow_nan=False)
            except (ValueError, TypeError):
                receipt_request = {"invalid_request": repr(args)}
                raise Failure("error", "request must contain finite JSON values")
            response = envelope(data=self.dispatch(command, args))
        except Failure as exc:
            response = envelope(exc.status, exc.data, str(exc))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            response = envelope("error", error=f"{type(exc).__name__}: {exc}")
        except KeyboardInterrupt:
            response = envelope("error", error="interrupted; target and artifacts retained")
        response.update(action_id=action_id, command=command, started_monotonic=start,
                        ended_monotonic=time.monotonic(),
                        timing_scope="runner wall time including helper compilation and identity checks")
        if command == "launch" and response["status"] != "ok" and self.child is not None:
            preferences = self.manifest.get("preferences", {})
            if preferences.get("status") == "pending":
                preferences.update(status="failed", error="launch ended without a validated preference receipt")
                self.save()
            response["data"]["launch_failure_cleanup"] = self.cleanup_failed_launch()
        if self.manifest:
            response["run_id"] = self.manifest["run_id"]
            response["target"] = {key: self.manifest.get(key) for key in
                                  ("pid", "executable_path", "executable_sha256", "process_start_identity", "owned")}
            row = {"request": receipt_request, "step_id": step_id, **response}
            atomic_json(self.directory / "artifacts" / (action_id + ".json"), row)
            with (self.directory / "actions.jsonl").open("a") as stream:
                stream.write(json.dumps(row, allow_nan=False) + "\n")
            atomic_json(self.directory / "last.json", response)
        return response

    def cleanup_failed_launch(self):
        """Only the child created in this invocation can enter launch-error cleanup.

        Its Popen handle has not been reaped: PID reuse is impossible while it is
        still running. A failed identity probe is not permission to signal some
        persisted PID from another invocation. No force cleanup of attached apps.
        """
        if self.child.poll() is not None:
            return {"status": "ok", "already_exited": True, "returncode": self.child.returncode}
        outcome = {}
        if self.manifest.get("process_start_identity"):
            try:
                self.checked_identity(3)
                self.adapter.quit(self.child.pid, {k: self.manifest[k] for k in
                                  ("executable_path", "process_start_identity", "bundle_id")}, 3)
                self.child.wait(timeout=3)
                self.manifest["lifecycle"] = "closed-after-launch-failure"
                self.save()
                return {"status": "ok", "method": "graceful-quit", "returncode": self.child.returncode}
            except Failure as exc:
                outcome["graceful_error"] = envelope(exc.status, exc.data, str(exc))
                if exc.status == "target-lost":
                    observed = exc.data.get("observed", {})
                    unregistered_child = observed.get("bundle_id") is None and all(
                        observed.get(k) == self.manifest[k] for k in
                        ("executable_path", "process_start_identity"))
                    if not unregistered_child:
                        return {"status": "target-lost", "cleanup": "refused after identity mismatch", **outcome}
            except subprocess.TimeoutExpired:
                outcome["graceful_error"] = "owned child did not exit before graceful deadline"
        # Popen.poll reaps a completed child and prevents signaling its reused PID.
        if self.child.poll() is None:
            try:
                self.child.terminate()
                self.child.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired) as exc:
                outcome.update(status="timed-out", error=str(exc), cleanup="SIGTERM unconfirmed; no SIGKILL")
                self.manifest["launch_failure_cleanup"] = outcome
                self.save()
                return outcome
        self.manifest["lifecycle"] = "closed-after-launch-failure"
        self.save()
        return {"status": "ok", "method": "owned-child-SIGTERM", "returncode": self.child.returncode, **outcome}

    def scenario(self, args):
        scenario = request_json(args["scenario"])
        if self.manifest.get("scenario_sha256"):
            raise Failure("error", "run already has a scenario; use a new run to preserve prior evidence")
        metrics_spec = scenario.get("metrics", {})
        self.manifest.update(scenario_sha256=json_hash(scenario), scenario_name=scenario.get("name", "invalid-scenario"),
                             required_metrics=metrics_spec.get("required", []) if isinstance(metrics_spec, dict) else [])
        atomic_json(self.directory / "scenario.json", scenario)
        self.save()
        results = []
        failure = None
        try:
            validate_scenario(scenario)
            requires = scenario.get("requires", [])
            if requires:
                discovered = self.execute("hook", {"action": "capabilities"}, "capabilities")
                results.append(discovered)
                if discovered["status"] != "ok":
                    raise Failure(discovered["status"], "capability discovery failed", discovered)
                state = discovered["data"]
                available = state.get("capabilities", state.get("commands", []))
                if isinstance(available, dict):
                    available = [key for key, value in available.items() if value is True]
                if not isinstance(available, list) or not all(isinstance(x, str) for x in available):
                    raise Failure("unsupported", "unrecognized capability response")
                missing = sorted(set(requires) - set(available))
                if missing:
                    raise Failure("unsupported", "required capabilities unavailable", {"missing": missing})
            for step in scenario["steps"]:
                result = self.execute(step["command"], step.get("args", {}), step["id"])
                results.append(result)
                if result["status"] != "ok":
                    raise Failure(result["status"], f"scenario step {step['id']} failed", result)
                if "expect" in step:
                    if not condition(result, step["expect"]):
                        raise Failure("assertion-failed", f"expect failed at {step['id']}", {
                            "condition": step["expect"], "observation": result})
            metrics = load_metrics(self.directory)
            required = self.manifest["required_metrics"]
            missing = sorted(set(required) - set(metrics))
            if missing:
                raise Failure("unsupported", "required metrics unavailable", {"missing_metrics": missing})
        except Failure as exc:
            failure = exc
        except (OSError, ValueError, KeyError, TypeError) as exc:
            failure = Failure("error", f"{type(exc).__name__}: {exc}")
        except KeyboardInterrupt:
            failure = Failure("error", "scenario interrupted; artifacts retained")
        if failure and self.manifest.get("trace_requested"):
            failure.data["trace_cleanup"] = self.execute("trace-stop", {})
        # Never delete or replace raw trace outputs, even on failure.
        assertions = {"schema_version": 1, "status": failure.status if failure else "ok",
                      "scenario_sha256": self.manifest["scenario_sha256"], "steps": results,
                      "required_metrics": self.manifest["required_metrics"],
                      "error": str(failure) if failure else None,
                      "failure_data": failure.data if failure else None}
        atomic_json(self.directory / "assertions.json", assertions)
        if not (self.directory / "metrics.json").exists():
            atomic_json(self.directory / "metrics.json", {"schema_version": 1, "metrics": {},
                        "limitations": LIMITATIONS, "availability": "no measurements exported"})
        self.manifest["scenario_status"] = assertions["status"]
        self.save()
        report = [f"# {scenario.get('name', 'invalid-scenario')}", "", f"Status: {assertions['status']}",
                  f"Run: {self.directory}", "", "Reproduction (requires a ready run):",
                  f"    python3 Scripts/agent-ui/agent_ui.py run --run-dir NEW_RUN --scenario {self.directory / 'scenario.json'}",
                  "", f"Command receipts: {len(results)}", ""]
        if failure:
            report += [str(failure), json.dumps(failure.data, sort_keys=True), ""]
        report += LIMITATIONS
        (self.directory / "report.md").write_text("\n".join(report) + "\n")
        data = {"assertions": str(self.directory / "assertions.json"),
                "report": str(self.directory / "report.md"), "steps": len(results)}
        if failure:
            raise Failure(failure.status, str(failure), dict(failure.data, **data))
        return data

    def import_trace_metrics(self, data):
        """Normalize only the trace adapter's documented diagnostic row count."""
        if data.get("measurement_valid") is not True:
            return
        observations = data.get("metrics", {}).get("time_profile_samples", [])
        rows = {}
        for index, observation in enumerate(observations):
            value = observation.get("value")
            if (observation.get("name") != "time_profile_samples" or observation.get("unit") != "samples"
                    or not isinstance(value, int) or isinstance(value, bool) or value <= 0):
                continue
            path = Path(observation.get("artifact", "")).resolve()
            if not path.is_relative_to(self.directory) or not path.is_file():
                continue
            name = "time_profile_samples" if len(observations) == 1 else f"time_profile_samples_run_{index + 1}"
            rows[name] = {"samples": [value], "unit": "samples", "source": "xctrace-time-profile",
                          "endpoint": "exported-table-row-count; no target or interaction attribution",
                          "artifact": str(path.relative_to(self.directory)),
                          "diagnostic_only": True, "definition": observation.get("definition")}
        if rows:
            existing = self.directory / "metrics.json"
            document = read_json(existing) if existing.exists() else {"schema_version": 1, "metrics": {}}
            for name, row in rows.items():
                if name in document["metrics"]:
                    # Preserve old measurements rather than replacing a prior capture.
                    raise Failure("error", "metric already retained; use a fresh run for another cohort")
                document["metrics"][name] = row
            document["limitations"] = LIMITATIONS
            atomic_json(existing, document)


def validate_scenario(scenario):
    if scenario.get("schema_version") != 1 or not isinstance(scenario.get("name"), str):
        raise Failure("unsupported", "scenario requires schema_version:1 and name")
    steps = scenario.get("steps")
    if not isinstance(steps, list) or not 1 <= len(steps) <= 1000:
        raise Failure("error", "scenario requires 1..1000 steps")
    allowed = {"inspect", "act", "hook", "wait", "assert", "capture", "trace-start", "trace-stop", "trace-export"}
    seen = set()
    for step in steps:
        if not isinstance(step, dict) or not isinstance(step.get("id"), str) or not step["id"] or step["id"] in seen:
            raise Failure("error", "scenario step IDs must be unique nonempty strings")
        seen.add(step["id"])
        if step.get("command") not in allowed:
            raise Failure("unsupported", f"unsupported scenario command: {step.get('command')}")
        if not isinstance(step.get("args", {}), dict):
            raise Failure("error", "step args must be an object")
        if step["command"] == "act" and step.get("args", {}).get("mode") not in {"input", "accessibility"}:
            raise Failure("error", "scenario act requires explicit input/accessibility mode")
        if "expect" in step:
            condition({}, step["expect"])
    requires = scenario.get("requires", [])
    metrics = scenario.get("metrics", {})
    if not isinstance(requires, list) or not all(isinstance(x, str) for x in requires):
        raise Failure("error", "requires must be a list of capability names")
    if not isinstance(metrics, dict) or not isinstance(metrics.get("required", []), list) or not all(
            isinstance(x, str) for x in metrics.get("required", [])):
        raise Failure("error", "metrics.required must be a list of metric names")


def load_metrics(directory):
    """Accept only explicit measured quantities, never derive FPS from sample counts.

    Export schema: {schema_version:1, metrics:{name:{samples:[number,...], unit,
    endpoint, source, artifact}}}. artifact is a retained run-relative raw evidence file.
    Unknown trace exports remain available for inspection but cannot pass a metric gate.
    """
    path = Path(directory) / "metrics.json"
    if not path.exists():
        return {}
    document = read_json(path)
    if document.get("schema_version") != 1 or not isinstance(document.get("metrics"), dict):
        raise Failure("unsupported", "metrics.json does not contain the supported measurement schema")
    valid = {}
    for name, row in document["metrics"].items():
        if not isinstance(row, dict):
            continue
        samples = row.get("samples")
        if (not isinstance(samples, list) or not samples or not all(
                isinstance(x, (float, int)) and not isinstance(x, bool) and math.isfinite(x) for x in samples)):
            continue
        if not all(isinstance(row.get(k), str) and row[k] for k in ("unit", "endpoint", "source", "artifact")):
            continue
        if Path(row["artifact"]).is_absolute() or not isinstance(row.get("diagnostic_only", False), bool):
            continue
        artifact = (Path(directory) / row["artifact"]).resolve()
        if not artifact.is_relative_to(Path(directory).resolve()) or not artifact.is_file() or not artifact.stat().st_size:
            continue
        # A stack/CPU sample is never admissible as a displayed frame-rate measurement.
        if ("fps" in name.lower() or row["unit"].lower() in {"fps", "frames/s"}) and row["source"] != "presentation-timestamps":
            continue
        valid[name] = row
    return valid


def compare_runs(baseline, candidate):
    baseline, candidate = Path(baseline).resolve(), Path(candidate).resolve()
    if baseline == candidate:
        raise Failure("error", "baseline and candidate must be distinct runs")
    bm, cm = read_json(baseline / "manifest.json"), read_json(candidate / "manifest.json")
    for directory, manifest in ((baseline, bm), (candidate, cm)):
        correctness = read_json(directory / "assertions.json")
        if (manifest.get("scenario_status") != "ok" or correctness.get("status") != "ok"
                or correctness.get("scenario_sha256") != manifest.get("scenario_sha256")):
            raise Failure("assertion-failed", f"run has no passing scenario correctness receipt: {directory}")
    if not bm.get("scenario_sha256") or bm["scenario_sha256"] != cm.get("scenario_sha256"):
        raise Failure("error", "scenario hashes do not match")
    # Run-owned suite names and paths differ; their retained initialization
    # semantics must match before those transport fields may be ignored.
    preference_semantics = []
    for manifest in (bm, cm):
        preferences = manifest.get("preferences")
        if preferences is None:
            preference_semantics.append(None)  # Historical manifests retain explicit context.
            continue
        if (preferences.get("status") != "validated"
                or preferences.get("fallback_domains") != []
                or not preferences.get("isolation_mode")
                or not re.fullmatch(r"[0-9a-f]{64}", preferences.get("effective_initial_sha256", ""))):
            raise Failure("error", "comparison requires validated isolated preference initialization")
        values = preferences.get("effective_initial_values")
        if not isinstance(values, dict):
            raise Failure("error", "comparison requires retained effective preference values")
        values = dict(values)
        # The suite reservation identifies ownership, not a user preference.
        # Its unique token is retained in the receipt, but differs per launch.
        values.pop("Illiquid.agent-ui-preference-suite.v1", None)
        preference_semantics.append({"isolation_mode": preferences["isolation_mode"],
                                     "seed_sha256": preferences.get("seed_sha256"),
                                     "effective_values": preference_json_identity(values)})
    if preference_semantics[0] != preference_semantics[1]:
        raise Failure("error", "effective preference initialization differs")
    required_context = {"fixtures", "instrumentation", "display", "cache_state", "preferences"}
    context = bm.get("comparison_context", {})
    if (not required_context <= set(context) or context != cm.get("comparison_context")
            or bm.get("environment") != cm.get("environment")):
        # Per-run paths/tokens differ intentionally; compare their semantic settings below.
        def semantic_environment(manifest):
            env = dict(manifest.get("environment", {}))
            overrides = dict(env.pop("launch_overrides", {}))
            return env, {k: v for k, v in overrides.items() if k not in {
                "CFFIXED_USER_HOME", "TMPDIR", "ILLIQUID_BENCHMARK_CONTROL_SESSION",
                "ILLIQUID_BENCHMARK_CONTROL_FILE", "ILLIQUID_BENCHMARK_SESSION_FILE", "ILLIQUID_BENCHMARK_THUMBNAIL_CACHE",
                "ILLIQUID_BENCHMARK_PREFERENCES_SUITE", "ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT",
                "ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE"}}
        if (not required_context <= set(context) or context != cm.get("comparison_context")
                or semantic_environment(bm) != semantic_environment(cm)):
            raise Failure("error", "comparison requires matching fixture/instrumentation/display/cache/preferences context and environment")
    bmetrics, cmetrics = load_metrics(baseline), load_metrics(candidate)
    required = set(bm.get("required_metrics", [])) | set(cm.get("required_metrics", []))
    missing = sorted(required - (set(bmetrics) & set(cmetrics)))
    if missing or not (set(bmetrics) & set(cmetrics)):
        raise Failure("unsupported", "no matched required measurements", {"missing_metrics": missing})
    rows = {}
    for name in sorted(set(bmetrics) & set(cmetrics)):
        left, right = bmetrics[name], cmetrics[name]
        if (any(left[k] != right[k] for k in ("unit", "endpoint", "source"))
                or left.get("definition") != right.get("definition")
                or left.get("diagnostic_only", False) != right.get("diagnostic_only", False)):
            raise Failure("error", f"measurement definitions differ: {name}")
        bmean, cmean = statistics.mean(left["samples"]), statistics.mean(right["samples"])
        rows[name] = {"baseline_mean": bmean, "candidate_mean": cmean,
                      "delta": cmean - bmean, "delta_percent": (cmean / bmean - 1) * 100 if bmean else None,
                      "unit": left["unit"], "endpoint": left["endpoint"], "source": left["source"],
                      "diagnostic_only": left.get("diagnostic_only", False), "definition": left.get("definition"),
                      "baseline_count": len(left["samples"]), "candidate_count": len(right["samples"]),
                      "baseline_min": min(left["samples"]), "baseline_max": max(left["samples"]),
                      "candidate_min": min(right["samples"]), "candidate_max": max(right["samples"])}
    return {"baseline": str(baseline), "candidate": str(candidate), "metrics": rows,
            "performance_gate": "not-established", "run_count_per_build": 1,
            "limitations": LIMITATIONS + ["Single matched runs do not establish variation or tail percentiles."]}


class JSONParser(argparse.ArgumentParser):
    def error(self, message):
        raise Failure("error", message)


def parser():
    cli = JSONParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="report native permissions, session and trace availability")
    launch = commands.add_parser("launch", help="launch an already built isolated benchmark .app")
    launch.add_argument("--app", required=True)
    launch.add_argument("--run-dir", help="new directory; defaults to QualificationArtifacts/AgentUI/<id>")
    launch.add_argument("--context", help="JSON string/file with fixture, instrumentation, display, cache context")
    launch.add_argument("--preferences-seed-file", help="JSON preference seed copied byte-for-byte into the new run")
    launch.add_argument("--timeout", type=float, default=30)
    attach = commands.add_parser("attach", help="attach exact PID and executable; does not acquire process ownership")
    attach.add_argument("--pid", required=True, type=int)
    attach.add_argument("--executable", required=True)
    attach.add_argument("--run-dir")
    attach.add_argument("--context")
    for name in ("inspect", "act", "hook", "wait", "assert", "capture"):
        command = commands.add_parser(name)
        command.add_argument("--run-dir", required=True)
        command.add_argument("--request", "--args", dest="request", help="JSON object string, path, or @path")
        command.add_argument("--timeout", type=float, help="bounded operation timeout, seconds")
        if name == "hook":
            command.add_argument("--action", help="benchmark action; alternatively supply in --args")
        if name == "capture":
            command.add_argument("--output", help="new filename within this run's artifacts directory")
    trace = commands.add_parser("trace", help="bounded wrapper for trace.py")
    trace.add_argument("trace_command", choices=("start", "stop", "export"))
    trace.add_argument("--run-dir", required=True)
    trace.add_argument("--template")
    trace.add_argument("--seconds", type=float)
    trace.add_argument("--metrics", action="store_true", default=None, help="export known-schema diagnostic metrics")
    trace.add_argument("--require-metric", action="append", default=None, help="required trace metric (repeatable)")
    trace.add_argument("--timeout", type=float, help="outer deadline; minimum start=240, stop=60, export=120 seconds")
    run = commands.add_parser("run", help="execute a schema_version:1 scenario against a ready run")
    run.add_argument("--run-dir", required=True)
    run.add_argument("--scenario", required=True, help="JSON scenario string, path, or @path")
    compare = commands.add_parser("compare", help="compare passing matched runs with retained measurement evidence")
    compare.add_argument("--baseline", required=True)
    compare.add_argument("--candidate", required=True)
    close = commands.add_parser("close", help="gracefully quit owned PID; preserve all run artifacts")
    close.add_argument("--run-dir", required=True)
    close.add_argument("--timeout", type=float, default=15)
    close.add_argument("--terminate-unowned", action="store_true", help="explicitly allow quitting an attached PID")
    close.add_argument("--force", action="store_true", help="allow SIGTERM after graceful quit deadline; never SIGKILL")
    return cli


def main(argv=None):
    runner = None
    try:
        args = vars(parser().parse_args(argv))
        command = args.pop("command")
        directory = args.pop("run_dir", None)
        request = request_json(args.pop("request", None))
        request.update({k: v for k, v in args.items() if v is not None})
        if "context" in request:
            request["context"] = request_json(request["context"])
        if command == "trace":
            command = "trace-" + request.pop("trace_command")
        if command == "compare":
            directory = request["candidate"]
        runner = Runner(directory)
        if command not in {"launch", "attach", "doctor"}:
            runner.load()
            with file_lock(runner.directory / ".runner.lock"):
                # Reload after acquiring lock: another CLI may just have updated manifest.
                runner.manifest = None
                response = runner.execute(command, request)
        else:
            response = runner.execute(command, request)
    except Failure as exc:
        response = envelope(exc.status, exc.data, str(exc))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        response = envelope("error", error=f"{type(exc).__name__}: {exc}")
    except KeyboardInterrupt:
        response = envelope("error", error="interrupted; artifacts and target retained; use close --run-dir")
    if runner and runner.directory and runner.directory.is_dir():
        response.setdefault("run_dir", str(runner.directory))
    print(json.dumps(response, allow_nan=False))
    return 0 if response["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
