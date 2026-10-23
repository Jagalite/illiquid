"""Native helper tests: compile, pure fixtures/injected events, read-only protocol.

No application launch, AX action, capture, or live global input is permitted here.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "native.swift"


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "requires macOS Swift SDK")
class NativeHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="illiquid-native-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.helper = cls.directory / "native"
        compile_result = subprocess.run(
            ["swiftc", "-O", str(SOURCE), "-o", str(cls.helper)],
            capture_output=True, text=True, timeout=120,
        )
        if compile_result.returncode:
            raise AssertionError(compile_result.stderr)

    def request(self, request=None, *, raw=None):
        result = subprocess.run(
            [str(self.helper)], input=raw if raw is not None else json.dumps(request),
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(len(result.stdout.splitlines()), 1, result)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["schema_version"], 1)
        self.assertIsInstance(envelope["data"], dict)
        self.assertGreaterEqual(envelope["ended_monotonic_ns"], envelope["started_monotonic_ns"])
        self.assertEqual(result.returncode == 0, envelope["status"] == "ok", envelope)
        return envelope

    def test_core_fixtures_and_injected_event_cleanup(self):
        main = self.directory / "main.swift"
        # Swift only permits top-level statements (including inactive #if branches)
        # in main.swift when compiling multiple files. Combine verbatim sources.
        main.write_text(SOURCE.read_text() + "\n" + (HERE / "test_native_core.swift").read_text()
                        + '\ndo { try runCoreTests() } catch { fputs("\\(error)\\n", stderr); exit(1) }\n')
        executable = self.directory / "core-tests"
        result = subprocess.run(
            ["swiftc", "-D", "NATIVE_UI_TESTS", str(main), "-o", str(executable)],
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("checks passed", result.stdout)

    def test_doctor_is_read_only_and_reports_permission_booleans(self):
        envelope = self.request({"operation": "doctor", "run_id": "tests", "action_id": "doctor"})
        self.assertEqual(envelope["status"], "ok")
        self.assertEqual(envelope["run_id"], "tests")
        self.assertEqual(envelope["action_id"], "doctor")
        data = envelope["data"]
        for permission in ("accessibility", "screen_capture", "post_event"):
            self.assertIsInstance(data["permissions"][permission], bool)
        self.assertFalse(data["capabilities"]["permission_prompts"])
        self.assertFalse(data["capabilities"]["app_launch"])
        self.assertEqual(data["coordinate_space"], "quartz-global-logical-points")

    def test_identity_without_accessibility(self):
        data = self.request({"operation": "identity", "pid": os.getpid()})["data"]
        self.assertTrue(data["alive"])
        self.assertEqual(data["pid"], os.getpid())
        self.assertTrue(Path(data["executable_path"]).is_absolute())
        seconds, microseconds = data["process_start_identity"].split(":")
        self.assertGreater(int(seconds), 0)
        self.assertGreaterEqual(int(microseconds), 0)
        again = self.request({"operation": "identity", "pid": os.getpid(), "expected_identity": {
            k: data[k] for k in ("executable_path", "process_start_identity")}})
        self.assertEqual(again["status"], "ok")

    def test_identity_mismatch_is_target_lost(self):
        envelope = self.request({"operation": "identity", "pid": os.getpid(),
                                 "expected_identity": {"process_start_identity": "stale"}})
        self.assertEqual(envelope["status"], "target-lost")

    def test_window_discovery_is_explicitly_not_an_accessibility_tree(self):
        result = self.request({"operation": "inspect", "pid": os.getpid(), "windows_only": True})
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["data"]["inspection_scope"], "windows-only")
        self.assertTrue(result["data"]["truncated"])
        self.assertEqual(result["data"]["elements"], [])
        self.assertIsInstance(result["data"]["windows"], list)
        invalid = self.request({"operation": "inspect", "pid": os.getpid(), "windows_only": 1})
        self.assertEqual(invalid["status"], "error")

    def test_exited_pid_identity_reports_dead(self):
        child = subprocess.Popen(["/usr/bin/true"])
        child.wait(timeout=5)
        envelope = self.request({"operation": "identity", "pid": child.pid})
        self.assertEqual(envelope["status"], "ok")
        self.assertFalse(envelope["data"]["alive"])

    def test_unsupported_action_never_attempts_input(self):
        for action, mode in (("launch", "input"), ("drag", "accessibility"),
                             ("window", "input"), ("key", "app-hook")):
            with self.subTest(action=action, mode=mode):
                envelope = self.request({"operation": "act", "pid": os.getpid(), "action": action, "mode": mode})
                self.assertEqual(envelope["status"], "unsupported")

    def test_bad_input_is_rejected_before_any_permissions_or_events(self):
        cases = [
            {"action": "click", "mode": "input"},
            {"action": "drag", "mode": "input", "from": {"x": 0, "y": 0}},
            {"action": "type", "mode": "input", "text": 1},
            {"action": "key", "mode": "input", "key": "space", "modifiers": ["cmd", "cmd"]},
            {"action": "click", "mode": "input", "target": {"identifier": "x", "typo": "y"}},
        ]
        for fields in cases:
            with self.subTest(fields=fields):
                envelope = self.request(dict(operation="act", pid=os.getpid(), **fields))
                self.assertEqual(envelope["status"], "error")

    def test_malformed_protocol(self):
        for raw in ("", "{", "[]", "{} {}", '{"operation":"doctor","timeout":true}'):
            with self.subTest(raw=raw):
                self.assertEqual(self.request(raw=raw)["status"], "error")
        for pid in (True, 0, -1, 1.5, "1", 2**40):
            with self.subTest(pid=pid):
                self.assertEqual(self.request({"operation": "identity", "pid": pid})["status"], "error")
        self.assertEqual(self.request({"operation": "launch"})["status"], "unsupported")


if __name__ == "__main__":
    unittest.main()
