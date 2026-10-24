"""Runner contract tests. No UI input, application launch, Swift or product build."""
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "agent_ui.py"
SPEC = importlib.util.spec_from_file_location("agent_ui_runner", SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class SyntheticClock:
    """Advance runner deadlines on sleeps, independently of host scheduling/I/O."""
    strftime = staticmethod(time.strftime)
    time = staticmethod(time.time)

    def __init__(self):
        self.now = 10.0

    def monotonic(self):
        return self.now

    def monotonic_ns(self):
        return round(self.now * 1e9)

    def sleep(self, seconds):
        self.now += seconds


class FakeChild:
    pid = 424242

    def __init__(self):
        self.returncode = None
        self.terminate_calls = 0

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminate_calls += 1
        self.returncode = -signal.SIGTERM

    def wait(self, timeout):
        if self.returncode is None:
            raise subprocess.TimeoutExpired("fake-child", timeout)
        return self.returncode


class FakeAdapter:
    def __init__(self, executable):
        self.live = {"pid": FakeChild.pid, "alive": True, "executable_path": str(executable),
                     "process_start_identity": "12345:678", "bundle_id": runner.DOMAIN}
        self.native_calls = []
        self.signals = []
        self.quit_calls = []
        self.trace_calls = []
        self.environments = []
        self.child = FakeChild()
        self.inspect_results = [{"windows": [{"window_id": 9, "visible": True}], "elements": []}]
        self.fail_native = None
        self.on_signal = None
        self.ready = True
        self.quit_exits = True
        self.trace_failure = None
        self.trace_data = {}
        self.emit_preferences = True
        self.preference_transform = None
        self.preference_bytes = None

    def identity(self, pid, timeout=10):
        assert pid == self.live["pid"], "wrong PID selected"
        assert timeout > 0
        return dict(self.live)

    def native(self, request, timeout=15):
        self.native_calls.append(request)
        if self.fail_native:
            raise self.fail_native
        if request["operation"] == "inspect":
            return self.inspect_results.pop(0) if len(self.inspect_results) > 1 else self.inspect_results[0]
        if request["operation"] == "capture":
            Path(request["output"]).write_bytes(b"fake scoped capture")
        return {"delivered": True}

    def signal(self, pid, sig):
        self.signals.append((pid, sig))
        if self.on_signal:
            self.on_signal()

    def spawn(self, executable, environment, log):
        assert str(executable) == self.live["executable_path"]
        self.environments.append(environment)
        receipt_path = Path(environment["ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT"])
        assert receipt_path.is_absolute() and receipt_path.parent.is_dir()
        assert not receipt_path.exists(), "runner must supply an absent receipt path"
        if self.emit_preferences:
            seed_path = environment.get("ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE")
            seed = Path(seed_path).read_bytes() if seed_path else None
            values = json.loads(seed) if seed is not None else {}
            effective = dict(values, **{"Illiquid.agent-ui-preference-suite.v1":
                                      environment["ILLIQUID_BENCHMARK_PREFERENCES_SUITE"]})
            canonical = json.dumps(effective, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            receipt = {"schema_version": 1, "pid": self.child.pid,
                       "session": environment["ILLIQUID_BENCHMARK_CONTROL_SESSION"],
                       "suite": environment["ILLIQUID_BENCHMARK_PREFERENCES_SUITE"],
                       "isolation_mode": "session-suite-only", "fallback_domains": [],
                       "seed_path": seed_path,
                       "seed_sha256": hashlib.sha256(seed).hexdigest() if seed is not None else None,
                       "seed_values": values, "effective_initial_values": effective,
                       "effective_initial_canonical_json": canonical,
                       "effective_initial_sha256": hashlib.sha256(canonical.encode()).hexdigest(),
                       "session_file": environment["ILLIQUID_BENCHMARK_SESSION_FILE"]}
            if self.preference_transform:
                self.preference_transform(receipt)
            receipt_path.write_bytes(self.preference_bytes if self.preference_bytes is not None
                                     else json.dumps(receipt).encode())
        if self.ready:
            log.write(("[benchmark-control-channel] session=" +
                       environment["ILLIQUID_BENCHMARK_CONTROL_SESSION"] + " phase=ready\n").encode())
        return self.child

    def quit(self, pid, expected, timeout=15):
        assert all(self.live[k] == v for k, v in expected.items())
        self.quit_calls.append(pid)
        if self.quit_exits:
            self.live["alive"] = False
            self.child.returncode = 0

    def trace(self, command, directory, pid=None, args=None, timeout=None):
        self.trace_calls.append((command, directory, pid, args, timeout))
        if self.trace_failure and command == self.trace_failure[0]:
            raise self.trace_failure[1]
        return self.trace_data.copy()


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.clock = SyntheticClock()
        # Scope the clock to this runner module; subprocess tests keep real time.
        clock = patch.object(runner, "time", self.clock)
        clock.start()
        self.addCleanup(clock.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        # Source receipt collection is an OS boundary too; avoid repository I/O
        # racing other agents and keep every runner test deterministic.
        metadata = patch.object(runner, "subprocess_run", side_effect=lambda argv, timeout, **kwargs:
                                subprocess.CompletedProcess(argv, 0, "fixture-head\n" if "rev-parse" in argv else "fixture patch\n", ""))
        metadata.start()
        self.addCleanup(metadata.stop)
        self.app = self.root / "Unique Benchmark.app"
        self.executable = self.app / "Contents/MacOS/Illiquid"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"fake benchmark executable\n")
        self.executable.chmod(0o700)
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleExecutable": "Illiquid", "CFBundleIdentifier": runner.DOMAIN}))
        self.adapter = FakeAdapter(self.executable)
        self.run = runner.Runner(self.root / "run", self.adapter)

    def attach(self):
        result = self.run.execute("attach", {"pid": FakeChild.pid, "executable": str(self.executable)})
        self.assertEqual(result["status"], "ok", result)
        return result

    def launch(self):
        result = self.run.execute("launch", {"app": str(self.app), "timeout": .2})
        self.assertEqual(result["status"], "ok", result)
        return result

    def setup_hook(self, action="agent-state", state=None, accepted="yes", prefix="benchmark-control-channel"):
        self.launch()
        def respond():
            payload = runner.read_json(self.run.manifest["control_file"])
            if state is not None:
                data = {"schema_version": 1, "status": "ok", "pid": FakeChild.pid,
                        "session": payload["session"], "id": payload["id"], "data": state}
                with Path(self.run.manifest["log_file"]).open("a") as stream:
                    # Wrong id/session must never satisfy correlation.
                    stream.write('[agent-ui-state] {"session":"other","id":"other","data":{}}\n')
                    stream.write("[agent-ui-state] " + json.dumps(data) + "\n")
            with Path(self.run.manifest["log_file"]).open("a") as stream:
                stream.write(f'[{prefix}] session={payload["session"]} id={payload["id"]} '
                             f'phase=completed accepted={accepted}\n')
        self.adapter.on_signal = respond

    def grip_state(self, *, x=200, y=300, locked=False):
        return {"source": {"url": "file:///fixture/video.mp4", "revision": 7},
                "window": {"id": 9, "visible": True, "key": True, "miniaturized": False,
                           "frame": {"x": 0, "y": 0, "width": 900, "height": 600},
                           "interface_scale": .9, "sidebar_presented": False},
                "chrome": {"controls_position_locked": locked, "interaction_cancellation_revision": 1,
                           "controls_position_revision": 0, "interaction_pins": []},
                "playback": {"pause_desired": True, "position_seconds": 3.0, "loading": False, "buffering": False},
                "targets": [{"identifier": runner.GRIP_IDENTIFIER, "enabled": not locked,
                             "source_revision": 7, "sampled_monotonic_ns": self.clock.monotonic_ns(),
                             "bounds": {"x": 9999, "y": 9999, "width": 24, "height": 40},
                             "screen_geometry": {"coordinate_space": "quartz-global-logical-points",
                                                 "window_id": 9,
                                                 "bounds": {"x": x, "y": y, "width": 24, "height": 40},
                                                 "root_screen_appkit": {"x": 0, "y": 0, "width": 900, "height": 600}}}]}

    def grip_request(self, expected="moved"):
        return {"action": "drag", "mode": "input", "diagnostic_target": {"identifier": runner.GRIP_IDENTIFIER},
                "delta": {"x": 0, "y": -80}, "duration": .01, "expected_outcome": expected, "timeout": 1.1}

    def grip_observations(self, states):
        self.launch()
        retained = list(states)
        def observe(args):
            state = retained.pop(0) if len(retained) > 1 else retained[0]
            return {"state": {"data": state}}
        hook = patch.object(self.run, "hook", side_effect=observe)
        hook.start()
        self.addCleanup(hook.stop)

    def drag_calls(self):
        return [r for r in self.adapter.native_calls if r.get("action") == "drag"]

    def test_diagnostic_grip_uses_screen_center_not_local_or_ax_guess(self):
        before, after = self.grip_state(), self.grip_state(y=220)
        self.grip_observations([before, before, after, after])
        result = self.run.execute("act", self.grip_request())
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(result["data"]["movement_points"], 80)
        self.assertTrue(result["data"]["no_seek"])
        self.assertEqual(len(self.drag_calls()), 1)
        request = self.drag_calls()[0]
        self.assertEqual(request["from"], {"x": 212, "y": 320})
        self.assertEqual(request["to"], {"x": 212, "y": 240})
        self.assertEqual(request["target"], {"window_id": 9})
        self.assertEqual(request["expected_identity"]["process_start_identity"], "12345:678")
        self.assertNotIn("diagnostic_target", request)

    def test_locked_grip_delivers_real_drag_and_requires_unchanged_geometry(self):
        state = self.grip_state(locked=True)
        self.grip_observations([state])
        result = self.run.execute("act", self.grip_request("locked"))
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(result["data"]["outcome"], "locked")
        self.assertEqual(result["data"]["movement_points"], 0)
        self.assertEqual(len(self.drag_calls()), 1)

    def test_grip_refuses_stale_source_window_space_and_sample_before_input(self):
        import copy
        cases = []
        for mutate in [
            lambda s: s["targets"][0].update(source_revision=6),
            lambda s: s["targets"][0]["screen_geometry"].update(window_id=8),
            lambda s: s["targets"][0]["screen_geometry"].update(coordinate_space="swiftui-player-root-top-left-points"),
            lambda s: s["targets"][0].update(sampled_monotonic_ns=1),
            lambda s: s["window"].update(key=False),
            lambda s: s["targets"].append(copy.deepcopy(s["targets"][0])),
            lambda s: s["targets"][0]["screen_geometry"]["bounds"].update(x=float("nan")),
        ]:
            state = self.grip_state()
            mutate(state)
            cases.append(state)
        self.launch()
        for state in cases:
            with self.subTest(state=state), patch.object(self.run, "hook", return_value={"state": {"data": state}}):
                result = self.run.execute("act", self.grip_request())
                self.assertNotEqual(result["status"], "ok", result)
                self.assertEqual(self.drag_calls(), [])

    def test_grip_reconfirms_geometry_before_press_and_refuses_drift(self):
        self.grip_observations([self.grip_state(), self.grip_state(y=295)])
        result = self.run.execute("act", self.grip_request())
        self.assertEqual(result["status"], "assertion-failed", result)
        self.assertIn("changed before input", result["error"])
        self.assertEqual(self.drag_calls(), [])

    def test_grip_checks_lock_and_paused_prerequisites_before_input(self):
        self.launch()
        for change in ("locked", "playing", "loading", "interaction"):
            state = self.grip_state(locked=change == "locked")
            if change == "playing": state["playback"]["pause_desired"] = False
            if change == "loading": state["playback"]["loading"] = True
            if change == "interaction": state["chrome"]["interaction_pins"] = ["scrubbing"]
            with self.subTest(change=change), patch.object(self.run, "hook", return_value={"state": {"data": state}}):
                result = self.run.execute("act", self.grip_request())
                self.assertEqual(result["status"], "assertion-failed", result)
                self.assertEqual(self.drag_calls(), [])

    def test_grip_fails_changed_source_cancellation_seek_or_window_after_input(self):
        self.launch()
        for change in ("source", "cancellation", "seek", "window"):
            before, after = self.grip_state(), self.grip_state(y=220)
            if change == "source":
                after["source"]["revision"] = 8
                after["targets"][0]["source_revision"] = 8
            if change == "cancellation": after["chrome"]["interaction_cancellation_revision"] += 1
            if change == "seek": after["playback"]["position_seconds"] = 6.0
            if change == "window": after["window"]["frame"]["width"] = 850
            with self.subTest(change=change), patch.object(self.run, "hook", side_effect=[
                    {"state": {"data": before}}, {"state": {"data": before}}, {"state": {"data": after}}]):
                count = len(self.drag_calls())
                result = self.run.execute("act", self.grip_request())
                self.assertEqual(result["status"], "assertion-failed", result)
                self.assertEqual(len(self.drag_calls()), count + 1)
                self.assertIn("native", result["data"])

    def test_dispatched_grip_without_movement_fails_and_never_retries_input(self):
        self.grip_observations([self.grip_state()])
        # Refresh only the sample timestamp; the observed position stays fixed.
        with patch.object(self.run, "hook", side_effect=lambda args: {"state": {"data": self.grip_state()}}):
            result = self.run.execute("act", self.grip_request())
        self.assertEqual(result["status"], "assertion-failed", result)
        self.assertEqual(len(self.drag_calls()), 1)
        self.assertIn("outcome was not observed", result["error"])

    def test_grip_native_failure_preserves_cleanup_and_does_not_retry(self):
        before = self.grip_state()
        self.grip_observations([before])
        self.adapter.fail_native = runner.Failure("assertion-failed", "focus lost during drag", {
            "held_inputs_released": True, "focus_lost": True})
        result = self.run.execute("act", self.grip_request())
        self.assertEqual(result["status"], "assertion-failed", result)
        self.assertTrue(result["data"]["input_attempted"])
        self.assertTrue(result["data"]["native_failure"]["held_inputs_released"])
        self.assertEqual(len(self.drag_calls()), 1)

    def test_canceled_grip_and_raw_point_overrides_are_refused_without_input(self):
        self.launch()
        for request in (self.grip_request("canceled"), dict(self.grip_request(), to={"x": 1, "y": 2})):
            result = self.run.execute("act", request)
            self.assertNotEqual(result["status"], "ok", result)
            self.assertEqual(self.drag_calls(), [])

    def test_launch_exact_bundle_isolated_environment_and_manifest(self):
        with patch.dict(os.environ, {"HOME": "/do-not-repurpose", "ILLIQUID_BENCHMARK_FAKE": "stale",
                                    "ILLIQUID_BENCHMARK_PREFERENCES_SUITE": "shared",
                                    "ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE": "/inherited-seed",
                                    "ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT": "/inherited-receipt"}):
            response = self.launch()
        env = self.adapter.environments[0]
        self.assertEqual(env["HOME"], "/do-not-repurpose")
        self.assertNotIn("HOME", self.run.manifest["environment"]["launch_overrides"])
        self.assertEqual(env["CFFIXED_USER_HOME"], str(self.run.directory / "state/home"))
        self.assertNotIn("ILLIQUID_BENCHMARK_FAKE", env)
        self.assertEqual(env["ILLIQUID_BENCHMARK_SOFTWARE_OUTPUT"], "planar")
        self.assertEqual(response["target"]["process_start_identity"], "12345:678")
        self.assertTrue(self.run.manifest["owned"])
        self.assertEqual(self.run.manifest["executable_sha256"], runner.digest(self.executable))
        self.assertTrue((self.run.directory / "artifacts/source.patch").is_file())
        self.assertEqual(self.adapter.native_calls[0]["pid"], FakeChild.pid)
        preferences = self.run.manifest["preferences"]
        self.assertEqual(env["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"], "1")
        self.assertEqual(env["ILLIQUID_BENCHMARK_PREFERENCES_SUITE"],
                         runner.DOMAIN + ".AgentUI." + self.run.manifest["session_token"])
        self.assertEqual(env["ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT"], preferences["receipt_file"])
        self.assertNotIn("ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE", env)
        self.assertEqual(preferences["status"], "validated")
        self.assertEqual(preferences["isolation_mode"], "session-suite-only")
        self.assertIsNone(preferences["seed_sha256"])
        self.assertEqual(preferences["receipt_sha256"], runner.digest(preferences["receipt_file"]))
        self.assertEqual(runner.read_json(self.run.directory / "manifest.json")["preferences"], preferences)

    def test_preference_seed_is_copied_exactly_and_receipt_hash_is_bound(self):
        source = self.root / "reviewed-seed.json"
        seed = b'{ "Illiquid.fixture": {"unicode": "caf\\u00e9", "url": "file:///fixture/", "float": 1.0} }\n'
        source.write_bytes(seed)
        def foundation_encoding(receipt):
            canonical = receipt["effective_initial_canonical_json"].replace("/", "\\/").replace('"float":1.0', '"float":1')
            receipt.update(effective_initial_canonical_json=canonical,
                           effective_initial_sha256=hashlib.sha256(canonical.encode()).hexdigest())
        self.adapter.preference_transform = foundation_encoding
        result = self.run.execute("launch", {"app": str(self.app), "timeout": .2,
                                             "preferences_seed_file": str(source)})
        self.assertEqual(result["status"], "ok", result)
        preferences = self.run.manifest["preferences"]
        retained = Path(preferences["seed_path"])
        self.assertEqual(retained, self.run.directory / "state/preferences-seed.json")
        self.assertEqual(retained.read_bytes(), seed)
        self.assertEqual(source.read_bytes(), seed)
        self.assertEqual(preferences["seed_sha256"], hashlib.sha256(seed).hexdigest())
        self.assertEqual(self.adapter.environments[0]["ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE"], str(retained))
        receipt = runner.read_json(preferences["receipt_file"])
        self.assertEqual(preferences["effective_initial_sha256"],
                         hashlib.sha256(receipt["effective_initial_canonical_json"].encode()).hexdigest())
        self.assertNotEqual(runner.json_hash(receipt["effective_initial_values"]),
                            preferences["effective_initial_sha256"])

    def test_invalid_preference_seeds_refused_before_spawn(self):
        source = self.root / "invalid-seed.json"
        for data in (b'[]', b'{broken', b'{"Illiquid.x":null}', b'{"Illiquid.x":[null]}',
                     b'{"Shared.key":1}', b'{"Illiquid.agent-ui-preference-suite.v1":"forged"}',
                     b'{"Illiquid.x":NaN}', b'{"Illiquid.x":1,"Illiquid.x":2}', b'\xff',
                     b' ' * (1024 * 1024 + 1)):
            source.write_bytes(data)
            with self.subTest(data=data[:80]):
                result = self.run.execute("launch", {"app": str(self.app), "preferences_seed_file": str(source)})
                self.assertEqual(result["status"], "error", result)
                self.assertEqual(self.adapter.environments, [])
                self.assertFalse(self.run.directory.exists())
        result = self.run.execute("launch", {"app": str(self.app), "preferences_seed_file": str(source) + ".absent"})
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(self.adapter.environments, [])

    def test_missing_preference_receipt_never_qualifies_or_dispatches_input(self):
        self.adapter.emit_preferences = False
        result = self.run.execute("launch", {"app": str(self.app), "timeout": .01})
        self.assertEqual(result["status"], "timed-out", result)
        self.assertIn("preference receipt", result["error"])
        self.assertEqual(self.adapter.native_calls, [])
        self.assertEqual(result["data"]["launch_failure_cleanup"]["status"], "ok")
        preferences = runner.read_json(self.run.directory / "manifest.json")["preferences"]
        self.assertEqual(preferences["status"], "failed")
        self.assertIsNone(preferences["isolation_mode"])
        self.assertFalse(Path(preferences["receipt_file"]).exists())

    def test_app_preference_refusal_retains_log_and_exit_without_isolation_claim(self):
        self.adapter.emit_preferences = False
        self.adapter.ready = False
        original = self.adapter.spawn
        def refuse(executable, environment, log):
            child = original(executable, environment, log)
            log.write(b"[agent-ui-preferences] refused: invalid preference configuration\n")
            child.returncode = 78
            return child
        with patch.object(self.adapter, "spawn", side_effect=refuse):
            result = self.run.execute("launch", {"app": str(self.app), "timeout": .1})
        self.assertEqual(result["status"], "target-lost", result)
        self.assertEqual(result["data"]["launch_failure_cleanup"]["returncode"], 78)
        self.assertIn("[agent-ui-preferences] refused", (self.run.directory / "app.log").read_text())
        preferences = runner.read_json(self.run.directory / "manifest.json")["preferences"]
        self.assertEqual(preferences["status"], "failed")
        self.assertIsNone(preferences["isolation_mode"])
        self.assertEqual(self.adapter.native_calls, [])

    def test_malformed_preference_receipt_retained_and_launch_fails_closed(self):
        for index, data in enumerate((b'{broken', b'[]', b'null', b'\xff', b'{"schema_version":NaN}',
                                      b'{"schema_version":1,"schema_version":2}')):
            self.adapter = FakeAdapter(self.executable)
            self.run = runner.Runner(self.root / f"malformed-{index}", self.adapter)
            self.adapter.preference_bytes = data
            with self.subTest(data=data):
                result = self.run.execute("launch", {"app": str(self.app), "timeout": .1})
                self.assertEqual(result["status"], "assertion-failed", result)
                self.assertEqual(self.run.manifest["preferences"]["status"], "failed")
                self.assertEqual(Path(self.run.manifest["preferences"]["receipt_file"]).read_bytes(), data)
                self.assertNotEqual(self.run.manifest["lifecycle"], "ready")
                self.assertEqual(self.adapter.native_calls, [])

    def test_mismatched_preference_receipt_fields_refuse_launch_before_activation(self):
        cases = {"schema_version": True, "session": "wrong", "suite": runner.DOMAIN,
                 "pid": FakeChild.pid + 1, "isolation_mode": "shared", "fallback_domains": [runner.DOMAIN],
                 "seed_path": "/unrequested", "seed_sha256": "0" * 64, "seed_values": {"Illiquid.x": True},
                 "session_file": "/wrong-session", "effective_initial_sha256": "0" * 64,
                 "effective_initial_canonical_json": "{}", "effective_initial_values": []}
        for index, (key, value) in enumerate(cases.items()):
            self.adapter = FakeAdapter(self.executable)
            self.run = runner.Runner(self.root / f"mismatch-{index}", self.adapter)
            self.adapter.preference_transform = lambda r, k=key, v=value: r.update({k: v})
            with self.subTest(field=key):
                result = self.run.execute("launch", {"app": str(self.app), "timeout": .1})
                self.assertEqual(result["status"], "assertion-failed", result)
                self.assertEqual(self.run.manifest["preferences"]["status"], "failed")
                self.assertIsNone(self.run.manifest["preferences"]["isolation_mode"])
                self.assertEqual(self.adapter.native_calls, [])

    def test_receipt_missing_required_fields_is_not_a_default_value(self):
        for index, key in enumerate(("seed_path", "seed_sha256", "seed_values", "fallback_domains",
                                     "effective_initial_canonical_json", "session", "suite")):
            self.adapter = FakeAdapter(self.executable)
            self.run = runner.Runner(self.root / f"missing-{index}", self.adapter)
            self.adapter.preference_transform = lambda r, k=key: r.pop(k)
            with self.subTest(field=key):
                result = self.run.execute("launch", {"app": str(self.app), "timeout": .1})
                self.assertEqual(result["status"], "assertion-failed", result)
                self.assertEqual(self.adapter.native_calls, [])

    def test_attach_never_claims_preference_isolation(self):
        self.attach()
        self.assertEqual(self.run.manifest["preferences"], {"status": "unverified", "isolation_mode": None})
        self.assertEqual(self.adapter.environments, [])

    def test_launch_refuses_production_bundle_without_creating_run_or_spawn(self):
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.Illiquid", "CFBundleExecutable": "Illiquid"}))
        result = self.run.execute("launch", {"app": str(self.app)})
        self.assertEqual(result["status"], "error")
        self.assertFalse(self.run.directory.exists())
        self.assertEqual(self.adapter.environments, [])

    def test_slow_optional_checkout_metadata_keeps_failure_without_blocking_launch(self):
        with patch.object(runner, "subprocess_run", side_effect=runner.Failure(
                "timed-out", "git deadline", {"stdout": "partial checkout evidence"})):
            self.launch()
        self.assertIsNone(self.run.manifest["source_revision"])
        self.assertFalse(self.run.manifest["source_patch_complete"])
        self.assertFalse(self.run.manifest["source_provenance_complete"])
        self.assertEqual(len(self.run.manifest["source_metadata_errors"]), 2)
        self.assertEqual((self.run.directory / "artifacts/source.patch").read_text(),
                         "partial checkout evidence")
        self.assertEqual(self.run.manifest["process_start_identity"], "12345:678")

    def test_nonzero_checkout_metadata_retains_stderr_and_partial_evidence(self):
        with patch.object(runner, "subprocess_run", side_effect=lambda argv, timeout, **kwargs:
                          subprocess.CompletedProcess(argv, 128, "partial evidence", "fixture git failure")):
            self.attach()
        self.assertIsNone(self.run.manifest["source_revision"])
        self.assertFalse(self.run.manifest["source_patch_complete"])
        errors = self.run.manifest["source_metadata_errors"]
        self.assertEqual(len(errors), 2)
        self.assertTrue(all(row["returncode"] == 128 and row["stderr"] == "fixture git failure" for row in errors))
        self.assertEqual((self.run.directory / "artifacts/source.patch").read_text(), "partial evidence")

    def test_bundle_executable_cannot_escape_through_symlink(self):
        external = self.root / "other"
        external.write_bytes(b"external executable")
        external.chmod(0o700)
        self.executable.unlink()
        self.executable.symlink_to(external)
        result = self.run.execute("launch", {"app": str(self.app)})
        self.assertEqual(result["status"], "error")
        self.assertEqual(self.adapter.environments, [])

    def test_launch_permission_failure_retains_identity_and_closes_owned_child(self):
        self.adapter.fail_native = runner.Failure("permission-required", "AX unavailable")
        result = self.run.execute("launch", {"app": str(self.app), "timeout": .1})
        self.assertEqual(result["status"], "permission-required", result)
        self.assertEqual(result["data"]["launch_failure_cleanup"]["status"], "ok")
        self.assertEqual(self.adapter.quit_calls, [FakeChild.pid])
        manifest = runner.read_json(self.run.directory / "manifest.json")
        self.assertEqual(manifest["pid"], FakeChild.pid)
        self.assertTrue(manifest["owned"])
        self.assertEqual(manifest["lifecycle"], "closed-after-launch-failure")
        self.assertTrue((self.run.directory / "app.log").exists())
        self.assertEqual(runner.read_json(self.run.directory / "last.json")["status"], "permission-required")

    def test_launch_readiness_failure_attempts_only_owned_child_cleanup(self):
        self.adapter.ready = False
        self.adapter.quit_exits = False
        result = self.run.execute("launch", {"app": str(self.app), "timeout": .01})
        self.assertEqual(result["status"], "timed-out", result)
        self.assertEqual(self.adapter.child.terminate_calls, 1)
        self.assertEqual(result["data"]["launch_failure_cleanup"]["method"], "owned-child-SIGTERM")
        self.assertEqual(self.adapter.signals, [])

    def test_launch_waits_for_visible_window_after_channel_readiness(self):
        self.adapter.inspect_results = [{"windows": [{"window_id": 9, "visible": False}]},
                                        {"windows": [{"window_id": 9, "visible": True}]}]
        self.launch()
        self.assertEqual(len(self.adapter.native_calls), 3)
        self.assertEqual(self.adapter.native_calls[0]["action"], "focus")
        self.assertEqual(self.adapter.native_calls[0]["mode"], "accessibility")
        self.assertTrue(self.adapter.native_calls[1]["windows_only"])

    def test_launch_waits_for_appkit_registration_with_pinned_kernel_identity(self):
        initial = dict(self.adapter.live, bundle_id=None)
        original = self.adapter.identity
        def identify(pid, timeout=10):
            live = original(pid, timeout)
            return initial if identity.call_count == 1 else live
        with patch.object(self.adapter, "identity", side_effect=identify) as identity:
            self.launch()
        self.assertGreaterEqual(identity.call_count, 3)
        self.assertEqual(self.run.manifest["process_start_identity"], initial["process_start_identity"])

    def test_launch_refuses_pid_reuse_during_appkit_registration(self):
        initial = dict(self.adapter.live, bundle_id=None)
        replacement = dict(self.adapter.live, process_start_identity="reused")
        with patch.object(self.adapter, "identity", side_effect=lambda pid, timeout=10:
                          initial if identity.call_count == 1 else dict(replacement)) as identity:
            result = self.run.execute("launch", {"app": str(self.app), "timeout": .2})
        self.assertEqual(result["status"], "target-lost")
        self.assertEqual(self.adapter.native_calls, [])

    def test_registration_timeout_terminates_only_the_still_owned_child(self):
        self.adapter.live["bundle_id"] = None
        result = self.run.execute("launch", {"app": str(self.app), "timeout": .01})
        self.assertEqual(result["status"], "timed-out")
        self.assertEqual(result["data"]["launch_failure_cleanup"]["status"], "ok")
        self.assertEqual(self.adapter.child.terminate_calls, 1)

    def test_launch_retries_read_only_ax_timeout_within_original_deadline(self):
        original = self.adapter.native
        calls = 0
        def observe(request, timeout):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise runner.Failure("timed-out", "AX startup busy")
            return original(request, timeout)
        with patch.object(self.adapter, "native", side_effect=observe):
            self.launch()
        self.assertEqual(calls, 3)

    def test_launch_does_not_activate_after_identity_exhausts_deadline(self):
        clock = [0.0]
        calls = 0
        original = self.adapter.identity
        def identify(pid, timeout=10):
            nonlocal calls
            calls += 1
            if calls == 2:
                clock[0] = 1.0
            return original(pid, timeout)
        with patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(self.adapter, "identity", side_effect=identify):
            result = self.run.execute("launch", {"app": str(self.app), "timeout": .2})
        self.assertEqual(result["status"], "timed-out", result)
        self.assertEqual(self.adapter.native_calls, [])
        self.assertEqual(result["data"]["launch_failure_cleanup"]["status"], "ok")

    def test_launch_late_visible_window_cannot_qualify_readiness(self):
        clock = [0.0]
        original = self.adapter.native
        def observe(request, timeout):
            result = original(request, timeout)
            if request["operation"] == "inspect":
                clock[0] = 1.0
            return result
        with patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(self.adapter, "native", side_effect=observe):
            result = self.run.execute("launch", {"app": str(self.app), "timeout": .2})
        self.assertEqual(result["status"], "timed-out", result)
        self.assertNotEqual(self.run.manifest["lifecycle"], "ready")
        self.assertTrue(result["data"]["last_inspection"]["windows"][0]["visible"])

    def test_attach_requires_exact_executable(self):
        other = self.root / "wrong"
        other.write_bytes(b"wrong")
        result = self.run.execute("attach", {"pid": FakeChild.pid, "executable": str(other)})
        self.assertEqual(result["status"], "target-lost")
        self.assertFalse(self.run.directory.exists())

    def test_pid_reuse_and_changed_binary_block_input_and_close(self):
        self.attach()
        self.adapter.live["process_start_identity"] = "reused-pid"
        for command, args in (("act", {"action": "click", "mode": "input"}),
                              ("close", {"terminate_unowned": True})):
            result = self.run.execute(command, args)
            self.assertEqual(result["status"], "target-lost", result)
        self.assertEqual(self.adapter.native_calls, [])
        self.assertEqual(self.adapter.quit_calls, [])
        self.assertEqual(self.adapter.signals, [])
        self.adapter.live["process_start_identity"] = "12345:678"
        self.executable.write_bytes(b"replaced on disk")
        self.assertEqual(self.run.execute("inspect")["status"], "target-lost")

    def test_missing_start_identity_is_never_synthesized(self):
        self.adapter.live["process_start_identity"] = None
        result = self.run.execute("attach", {"pid": FakeChild.pid, "executable": str(self.executable)})
        self.assertEqual(result["status"], "target-lost")
        self.assertFalse(self.run.directory.exists())

    def test_close_attached_process_detaches_and_preserves_evidence(self):
        self.attach()
        result = self.run.execute("close")
        self.assertEqual(result["status"], "ok")
        self.assertFalse(result["data"]["terminated"])
        self.assertEqual(self.adapter.quit_calls, [])
        self.assertEqual(self.adapter.signals, [])
        self.assertTrue((self.run.directory / "actions.jsonl").is_file())

    def test_detach_stops_owned_profiler_without_quitting_attached_app(self):
        self.attach()
        self.run.execute("trace-start", {"seconds": 1})
        result = self.run.execute("close")
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual([x[0] for x in self.adapter.trace_calls], ["start", "stop"])
        self.assertEqual(self.adapter.quit_calls, [])

    def test_profiler_cleanup_unsupported_is_never_a_successful_close(self):
        self.launch()
        self.run.execute("trace-start", {"seconds": 1})
        self.adapter.trace_failure = ("stop", runner.Failure("unsupported", "recorder cleanup unavailable"))
        result = self.run.execute("close", {"timeout": .01})
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(self.adapter.quit_calls, [FakeChild.pid])
        self.assertEqual(self.run.manifest["lifecycle"], "closed")
        self.assertIn("trace_cleanup_failure", self.run.manifest)

    def test_owned_close_graceful_and_no_signal_by_name(self):
        self.launch()
        result = self.run.execute("close", {"timeout": .02})
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(self.adapter.quit_calls, [FakeChild.pid])
        self.assertEqual(self.adapter.signals, [])
        self.assertEqual(self.run.manifest["lifecycle"], "closed")
        self.assertTrue((self.run.directory / "app.log").exists())

    def test_close_does_not_force_without_explicit_option(self):
        self.launch()
        self.adapter.quit_exits = False
        result = self.run.execute("close", {"timeout": .01})
        self.assertEqual(result["status"], "timed-out")
        self.assertEqual(self.adapter.signals, [])

    def test_act_requires_mode_pins_identity_and_never_falls_back(self):
        self.attach()
        self.assertEqual(self.run.execute("act", {"action": "click"})["status"], "error")
        self.assertEqual(self.adapter.native_calls, [])
        self.adapter.fail_native = runner.Failure("unsupported", "input unavailable")
        result = self.run.execute("act", {"action": "click", "mode": "input", "target": {"identifier": "play"}})
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(len(self.adapter.native_calls), 1)
        self.assertEqual(self.adapter.native_calls[0]["mode"], "input")
        self.assertEqual(self.adapter.native_calls[0]["expected_identity"]["process_start_identity"], "12345:678")
        self.assertEqual(self.adapter.signals, [])

    def test_request_cannot_override_pid_or_identity(self):
        self.attach()
        for key in ("pid", "operation", "expected_identity"):
            self.assertEqual(self.run.execute("inspect", {key: 1})["status"], "error")
        self.assertEqual(self.adapter.native_calls, [])

    def test_capture_keeps_scoped_file_and_rejects_escape_and_overwrite(self):
        self.attach()
        result = self.run.execute("capture", {"output": "window.png"})
        self.assertEqual(result["status"], "ok")
        self.assertEqual(Path(result["data"]["output"]).parent, self.run.directory / "artifacts")
        self.assertEqual(self.run.execute("capture", {"output": "window.png"})["status"], "error")
        self.assertEqual(self.run.execute("capture", {"output": "../../outside.png"})["status"], "error")
        self.assertEqual(len(self.adapter.native_calls), 1)

    def test_hook_correlates_state_and_flattens_without_losing_envelope(self):
        self.setup_hook(state={"commands": ["capabilities", "agent-state"]})
        result = self.run.execute("hook", {"action": "capabilities"})
        self.assertEqual(result["status"], "ok", result)
        self.assertIn("agent-state", result["data"]["state"]["data"]["commands"])
        self.assertIn("agent-state", result["data"]["commands"])
        self.assertEqual(self.adapter.signals, [(FakeChild.pid, signal.SIGUSR1)])
        self.assertEqual(runner.read_json(self.run.manifest["control_file"])["id"], result["data"]["command_id"])

    def test_hook_playback_ack_uses_existing_benchmark_prefix(self):
        self.setup_hook(prefix="benchmark-control")
        result = self.run.execute("hook", {"action": "play"})
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(result["data"]["mode"], "app-hook")

    def test_hook_rejection_and_missing_state_fail(self):
        self.setup_hook(accepted="no")
        self.assertEqual(self.run.execute("hook", {"action": "play"})["status"], "assertion-failed")
        self.adapter.on_signal = lambda: None
        result = self.run.execute("hook", {"action": "play", "timeout": .01})
        self.assertEqual(result["status"], "timed-out")
        self.assertEqual(len(self.adapter.signals), 2)  # No retry of timed out input.

    def test_acknowledgement_without_required_state_is_unsupported(self):
        self.setup_hook()
        result = self.run.execute("hook", {"action": "agent-state"})
        self.assertEqual(result["status"], "unsupported", result)

    def test_hook_without_ready_channel_never_signals(self):
        self.attach()
        result = self.run.execute("hook", {"action": "agent-state"})
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(self.adapter.signals, [])

    def test_wait_observes_bounded_condition_and_preserves_last_data(self):
        self.attach()
        self.adapter.inspect_results = [{"windows": []}, {"windows": [{"window_id": 9}]}]
        result = self.run.execute("wait", {"condition": {"path": "data.windows.0", "op": "exists"},
                                          "interval": .001, "timeout": .1})
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(len(self.adapter.native_calls), 2)
        result = self.run.execute("assert", {"path": "data.windows.0.window_id", "op": "eq", "value": 9})
        self.assertEqual(result["status"], "ok", result)

    def test_wait_refuses_mutating_hook_retries(self):
        self.attach()
        result = self.run.execute("wait", {"command": "hook", "args": {"action": "play"},
                                          "condition": {"path": "data", "op": "exists"}})
        self.assertEqual(result["status"], "error")
        self.assertEqual(self.adapter.signals, [])

    def test_wait_timeout_is_failure_with_last_observation(self):
        self.attach()
        result = self.run.execute("wait", {"timeout": .01, "interval": .001,
                                          "condition": {"path": "data.absent", "op": "exists"}})
        self.assertEqual(result["status"], "timed-out")
        self.assertIn("last", result["data"])

    def test_scenario_requires_actual_app_commands_and_saves_receipts(self):
        self.setup_hook(state={"commands": ["capabilities", "agent-state"]})
        scenario = {"schema_version": 1, "name": "inspect", "requires": ["agent-state"],
                    "steps": [{"id": "inspect", "command": "inspect"},
                              {"id": "assert", "command": "assert", "args": {"path": "data.windows.0", "op": "exists"}}]}
        result = self.run.execute("run", {"scenario": scenario})
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(runner.read_json(self.run.directory / "assertions.json")["status"], "ok")
        self.assertTrue((self.run.directory / "report.md").is_file())
        self.assertEqual(self.run.execute("run", {"scenario": scenario})["status"], "error")

    def test_missing_required_metric_fails_preserves_artifacts_and_report(self):
        self.attach()
        scenario = {"schema_version": 1, "name": "capture", "steps": [
            {"id": "capture", "command": "capture", "args": {"output": "proof.png"}}],
            "metrics": {"required": ["displayed_fps"]}}
        result = self.run.execute("run", {"scenario": scenario})
        self.assertEqual(result["status"], "unsupported", result)
        self.assertEqual(result["data"]["missing_metrics"], ["displayed_fps"])
        self.assertTrue((self.run.directory / "artifacts/proof.png").is_file())
        self.assertEqual(runner.read_json(self.run.directory / "assertions.json")["status"], "unsupported")
        self.assertIn("unsupported", (self.run.directory / "report.md").read_text())

    def test_missing_capability_fails_before_scenario_input(self):
        self.setup_hook(state={"commands": ["agent-state"]})
        scenario = {"schema_version": 1, "name": "missing", "requires": ["unsupported-hook"], "steps": [
            {"id": "click", "command": "act", "args": {"action": "click", "mode": "input"}}]}
        before = len(self.adapter.native_calls)
        result = self.run.execute("run", {"scenario": scenario})
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(len(self.adapter.native_calls), before)
        self.assertTrue((self.run.directory / "assertions.json").is_file())

    def test_nonfinite_request_is_rejected_and_retained_before_input(self):
        self.attach()
        result = self.run.execute("act", {"action": "click", "mode": "input", "point": {"x": float("nan"), "y": 1}})
        self.assertEqual(result["status"], "error")
        self.assertEqual(self.adapter.native_calls, [])
        self.assertIn("finite JSON", runner.read_json(self.run.directory / "last.json")["error"])

    def test_scenario_stops_after_failed_expect(self):
        self.attach()
        scenario = {"schema_version": 1, "name": "failure", "steps": [
            {"id": "wrong", "command": "inspect", "expect": {"path": "data.windows", "op": "eq", "value": []}},
            {"id": "must-not-click", "command": "act", "args": {"action": "click", "mode": "input"}}]}
        result = self.run.execute("run", {"scenario": scenario})
        self.assertEqual(result["status"], "assertion-failed")
        self.assertEqual([r["operation"] for r in self.adapter.native_calls], ["inspect"])

    def test_scenario_unsupported_or_ambiguous_modes_never_deliver_input(self):
        self.attach()
        for step in ({"id": "bad", "command": "unknown"}, {"id": "bad", "command": "act", "args": {"action": "click"}}):
            result = self.run.execute("run", {"scenario": {"schema_version": 1, "name": "invalid", "steps": [step]}})
            self.assertNotEqual(result["status"], "ok")
        self.assertEqual(self.adapter.native_calls, [])
        self.assertEqual(runner.read_json(self.run.directory / "assertions.json")["status"], "unsupported")
        self.assertTrue((self.run.directory / "scenario.json").is_file())

    def test_trace_wrapper_budgets_start_failure_cleanup_and_export_provenance(self):
        self.attach()
        self.adapter.trace_failure = ("start", runner.Failure("timed-out", "readiness failed"))
        result = self.run.execute("trace-start", {"seconds": 1})
        self.assertEqual(result["status"], "timed-out")
        self.assertEqual([x[0] for x in self.adapter.trace_calls], ["start", "stop"])
        self.assertEqual(self.adapter.trace_calls[0][-1], runner.TRACE_TIMEOUTS["start"])
        self.assertIn("startup_cleanup", result["data"])
        self.adapter.trace_failure = None
        raw = self.run.directory / "artifacts/time-profile.xml"
        raw.write_text("<trace-query-result>retained fixture</trace-query-result>")
        self.adapter.trace_data = {"measurement_valid": True, "metrics": {"time_profile_samples": [
            {"name": "time_profile_samples", "unit": "samples", "value": 5,
             "artifact": str(raw), "definition": "valid timestamp rows, not FPS"}]}}
        result = self.run.execute("trace-export", {"metrics": True, "require_metric": ["time_profile_samples"]})
        self.assertEqual(result["status"], "ok", result)
        metrics = runner.load_metrics(self.run.directory)
        self.assertEqual(metrics["time_profile_samples"]["samples"], [5])
        self.assertTrue(metrics["time_profile_samples"]["diagnostic_only"])
        self.assertEqual(metrics["time_profile_samples"]["artifact"], "artifacts/time-profile.xml")
        self.assertNotIn("fps", metrics)


class PureAndSubprocessTests(unittest.TestCase):
    def test_conditions_missing_null_pointer_and_type_errors(self):
        value = {"data": {"list": [None, 4], "a/b": "present"}}
        self.assertTrue(runner.condition(value, {"path": "data.list.0", "op": "exists"}))
        self.assertFalse(runner.condition(value, {"path": "data.list.2", "op": "ne", "value": 0}))
        self.assertTrue(runner.condition(value, {"path": "/data/a~1b", "op": "eq", "value": "present"}))
        self.assertFalse(runner.condition(value, {"path": "data.list", "op": "gt", "value": 3}))
        with self.assertRaises(runner.Failure):
            runner.condition(value, {"path": "", "op": "eval"})

    def test_json_request_inline_file_and_non_object_rejection(self):
        self.assertEqual(runner.request_json('{"action":"click"}'), {"action": "click"})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request.json"
            path.write_text('{"path":"data.windows","op":"exists"}')
            self.assertEqual(runner.request_json("@" + str(path))["op"], "exists")
            path.write_text("[]")
            with self.assertRaises(runner.Failure):
                runner.request_json(str(path))

    def test_subprocess_deadline_retains_partial_output(self):
        start = time.monotonic()
        with self.assertRaises(runner.Failure) as raised:
            runner.subprocess_run([sys.executable, "-c", "import time; print('started', flush=True); time.sleep(5)"], .5)
        self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(raised.exception.status, "timed-out")
        self.assertIn("started", raised.exception.data["stdout"])

    def test_native_deadline_allows_helper_to_release_inputs_before_exit(self):
        # This is a plain Python child standing in for the native helper. It
        # simulates native.swift's SIGTERM cleanup; no native input is posted.
        source = "import signal,time,sys; signal.signal(signal.SIGTERM, lambda *_: (print('released',flush=True),sys.exit(0))); print('ready',flush=True); time.sleep(10)"
        with self.assertRaises(runner.Failure) as raised:
            runner.native_subprocess([sys.executable, "-c", source], {}, .5)
        self.assertEqual(raised.exception.status, "timed-out")
        self.assertFalse(raised.exception.data["forced"])
        self.assertIn("released", raised.exception.data["stdout"])

    def test_adapter_envelope_nonzero_and_malformed_never_pass(self):
        for stdout, code in (("not JSON", 0), (json.dumps(runner.envelope()), 2),
                             (json.dumps(runner.envelope("permission-required", error="permission")), 0)):
            with self.assertRaises(runner.Failure):
                runner.decode_response(subprocess.CompletedProcess([], code, stdout, "diagnostic"))

    def test_helper_compile_cache_reuses_binary_and_invalidates_changed_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "native.swift"
            source.write_text("fake swift source v1")
            adapter = runner.Adapter(root / "cache")
            compilations = []
            def fake_command(argv, timeout, **kwargs):
                if "--version" in argv:
                    return subprocess.CompletedProcess(argv, 0, "fixture-swift-version", "")
                compilations.append(argv)
                Path(argv[-1]).write_bytes(b"fake helper binary")
                return subprocess.CompletedProcess(argv, 0, "", "")
            with patch.object(runner.platform, "system", return_value="Darwin"), \
                 patch.object(runner.shutil, "which", return_value="/fixture/swiftc"), \
                 patch.object(runner, "subprocess_run", side_effect=fake_command):
                first = adapter.compile(source)
                self.assertEqual(adapter.compile(source), first)
                self.assertEqual(len(compilations), 1)
                with patch.object(runner, "digest", side_effect=[runner.digest(source), "changed-during-lock"]):
                    with self.assertRaises(runner.Failure):
                        adapter.compile(source)
                self.assertEqual(len(compilations), 1)
                source.write_text("fake swift source v2")
                self.assertNotEqual(adapter.compile(source), first)
                self.assertEqual(len(compilations), 2)
                self.assertTrue(first.exists())

    def test_failed_helper_compile_removes_partial_binary_and_retains_failure_receipt(self):
        for timed_out in (True, False):
            with self.subTest(timed_out=timed_out), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "native.swift"
                source.write_text("fake swift source")
                adapter = runner.Adapter(root / "cache")
                def fake_command(argv, timeout, **kwargs):
                    if "--version" in argv:
                        return subprocess.CompletedProcess(argv, 0, "fixture-swift-version", "")
                    Path(argv[-1]).write_bytes(b"incomplete executable")
                    if timed_out:
                        raise runner.Failure("timed-out", "compiler deadline", {"stderr": "partial diagnostic"})
                    return subprocess.CompletedProcess(argv, 1, "", "compiler failure")
                with patch.object(runner.platform, "system", return_value="Darwin"), \
                     patch.object(runner.shutil, "which", return_value="/fixture/swiftc"), \
                     patch.object(runner, "subprocess_run", side_effect=fake_command):
                    with self.assertRaises(runner.Failure) as raised:
                        adapter.compile(source)
                self.assertEqual(raised.exception.status, "timed-out" if timed_out else "error")
                self.assertEqual(list(adapter.cache.glob("*.pending")), [])
                receipts = list(adapter.cache.glob("*.compile.json"))
                self.assertEqual(len(receipts), 1)
                receipt = runner.read_json(receipts[0])
                self.assertEqual(receipt["status"], raised.exception.status)
                self.assertEqual(receipt["source_sha256"], runner.digest(source))
                if timed_out:
                    self.assertEqual(receipt["failure_data"]["stderr"], "partial diagnostic")
                else:
                    self.assertEqual(receipt["returncode"], 1)

    def test_prepare_reports_os_failure_as_one_json_envelope(self):
        spec = importlib.util.spec_from_file_location("agent_ui_prepare", SCRIPT.with_name("prepare.py"))
        prepare = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"agent_ui": runner}):
            spec.loader.exec_module(prepare)
        for construction_failure in (True, False):
            with self.subTest(construction_failure=construction_failure), \
                 patch.object(prepare, "Adapter") as adapter, patch("sys.stdout", new_callable=io.StringIO) as output:
                if construction_failure:
                    adapter.side_effect = PermissionError("cache unavailable")
                else:
                    adapter.return_value.compile.side_effect = PermissionError("cache unavailable")
                self.assertEqual(prepare.main(), 1)
                self.assertEqual(len(output.getvalue().splitlines()), 1)
                result = json.loads(output.getvalue())
                self.assertEqual(result["status"], "error")
                self.assertIn("PermissionError", result["error"])

    def test_trace_export_forwards_flags_and_enforces_outer_budget(self):
        adapter = runner.Adapter()
        result = subprocess.CompletedProcess([], 0, json.dumps(runner.envelope()), "")
        with patch.object(runner, "subprocess_run", return_value=result) as invoke:
            adapter.trace("export", Path("/fixture/run"), args={"metrics": True, "require_metric": ["time_profile_samples"]})
            argv = invoke.call_args.args[0]
            self.assertIn("--metrics", argv)
            self.assertEqual(argv[-2:], ["--require-metric", "time_profile_samples"])
            self.assertGreaterEqual(invoke.call_args.args[1], 90)
            with self.assertRaises(runner.Failure):
                adapter.trace("start", Path("/fixture/run"), 123, timeout=30)

    def test_cli_help_and_errors_are_bounded_subprocesses_without_ui(self):
        help_result = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True, timeout=5)
        self.assertEqual(help_result.returncode, 0)
        for command in ("doctor", "launch", "attach", "inspect", "act", "hook", "wait", "assert", "capture", "trace", "run", "compare", "close"):
            self.assertIn(command, help_result.stdout)
        bad = subprocess.run([sys.executable, str(SCRIPT), "act"], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(bad.returncode, 0)
        self.assertEqual(json.loads(bad.stdout)["status"], "error")
        self.assertEqual(len(bad.stdout.splitlines()), 1)

    def test_lock_contention_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.lock"
            with runner.file_lock(path):
                with self.assertRaises(runner.Failure) as raised:
                    with runner.file_lock(path, timeout=.01):
                        self.fail("lock was acquired concurrently")
                self.assertEqual(raised.exception.status, "timed-out")


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paths = [self.root / "baseline", self.root / "candidate"]
        for index, path in enumerate(self.paths):
            path.mkdir()
            (path / "raw.json").write_text("[10,12]")
            manifest = {"schema_version": 1, "scenario_sha256": "matched", "scenario_status": "ok",
                        "required_metrics": ["latency"], "environment": {"os": "same", "machine": "same"},
                        "comparison_context": {"fixtures": {"video": "abc"}, "instrumentation": "same",
                                               "display": {"refresh_hz": 60}, "cache_state": "warm",
                                               "preferences": {"fixture_hash": "test-preferences"}}}
            runner.atomic_json(path / "manifest.json", manifest)
            runner.atomic_json(path / "assertions.json", {"status": "ok", "scenario_sha256": "matched"})
            runner.atomic_json(path / "metrics.json", {"schema_version": 1, "metrics": {"latency": {
                "samples": [10 + index, 12 + index], "unit": "ms", "endpoint": "dispatch-to-model-update",
                "source": "fixture-measurement", "artifact": "raw.json"}}})

    def test_matched_comparison_has_counts_delta_and_no_regression_or_fps_claim(self):
        result = runner.compare_runs(*self.paths)
        row = result["metrics"]["latency"]
        self.assertEqual(row["delta"], 1)
        self.assertEqual(row["baseline_count"], 2)
        self.assertEqual(result["performance_gate"], "not-established")
        self.assertNotIn("p99", row)
        self.assertEqual(result["run_count_per_build"], 1)

    def test_isolated_preferences_compare_semantics_instead_of_run_paths(self):
        for index, directory in enumerate(self.paths):
            path = directory / "manifest.json"
            manifest = runner.read_json(path)
            manifest["preferences"] = {"status": "validated", "fallback_domains": [],
                "isolation_mode": "suite-only", "seed_sha256": None,
                "effective_initial_sha256": str(index) * 64,
                "effective_initial_values": {"Illiquid.agent-ui-preference-suite.v1": "suite." + str(index),
                                             "Illiquid.test": True}}
            manifest["environment"]["launch_overrides"] = {
                "ILLIQUID_BENCHMARK_PREFERENCES_SUITE": "suite." + str(index),
                "ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT": str(directory / "receipt.json")}
            runner.atomic_json(path, manifest)
        self.assertIn("latency", runner.compare_runs(*self.paths)["metrics"])
        path = self.paths[1] / "manifest.json"
        manifest = runner.read_json(path)
        manifest["preferences"]["effective_initial_values"]["Illiquid.test"] = False
        runner.atomic_json(path, manifest)
        with self.assertRaises(runner.Failure):
            runner.compare_runs(*self.paths)
        manifest["preferences"]["status"] = "pending"
        runner.atomic_json(path, manifest)
        with self.assertRaises(runner.Failure):
            runner.compare_runs(*self.paths)

    def test_missing_metric_or_failed_correctness_cannot_pass(self):
        runner.atomic_json(self.paths[1] / "metrics.json", {"schema_version": 1, "metrics": {}})
        with self.assertRaises(runner.Failure) as raised:
            runner.compare_runs(*self.paths)
        self.assertEqual(raised.exception.status, "unsupported")
        runner.atomic_json(self.paths[1] / "assertions.json", {"status": "assertion-failed"})
        with self.assertRaises(runner.Failure) as raised:
            runner.compare_runs(*self.paths)
        self.assertEqual(raised.exception.status, "assertion-failed")

    def test_mismatched_context_or_scenario_rejected(self):
        path = self.paths[1] / "manifest.json"
        manifest = runner.read_json(path)
        manifest["comparison_context"]["display"]["refresh_hz"] = 120
        runner.atomic_json(path, manifest)
        with self.assertRaises(runner.Failure):
            runner.compare_runs(*self.paths)
        manifest["scenario_sha256"] = "different"
        runner.atomic_json(path, manifest)
        with self.assertRaises(runner.Failure):
            runner.compare_runs(*self.paths)

    def test_cpu_samples_do_not_become_displayed_fps(self):
        path = self.paths[0] / "metrics.json"
        runner.atomic_json(path, {"schema_version": 1, "metrics": {"displayed_fps": {
            "samples": [60], "unit": "fps", "endpoint": "sample-count", "source": "cpu-sample",
            "artifact": "raw.json"}}})
        self.assertEqual(runner.load_metrics(self.paths[0]), {})
        with self.assertRaises(runner.Failure):
            runner.compare_runs(*self.paths)

    def test_missing_raw_evidence_and_nonfinite_measurements_are_not_zero(self):
        path = self.paths[0] / "metrics.json"
        doc = runner.read_json(path)
        doc["metrics"]["latency"]["artifact"] = "absent.json"
        runner.atomic_json(path, doc)
        self.assertEqual(runner.load_metrics(self.paths[0]), {})
        doc["metrics"]["latency"]["artifact"] = "raw.json"
        doc["metrics"]["latency"]["samples"] = [float("nan")]
        path.write_text(json.dumps(doc))
        self.assertEqual(runner.load_metrics(self.paths[0]), {})

    def test_diagnostic_measurement_label_and_definition_survive_comparison(self):
        for directory in self.paths:
            path = directory / "metrics.json"
            document = runner.read_json(path)
            document["metrics"]["latency"].update(diagnostic_only=True, definition="fixture diagnostic")
            runner.atomic_json(path, document)
        row = runner.compare_runs(*self.paths)["metrics"]["latency"]
        self.assertTrue(row["diagnostic_only"])
        self.assertEqual(row["definition"], "fixture diagnostic")
        for key, value in (("definition", "different diagnostic"), ("diagnostic_only", False)):
            with self.subTest(key=key):
                path = self.paths[1] / "metrics.json"
                document = runner.read_json(path)
                document["metrics"]["latency"].update(diagnostic_only=True, definition="fixture diagnostic")
                document["metrics"]["latency"][key] = value
                runner.atomic_json(path, document)
                with self.assertRaises(runner.Failure) as raised:
                    runner.compare_runs(*self.paths)
                self.assertEqual(raised.exception.status, "error")

    def test_measurement_artifact_must_be_run_relative(self):
        path = self.paths[0] / "metrics.json"
        document = runner.read_json(path)
        document["metrics"]["latency"]["artifact"] = str(self.paths[0] / "raw.json")
        runner.atomic_json(path, document)
        self.assertEqual(runner.load_metrics(self.paths[0]), {})


if __name__ == "__main__":
    unittest.main()
