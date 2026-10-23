"""Trace adapter tests: fake subprocesses/kernel metadata and inline XML only.

Run with python3 -B -m unittest discover -s Scripts/agent-ui/tests -p test_trace.py
No test launches xctrace, targets the user's app, or creates a background process.
"""

import contextlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("agent_ui_trace", Path(__file__).parents[1] / "trace.py")
trace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trace)

TOC = '''<?xml version="1.0"?>
<trace-toc><run number="1"><data>
<table schema="time-profile" target-pid="100"/>
<table schema="unknown-frame-schema"/>
</data></run></trace-toc>'''
PROFILE = '''<?xml version="1.0"?>
<trace-query-result><node xpath='/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'>
<schema name="time-profile"><col><mnemonic>sample-time</mnemonic>
<engineering-type>sample-time</engineering-type></col></schema>
<row><sample-time id="1" fmt="1 ms">1000000</sample-time><thread id="2"/></row>
<row><sample-time ref="1"/><thread ref="2"/></row>
<row><sample-time id="3" fmt="2 ms">2000000</sample-time><thread ref="2"/></row>
</node></trace-query-result>'''
EMPTY_PROFILE = '''<trace-query-result><node><schema name="time-profile">
<col><mnemonic>sample-time</mnemonic></col></schema></node></trace-query-result>'''
CAPABILITIES = {"executable": "/fake/xctrace", "version": "fixture",
                "templates": ["Time Profiler"], "record_supported": True,
                "export_supported": True}


def identity(pid, start="1"):
    return {"pid": pid, "start_identity": start, "executable": "/fake/" + str(pid),
            "pgid": pid, "sid": pid}


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def time(self):
        return 1000 + self.now

    def sleep(self, seconds):
        self.now += seconds


class Process:
    def __init__(self, clock, pid=200, exit_at=0.3, code=0):
        self.clock, self.pid = clock, pid
        self.exit_at, self.code = exit_at, code
        self.returncode = None

    def poll(self):
        if self.exit_at is not None and self.clock.now >= self.exit_at:
            self.returncode = self.code
        return self.returncode

    def wait(self, timeout):
        if self.poll() is not None:
            return self.returncode
        if self.exit_at is None or self.exit_at > self.clock.now + timeout:
            self.clock.sleep(timeout)
            raise subprocess.TimeoutExpired("fixture", timeout)
        self.clock.now = self.exit_at
        return self.poll()


class TraceCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.clock = Clock()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.patch(trace.time, "monotonic", self.clock.monotonic)
        self.patch(trace.time, "time", self.clock.time)
        self.patch(trace.time, "sleep", self.clock.sleep)

    def patch(self, obj, name, value=mock.DEFAULT, **kwargs):
        return self.stack.enter_context(mock.patch.object(obj, name, value, **kwargs))

    def fixture(self, name, content):
        path = self.directory / name
        path.write_text(content)
        return path

    def assert_status(self, status, call, *args, **kwargs):
        with self.assertRaises(trace.TraceError) as raised:
            call(*args, **kwargs)
        self.assertEqual(status, raised.exception.status)
        return raised.exception

    def capture(self, status="ok", cleanup=True):
        root = self.directory / "trace"
        root.mkdir()
        capture = root / ("a" * 32)
        capture.mkdir()
        request = {"schema_version": 1, "capture_id": capture.name, "run_id": "test-run",
                   "target": identity(100), "template": "Time Profiler", "seconds": 0.2,
                   "capabilities": dict(CAPABILITIES)}
        trace.save(root / "current.json", {"capture_id": capture.name})
        trace.save(capture / "request.json", request)
        if status is not None:
            trace.save(capture / "outcome.json", trace.envelope(status, {
                "cleanup_confirmed": cleanup, "measurement_valid": False}))
        return root, capture, request


class NotificationTests(TraceCase):
    def setup_notification(self, register_status=0):
        self.patch(trace.sys, "platform", "darwin")
        library = mock.Mock()

        def register(name, descriptor, flags, token):
            self.assertEqual(b"com.illiquid.test", name)
            self.assertEqual(0, flags)  # A dedicated descriptor, never NOTIFY_REUSE.
            descriptor._obj.value = 42
            token._obj.value = 17
            return register_status

        library.notify_register_file_descriptor.side_effect = register
        library.notify_cancel.return_value = 0
        self.patch(trace.ctypes, "CDLL", return_value=library)
        self.blocking = self.patch(trace.os, "set_blocking")
        self.inheritable = self.patch(trace.os, "set_inheritable")
        self.read = self.patch(trace.os, "read", side_effect=BlockingIOError)
        return library

    def test_registration_is_nonblocking_and_has_no_synthetic_initial_event(self):
        library = self.setup_notification()
        notice = trace.Notification("com.illiquid.test")
        self.blocking.assert_called_once_with(42, False)
        self.inheritable.assert_called_once_with(42, False)
        self.read.assert_not_called()
        library.notify_register_check.assert_not_called()
        self.assertFalse(notice.fired())
        self.read.assert_called_once_with(42, 4)
        notice.close()
        notice.close()
        library.notify_cancel.assert_called_once_with(17)

    def test_readiness_requires_a_complete_delivered_event(self):
        self.setup_notification()
        notice = trace.Notification("com.illiquid.test")
        self.read.side_effect = [b"\x00\x00", BlockingIOError(), b"\x00\x11"]
        self.assertFalse(notice.fired())
        self.assertFalse(notice.fired())
        self.assertTrue(notice.fired())
        self.assertEqual([mock.call(42, 4), mock.call(42, 2), mock.call(42, 2)],
                         self.read.call_args_list)
        notice.close()

    def test_registration_error_does_not_use_descriptor(self):
        library = self.setup_notification(register_status=1)
        self.assert_status("unsupported", trace.Notification, "com.illiquid.test")
        self.blocking.assert_not_called()
        library.notify_cancel.assert_not_called()

    def test_descriptor_setup_error_cancels_registered_token(self):
        library = self.setup_notification()
        self.blocking.side_effect = OSError("cannot configure descriptor")
        with self.assertRaises(OSError):
            trace.Notification("com.illiquid.test")
        library.notify_cancel.assert_called_once_with(17)

    def test_closed_descriptor_is_an_error_and_never_readiness(self):
        self.setup_notification()
        notice = trace.Notification("com.illiquid.test")
        self.read.side_effect = None
        self.read.return_value = b""
        self.assert_status("error", notice.fired)
        notice.close()

    def test_cancellation_failure_is_explicit(self):
        library = self.setup_notification()
        notice = trace.Notification("com.illiquid.test")
        library.notify_cancel.return_value = 1
        self.assert_status("error", notice.close)


class XMLTests(TraceCase):
    def test_toc_records_unknown_schemas_without_claiming_metrics(self):
        tables = trace.inspect_toc(self.fixture("toc.xml", TOC))
        self.assertEqual(["time-profile", "unknown-frame-schema"], [t["schema"] for t in tables])
        self.assertEqual([True, False], [t["metrics_supported"] for t in tables])
        self.assertEqual("100", tables[0]["attributes"]["target-pid"])

    def test_known_sample_count_and_references_are_not_fps(self):
        metric = trace.time_profile_metric(self.fixture("profile.xml", PROFILE))
        self.assertEqual(3, metric["value"])
        self.assertEqual("samples", metric["unit"])
        self.assertIn("not FPS", metric["definition"])
        self.assertIn("no interaction", metric["scope"])

    def test_empty_rows_are_failure_not_zero(self):
        self.assert_status("assertion-failed", trace.time_profile_metric,
                           self.fixture("empty.xml", EMPTY_PROFILE))

    def test_unknown_schema_layout_encoding_or_ref_is_unsupported(self):
        cases = [PROFILE.replace('name="time-profile"', 'name="hitch"'),
                 PROFILE.replace("<mnemonic>sample-time", "<mnemonic>duration"),
                 PROFILE.replace('ref="1"', 'ref="missing"'),
                 PROFILE.replace(">1000000<", ">1 ms<"),
                 PROFILE.replace('<sample-time ref="1"/>', '<duration>1</duration>'),
                 PROFILE.replace("trace-query-result", "something-else"),
                 PROFILE.replace("</trace-query-result>", "<node/></trace-query-result>")]
        for i, xml in enumerate(cases):
            with self.subTest(i=i):
                self.assert_status("unsupported", trace.time_profile_metric, self.fixture(f"bad{i}.xml", xml))

    def test_empty_malformed_entity_and_oversize_xml(self):
        for content, status in ((" ", "assertion-failed"), ("<bad", "error"),
                                ('<!DOCTYPE x [<!ENTITY x "y">]><trace-toc/>', "unsupported")):
            self.assert_status(status, trace.xml_root, self.fixture("bad.xml", content))
        self.patch(trace, "MAX_XML_BYTES", 4)
        self.assert_status("unsupported", trace.xml_root, self.fixture("large.xml", TOC))

    def test_invalid_run_or_toc_root_is_unsupported(self):
        for content in (TOC.replace('number="1"', 'number="1\' or true()"'), "<toc/>"):
            self.assert_status("unsupported", trace.inspect_toc, self.fixture("bad.xml", content))


class OwnershipTests(TraceCase):
    def test_reused_pid_changed_executable_or_group_refuses_signal(self):
        child = Process(self.clock, exit_at=None)
        kill = self.patch(trace.os, "killpg")
        for changed in (identity(200, "new-start"), {**identity(200), "executable": "/other"},
                        {**identity(200), "pgid": 300}, None):
            with self.subTest(changed=changed):
                with mock.patch.object(trace, "process_identity", return_value=changed):
                    self.assert_status("target-lost", trace.signal_child, child, identity(200), signal.SIGINT)
        kill.assert_not_called()

    def test_already_reaped_child_is_never_signalled(self):
        child = Process(self.clock, exit_at=0)
        inspect = self.patch(trace, "process_identity")
        kill = self.patch(trace.os, "killpg")
        self.assertFalse(trace.signal_child(child, identity(200), signal.SIGKILL))
        inspect.assert_not_called()
        kill.assert_not_called()

    def test_session_group_leader_is_required(self):
        child = Process(self.clock, exit_at=None)
        metadata = {**identity(200), "sid": 999}
        self.patch(trace, "process_identity", return_value=metadata)
        kill = self.patch(trace.os, "killpg")
        self.assert_status("error", trace.signal_child, child, metadata, signal.SIGINT)
        kill.assert_not_called()

    def test_bounded_escalation_reaps_child(self):
        child = Process(self.clock, exit_at=None)
        self.patch(trace, "process_identity", return_value=identity(200))
        signals = []

        def kill(pid, sig):
            signals.append((pid, sig))
            if sig == signal.SIGKILL:
                child.exit_at, child.code = self.clock.now, -9

        self.patch(trace.os, "killpg", kill)
        result = trace.finish_child(child, identity(200))
        self.assertEqual([signal.SIGINT, signal.SIGTERM, signal.SIGKILL], [s for _, s in signals])
        self.assertTrue(result["reaped"])
        self.assertTrue(result["forced"])
        self.assertEqual(-9, result["returncode"])
        self.assertLessEqual(self.clock.now, trace.FINALIZE_TIMEOUT + 2 * trace.KILL_GRACE)

    def test_unknown_cleanup_not_assumed_dead(self):
        child = Process(self.clock, exit_at=None)
        self.patch(trace, "process_identity", side_effect=PermissionError("no inspection"))
        self.patch(trace.os, "killpg")
        with self.assertRaises(PermissionError):
            trace.same_process(identity(200))

    def test_stop_is_file_only_even_with_reused_metadata(self):
        root, capture, request = self.capture(status=None)
        trace.save(capture / "recorder.json", {"process": identity(200, "old")})
        kill = self.patch(trace.os, "killpg")

        def finish(seconds):
            self.clock.sleep(seconds)
            trace.save(capture / "outcome.json", trace.envelope(data={"cleanup_confirmed": True}))

        self.patch(trace.time, "sleep", finish)
        result = trace.stop(root)
        self.assertEqual("ok", result["status"])
        self.assertEqual(request["capture_id"], trace.load(capture / "stop.request.json")["capture_id"])
        kill.assert_not_called()
        self.assertEqual(result, trace.stop(root))

    def test_stop_timeout_is_explicit_unconfirmed_cleanup(self):
        root, capture, _ = self.capture(status=None)
        exc = self.assert_status("timed-out", trace.stop, root)
        self.assertFalse(exc.data["cleanup_confirmed"])
        self.assertLessEqual(self.clock.now, trace.STOP_TIMEOUT + 0.1)

    def test_overlap_and_unconfirmed_previous_cleanup_refused(self):
        for outcome in (None, trace.envelope(data={"cleanup_confirmed": False})):
            with self.subTest(outcome=outcome):
                root = self.directory / ("active" if outcome is None else "unclean")
                root.mkdir()
                capture = root / ("b" * 32)
                capture.mkdir()
                trace.save(root / "current.json", {"capture_id": capture.name})
                trace.save(capture / "request.json", {"capture_id": capture.name})
                if outcome:
                    trace.save(capture / "outcome.json", outcome)
                popen = self.patch(trace.subprocess, "Popen")
                self.assert_status("error", trace.start, root, 100, "Time Profiler", 1)
                popen.assert_not_called()

    def test_current_pointer_cannot_escape_run(self):
        root = self.directory
        trace.save(root / "current.json", {"capture_id": "../../outside"})
        self.assert_status("error", trace.current, root)

    def test_run_lock_releases_after_failure(self):
        with trace.locked(self.directory):
            self.assert_status("error", lambda: trace.locked(self.directory).__enter__())
        with trace.locked(self.directory):
            pass


class WorkerTests(TraceCase):
    def setup_worker(self, *, fired=True, exit_at=0.3, code=0, raw=True,
                     target_lost_at=None, stop_at=None, permission=False, ignore_signals=False):
        _, capture, request = self.capture(status=None)
        child = Process(self.clock, exit_at=exit_at, code=code)
        self.signals = []

        def popen(command, **kwargs):
            self.assertTrue(kwargs["start_new_session"])
            self.assertEqual(subprocess.DEVNULL, kwargs["stdin"])
            self.assertIn("--time-limit", command)
            self.assertEqual("100", command[command.index("--attach") + 1])
            if raw:
                (capture / "recording.trace").mkdir()
            if permission:
                kwargs["stderr"].write(b"Not authorized: permission denied")
                kwargs["stderr"].flush()
            return child

        def metadata(pid):
            if pid == 100 and target_lost_at is not None and self.clock.now >= target_lost_at:
                return None
            if pid == 200 and child.poll() is not None:
                return None
            return identity(pid)

        def kill(pid, sig):
            self.signals.append((pid, sig))
            if not ignore_signals or sig == signal.SIGKILL:
                child.exit_at = self.clock.now
                child.code = 0 if sig == signal.SIGINT else -int(sig)

        owner = self

        class Notice:
            def __init__(self, name):
                owner.assertIn(request["capture_id"], name)
                self.closed = False
                owner.notice = self

            def fired(self):
                return fired() if callable(fired) else fired

            def close(self):
                self.closed = True

        def sleep(seconds):
            self.clock.sleep(seconds)
            if stop_at is not None and self.clock.now >= stop_at:
                trace.request_stop(capture, request)

        self.patch(trace.subprocess, "Popen", popen)
        self.patch(trace, "process_identity", metadata)
        self.patch(trace.os, "killpg", kill)
        self.patch(trace, "Notification", Notice)
        self.patch(trace.time, "sleep", sleep)
        return capture, child

    def test_success_has_raw_identity_exit_and_notification_receipts(self):
        capture, child = self.setup_worker()
        result = trace.record_worker(capture)
        self.assertEqual("ok", result["status"])
        self.assertEqual(0, result["data"]["returncode"])
        self.assertTrue(result["data"]["cleanup_confirmed"])
        self.assertFalse(result["data"]["measurement_valid"])
        self.assertEqual("darwin-notification", trace.load(capture / "ready.json")["source"])
        self.assertEqual(identity(200), trace.load(capture / "recorder.json")["process"])
        self.assertEqual(result, trace.load(capture / "outcome.json"))
        self.assertEqual([], self.signals)
        self.assertTrue(self.notice.closed)
        self.assertIsNotNone(child.poll())

    def test_graceful_stop_is_owned_and_reaped(self):
        capture, child = self.setup_worker(exit_at=None, stop_at=0.1)
        result = trace.record_worker(capture)
        self.assertEqual("ok", result["status"])
        self.assertTrue(result["data"]["stopped"])
        self.assertEqual([(200, signal.SIGINT)], self.signals)
        self.assertIsNotNone(child.poll())

    def test_readiness_timeout_cleans_recorder(self):
        capture, child = self.setup_worker(fired=False, exit_at=None)
        result = trace.record_worker(capture)
        self.assertEqual("timed-out", result["status"])
        self.assertFalse((capture / "ready.json").exists())
        self.assertTrue(result["data"]["cleanup_confirmed"])
        self.assertIsNotNone(child.poll())

    def test_notification_at_or_after_start_deadline_cannot_publish_readiness(self):
        capture, child = self.setup_worker(
            fired=lambda: self.clock.now >= trace.START_TIMEOUT, exit_at=None)
        result = trace.record_worker(capture)
        self.assertEqual("timed-out", result["status"])
        self.assertEqual("Tracing readiness notification did not arrive", result["error"])
        self.assertFalse((capture / "ready.json").exists())
        self.assertTrue(result["data"]["cleanup_confirmed"])
        self.assertIsNotNone(child.poll())

    def test_notification_before_start_deadline_remains_accepted(self):
        capture, _ = self.setup_worker(
            fired=lambda: self.clock.now >= trace.START_TIMEOUT - 0.2,
            exit_at=trace.START_TIMEOUT + 0.1)
        result = trace.record_worker(capture)
        self.assertEqual("ok", result["status"])
        self.assertTrue((capture / "ready.json").exists())

    def test_target_loss_cleans_only_recorder(self):
        capture, child = self.setup_worker(exit_at=None, target_lost_at=0.1)
        result = trace.record_worker(capture)
        self.assertEqual("target-lost", result["status"])
        self.assertTrue(all(pid == 200 for pid, _ in self.signals))
        self.assertIsNotNone(child.poll())

    def test_successful_recorder_exit_cannot_hide_target_loss(self):
        capture, child = self.setup_worker(exit_at=0.3, target_lost_at=0.3)
        result = trace.record_worker(capture)
        self.assertEqual("target-lost", result["status"])
        self.assertTrue(result["data"]["cleanup_confirmed"])
        self.assertFalse(result["data"]["measurement_valid"])
        self.assertEqual(0, child.poll())
        self.assertEqual([], self.signals)

    def test_exit_zero_without_readiness_is_not_success(self):
        capture, _ = self.setup_worker(fired=False)
        self.assertEqual("assertion-failed", trace.record_worker(capture)["status"])

    def test_permission_failure_preserves_stderr(self):
        capture, _ = self.setup_worker(code=1, permission=True)
        result = trace.record_worker(capture)
        self.assertEqual("permission-required", result["status"])
        self.assertIn("permission denied", (capture / "record.stderr").read_text())

    def test_missing_raw_trace_is_incomplete(self):
        capture, _ = self.setup_worker(raw=False)
        self.assertEqual("assertion-failed", trace.record_worker(capture)["status"])

    def test_recording_deadline_forces_cleanup_without_leak(self):
        capture, child = self.setup_worker(exit_at=None, ignore_signals=True)
        result = trace.record_worker(capture)
        self.assertEqual("timed-out", result["status"])
        self.assertTrue(result["data"]["cleanup"]["forced"])
        self.assertEqual(-9, child.poll())
        self.assertLess(self.clock.now, 30)

    def test_hung_stop_does_not_spend_finalization_grace_twice(self):
        capture, child = self.setup_worker(exit_at=None, stop_at=0.1, ignore_signals=True)
        result = trace.record_worker(capture)
        self.assertEqual("timed-out", result["status"])
        self.assertTrue(result["data"]["cleanup_confirmed"])
        self.assertEqual(-9, child.poll())
        self.assertLess(self.clock.now, trace.STOP_TIMEOUT)
        self.assertEqual([signal.SIGINT, signal.SIGTERM, signal.SIGKILL], [sig for _, sig in self.signals])

    def test_start_notification_error_still_reaps_child(self):
        capture, child = self.setup_worker(exit_at=None)
        self.patch(trace, "Notification", side_effect=trace.TraceError("unsupported", "no notify"))
        result = trace.record_worker(capture)
        self.assertEqual("unsupported", result["status"])
        self.assertTrue(result["data"]["cleanup_confirmed"])
        self.assertFalse((capture / "recorder.json").exists())

    def test_notification_delivery_error_still_reaps_child(self):
        def failed_delivery():
            raise OSError("notification read failed")

        capture, child = self.setup_worker(fired=failed_delivery, exit_at=None)
        result = trace.record_worker(capture)
        self.assertEqual("error", result["status"])
        self.assertIn("notification read failed", result["error"])
        self.assertTrue(result["data"]["cleanup_confirmed"])
        self.assertIsNotNone(child.poll())
        self.assertTrue(self.notice.closed)


class CommandTests(TraceCase):
    def test_discovery_uses_help_not_assumed_flags(self):
        executable = self.fixture("xctrace", "fixture")
        replies = {"find": str(executable), "version": "Xcode fixture",
                   "templates": "== Standard Templates ==\nTime Profiler\nSwiftUI\n",
                   "record-help": "--attach --template --output --time-limit --no-prompt --notify-tracing-started",
                   "export-help": "--toc --xpath --output"}
        commands = []

        def run(command, directory, name, timeout):
            commands.append(command)
            self.assertLessEqual(timeout, trace.DISCOVERY_COMMAND_TIMEOUT)
            output = self.fixture(name + ".stdout", replies[name])
            return {"status": "ok", "stdout": str(output)}

        self.patch(trace, "run_command", run)
        result = trace.discover(self.directory)
        self.assertTrue(result["record_supported"])
        self.assertTrue(result["export_supported"])
        self.assertEqual(["Time Profiler", "SwiftUI"], result["templates"])
        self.assertFalse(result["live_profile_validated"])
        self.assertFalse(any("record" in command and "help" not in command for command in commands))
        replies["record-help"] = "--attach --template --output"
        self.assertFalse(trace.discover(self.directory)["record_supported"])

    def test_load_sensitive_discovery_has_30_second_commands_and_60_total_no_retry(self):
        executable = self.fixture("xctrace", "fixture")
        timeouts, calls = [], []

        def run(command, directory, name, timeout):
            calls.append(name)
            timeouts.append(timeout)
            # find/version cost 1 second each; templates costs 25 seconds.
            self.clock.sleep(25 if name == "templates" else 1)
            content = str(executable) if name == "find" else "Time Profiler" if name == "templates" else "fixture"
            return {"status": "ok", "stdout": str(self.fixture(name + ".stdout", content))}

        self.patch(trace, "run_command", run)
        result = trace.discover(self.directory)
        self.assertEqual(["find", "version", "templates", "record-help", "export-help"], calls)
        self.assertEqual(30, timeouts[2])
        self.assertLessEqual(sum((25, 1, 1, 1, 1)), trace.DISCOVERY_TIMEOUT)
        self.assertEqual(60, result["timeouts"]["discovery_total"])
        self.assertEqual(110, result["timeouts"]["recommended_outer"]["start"])

    def test_discovery_deadline_reduces_remaining_command_budget(self):
        executable = self.fixture("xctrace", "fixture")
        calls = []

        def run(command, directory, name, timeout):
            calls.append((name, timeout))
            self.clock.sleep(timeout)
            return {"status": "ok", "stdout": str(self.fixture(name + ".stdout", str(executable)))}

        self.patch(trace, "run_command", run)
        self.assert_status("timed-out", trace.discover, self.directory, deadline=40)
        self.assertEqual([("find", 30), ("version", 10)], calls)
        self.assertEqual(40, self.clock.now)

    def test_command_timeout_escalates_and_retains_raw_receipt(self):
        child = Process(self.clock, exit_at=None)
        self.patch(trace.subprocess, "Popen", return_value=child)
        self.patch(trace, "process_identity", return_value=identity(200))

        def kill(pid, sig):
            child.exit_at, child.code = self.clock.now, -int(sig)

        self.patch(trace.os, "killpg", kill)
        result = trace.run_command(["/fake/tool", "export"], self.directory, "command", 0.2)
        self.assertEqual("timed-out", result["status"])
        self.assertTrue(result["reaped"])
        self.assertEqual(result, trace.load(self.directory / "command.receipt.json"))
        self.assertTrue(Path(result["stdout"]).exists())
        self.assertTrue(Path(result["stderr"]).exists())

    def test_launch_failure_has_raw_receipt(self):
        self.patch(trace.subprocess, "Popen", side_effect=FileNotFoundError("no tool"))
        result = trace.run_command(["/missing"], self.directory, "missing")
        self.assertEqual("error", result["status"])
        self.assertIn("no tool", trace.load(self.directory / "missing.receipt.json")["error"])

    def test_identity_inspection_failure_still_cleans_unreaped_owned_child(self):
        child = Process(self.clock, exit_at=None)
        self.patch(trace.subprocess, "Popen", return_value=child)
        self.patch(trace, "process_identity", side_effect=PermissionError("metadata unavailable"))
        self.patch(trace.os, "getpgid", return_value=200)
        self.patch(trace.os, "getsid", return_value=200)

        def kill(pid, sig):
            child.exit_at, child.code = self.clock.now, -int(sig)

        self.patch(trace.os, "killpg", kill)
        result = trace.run_command(["/fake/tool"], self.directory, "identity-error")
        self.assertEqual("error", result["status"])
        self.assertTrue(result["cleanup"]["reaped"])
        self.assertIsNotNone(child.poll())

    def test_cli_invalid_arguments_and_missing_state_are_json_nonzero(self):
        for args in (["start"], ["export", "--run-dir", str(self.directory)],
                     ["start", "--run-dir", str(self.directory), "--pid", "x"]):
            with self.subTest(args=args):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    code = trace.main(args)
                result = json.loads(out.getvalue())
                self.assertEqual(1, code)
                self.assertEqual("error", result["status"])
                self.assertEqual(1, result["schema_version"])
                self.assertIn("monotonic", result["data"]["started"])

    def test_seconds_must_be_positive_finite_bounded(self):
        for seconds in (0, -1, math.nan, math.inf, trace.MAX_SECONDS + 1):
            with self.subTest(seconds=seconds):
                self.assert_status("error", trace.start, self.directory, 100, "Time Profiler", seconds)


class StartTests(TraceCase):
    def setup_start(self, mode="ready"):
        root = self.directory / "trace"
        root.mkdir()
        self.patch(trace.sys, "platform", "darwin")
        self.patch(trace, "discover", return_value=dict(CAPABILITIES))
        self.patch(trace, "process_identity", side_effect=lambda pid: identity(pid))
        owner = self

        class Supervisor(Process):
            def wait(self, timeout):
                capture, request = trace.current(root)
                owner.assertTrue((capture / "stop.request.json").exists())
                trace.save(capture / "outcome.json", trace.envelope("error", {
                    "cleanup_confirmed": True, "measurement_valid": False}))
                self.exit_at = owner.clock.now
                return self.poll()

        def popen(command, **kwargs):
            self.assertEqual("_record", command[-2])
            self.assertTrue(kwargs["start_new_session"])
            self.assertTrue(kwargs["close_fds"])
            capture, _ = trace.current(root)
            supervisor = Supervisor(self.clock, pid=300, exit_at=None)
            if mode == "ready":
                trace.save(capture / "ready.json", {"source": "darwin-notification", "recorder": identity(200)})
            elif mode == "early-exit":
                trace.save(capture / "outcome.json", trace.envelope("error", {
                    "cleanup_confirmed": True, "measurement_valid": False}, "fixture failed"))
                supervisor.exit_at = 0
            return supervisor

        self.patch(trace.subprocess, "Popen", popen)
        return root

    def test_start_returns_only_confirmed_ready_and_persists_target(self):
        root = self.setup_start()
        result = trace.start(root, 100, "Time Profiler", 5)
        self.assertEqual("darwin-notification", result["ready"]["source"])
        capture, request = trace.current(root)
        self.assertEqual(identity(100), request["target"])
        self.assertFalse(result["measurement_valid"])
        self.assertFalse((capture / "stop.request.json").exists())
        self.assertEqual(5, request["seconds"])

    def test_start_binds_to_runner_manifest_identity(self):
        root = self.setup_start()
        target = identity(100)
        trace.save(root.parent / "manifest.json", {
            "run_id": "pinned-run", "pid": target["pid"],
            "process_start_identity": target["start_identity"],
            "executable_path": target["executable"],
        })
        result = trace.start(root, 100, "Time Profiler", 5)
        self.assertEqual("pinned-run", result["run_id"])

    def test_start_refuses_replacement_or_incomplete_runner_identity_before_discovery(self):
        root = self.setup_start()
        target = identity(100)
        valid = {"pid": 100, "process_start_identity": target["start_identity"],
                 "executable_path": target["executable"]}
        for field, replacement in (("pid", 101), ("process_start_identity", "reused"),
                                   ("executable_path", "/another-app"),
                                   ("process_start_identity", None)):
            with self.subTest(field=field, replacement=replacement):
                trace.save(root.parent / "manifest.json", dict(valid, **{field: replacement}))
                self.assert_status("target-lost", trace.start, root, 100, "Time Profiler", 5)
                trace.discover.assert_not_called()
                self.assertFalse((root / "current.json").exists())

    def test_present_non_object_manifest_cannot_bypass_pinned_identity(self):
        root = self.setup_start()
        for manifest in (None, [], 1, "invalid"):
            with self.subTest(manifest=manifest):
                trace.save(root.parent / "manifest.json", manifest)
                self.assert_status("target-lost", trace.start, root, 100, "Time Profiler", 5)
                trace.discover.assert_not_called()
                self.assertFalse((root / "current.json").exists())

    def test_start_timeout_requests_and_waits_for_cleanup(self):
        root = self.setup_start(mode="no-ready")
        self.assert_status("timed-out", trace.start, root, 100, "Time Profiler", 1)
        capture, _ = trace.current(root)
        self.assertTrue(trace.load(capture / "outcome.json")["data"]["cleanup_confirmed"])
        self.assertLessEqual(self.clock.now, trace.START_TIMEOUT + 1.1)

    def test_failed_recorder_never_returns_ready(self):
        root = self.setup_start(mode="early-exit")
        self.assert_status("error", trace.start, root, 100, "Time Profiler", 1)

    def test_start_interrupt_requests_and_waits_for_cleanup(self):
        root = self.setup_start(mode="no-ready")
        self.patch(trace.time, "sleep", side_effect=KeyboardInterrupt)
        with self.assertRaises(KeyboardInterrupt):
            trace.start(root, 100, "Time Profiler", 1)
        capture, _ = trace.current(root)
        self.assertTrue(trace.load(capture / "outcome.json")["data"]["cleanup_confirmed"])

    def test_failed_supervisor_spawn_is_retained_and_allows_future_start(self):
        root = self.setup_start()
        self.patch(trace.subprocess, "Popen", side_effect=OSError("fixture spawn failure"))
        with self.assertRaises(OSError):
            trace.start(root, 100, "Time Profiler", 1)
        capture, _ = trace.current(root)
        self.assertTrue(trace.load(capture / "outcome.json")["data"]["cleanup_confirmed"])

    def test_unavailable_template_never_starts_worker(self):
        root = self.setup_start()
        popen = self.patch(trace.subprocess, "Popen")
        self.assert_status("unsupported", trace.start, root, 100, "Missing", 1)
        popen.assert_not_called()

    def test_replaced_target_before_start_returns_is_refused(self):
        root = self.setup_start()
        self.patch(trace, "process_identity", side_effect=[identity(100), identity(100, "new")])
        self.assert_status("target-lost", trace.start, root, 100, "Time Profiler", 1)
        capture, _ = trace.current(root)
        self.assertTrue((capture / "stop.request.json").exists())


class ExportTests(TraceCase):
    def setup_export(self, *, toc=TOC, profile=PROFILE, export_code=0,
                     status="ok", cleanup=True, stderr=b"fixture error"):
        root, capture, _ = self.capture(status=status, cleanup=cleanup)
        (capture / "recording.trace").mkdir()
        self.patch(trace, "discover", return_value=dict(CAPABILITIES))
        self.patch(trace, "process_identity", return_value=identity(200))
        self.commands = []

        def popen(command, **kwargs):
            self.commands.append(command)
            path = Path(command[command.index("--output") + 1])
            path.write_text(toc if "--toc" in command else profile)
            kwargs["stderr"].write(stderr)
            kwargs["stderr"].flush()
            return Process(self.clock, exit_at=0, code=export_code)

        self.patch(trace.subprocess, "Popen", popen)
        return root, capture

    def test_default_toc_success_is_not_a_measurement(self):
        root, _ = self.setup_export()
        result = trace.export(root)
        self.assertEqual("ok", result["status"])
        self.assertEqual({}, result["data"]["metrics"])
        self.assertFalse(result["data"]["measurement_valid"])
        self.assertFalse(result["data"]["qualified"])
        self.assertEqual("not-requested", result["data"]["measurement_status"])
        self.assertEqual(1, len(self.commands))

    def test_optional_known_metric_and_summary_retained(self):
        root, _ = self.setup_export()
        result = trace.export(root, required=[trace.METRIC])
        self.assertEqual("ok", result["status"])
        self.assertTrue(result["data"]["measurement_valid"])
        self.assertFalse(result["data"]["qualified"])
        self.assertEqual(3, result["data"]["metrics"][trace.METRIC][0]["value"])
        self.assertIn('/trace-toc/run[@number="1"]', self.commands[1][self.commands[1].index("--xpath") + 1])
        directory = Path(result["data"]["export_dir"])
        self.assertEqual(result, trace.load(directory / "summary.json"))
        self.assertTrue((directory / "toc.receipt.json").exists())

    def test_empty_toc_is_not_success(self):
        root, _ = self.setup_export(toc="<trace-toc><run number='1'><data/></run></trace-toc>")
        result = trace.export(root)
        self.assertEqual("assertion-failed", result["status"])
        self.assertEqual("empty", result["data"]["measurement_status"])

    def test_unknown_metrics_are_explicitly_unsupported(self):
        root, _ = self.setup_export()
        result = trace.export(root, required=["displayed_fps"])
        self.assertEqual("unsupported", result["status"])
        self.assertEqual(["displayed_fps"], result["data"]["missing_metrics"])
        self.assertFalse(result["data"]["measurement_valid"])
        self.assertEqual(1, len(self.commands))

    def test_unknown_schema_never_guesses_frames(self):
        root, _ = self.setup_export(toc=TOC.replace("time-profile", "swiftui-unknown"))
        result = trace.export(root, metrics=True)
        self.assertEqual("unsupported", result["status"])
        self.assertEqual({}, result["data"]["metrics"])

    def test_empty_known_table_fails_required_metric(self):
        root, _ = self.setup_export(profile=EMPTY_PROFILE)
        result = trace.export(root, required=[trace.METRIC])
        self.assertEqual("assertion-failed", result["status"])
        self.assertEqual("empty", result["data"]["measurement_status"])
        self.assertEqual({}, result["data"]["metrics"])

    def test_bad_export_exit_preserves_raw_xml_and_stderr(self):
        root, _ = self.setup_export(export_code=1)
        result = trace.export(root, metrics=True)
        self.assertEqual("error", result["status"])
        directory = Path(result["data"]["export_dir"])
        self.assertTrue((directory / "toc.xml").exists())
        self.assertEqual("fixture error", (directory / "toc.stderr").read_text())

    def test_nonzero_recorder_cannot_be_validated_by_good_export(self):
        root, _ = self.setup_export(status="timed-out")
        result = trace.export(root, metrics=True)
        self.assertEqual("assertion-failed", result["status"])
        self.assertFalse(result["data"]["measurement_valid"])
        self.assertTrue(result["data"]["metrics"])

    def test_unfinished_or_unclean_recorder_refuses_export(self):
        root, _ = self.setup_export(status=None)
        self.assert_status("error", trace.export, root)
        self.assertEqual([], self.commands)

    def test_multiple_runs_keep_observations_separate(self):
        toc = TOC.replace("</trace-toc>", '<run number="2"><data><table schema="time-profile"/></data></run></trace-toc>')
        root, _ = self.setup_export(toc=toc)
        result = trace.export(root, metrics=True)
        self.assertEqual("ok", result["status"])
        observations = result["data"]["metrics"][trace.METRIC]
        self.assertEqual([1, 2], [item["run"] for item in observations])
        self.assertEqual([3, 3], [item["value"] for item in observations])

    def test_ambiguous_schema_tables_are_not_summed(self):
        root, _ = self.setup_export(toc=TOC.replace('<table schema="unknown-frame-schema"/>', '<table schema="time-profile"/>'))
        self.assertEqual("unsupported", trace.export(root, metrics=True)["status"])

    def test_repeated_exports_preserve_old_artifacts(self):
        root, _ = self.setup_export()
        first, second = trace.export(root), trace.export(root)
        self.assertNotEqual(first["data"]["export_dir"], second["data"]["export_dir"])
        self.assertTrue(Path(first["data"]["toc"]).exists())

    def test_export_total_deadline_bounds_multiple_tables(self):
        toc = TOC.replace("</trace-toc>", '<run number="2"><data><table schema="time-profile"/></data></run></trace-toc>')
        root, _ = self.setup_export(toc=toc)
        original = trace.run_command
        budgets = []

        def run(command, directory, name, timeout):
            budgets.append(timeout)
            result = original(command, directory, name, timeout)
            self.clock.sleep(timeout)
            return result

        self.patch(trace, "run_command", run)
        result = trace.export(root, metrics=True)
        self.assertEqual("ok", result["status"])
        self.assertEqual([30, 30, 30], budgets)
        self.assertEqual(trace.EXPORT_TIMEOUT, self.clock.now)


if __name__ == "__main__":
    unittest.main()
