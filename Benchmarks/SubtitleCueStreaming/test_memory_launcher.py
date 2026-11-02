#!/usr/bin/env python3
"""Regression checks for the memory benchmark's fresh-process launcher."""
import json
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest


LAUNCHER = Path(__file__).with_name("fresh_process.py")


class MemoryLauncherTests(unittest.TestCase):
    def test_forwards_output_and_nonzero_exit_status(self):
        child = (
            "import sys; print('child stdout'); "
            "print('child stderr', file=sys.stderr); sys.exit(17)"
        )
        result = subprocess.run(
            [sys.executable, "-I", str(LAUNCHER), sys.executable, "-I", "-c", child],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(result.stdout, "child stdout\n")
        self.assertEqual(result.stderr, "child stderr\n")

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux ru_maxrss inheritance regression")
    def test_large_parent_does_not_set_measured_child_rss_floor(self):
        # Keep the allocation in a separate parent so the test runner itself
        # does not retain a large resident set. Touch every page and keep the
        # allocation alive until both observations are complete.
        parent = textwrap.dedent("""\
            import json
            import resource
            import subprocess
            import sys

            held_bytes = 128 * 1024 * 1024
            held = bytearray(held_bytes)
            for offset in range(0, held_bytes, 4096):
                held[offset] = 1
            child = (
                "import resource; "
                "print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024)"
            )
            direct = int(subprocess.check_output(
                [sys.executable, "-I", "-c", child], text=True, timeout=20))
            isolated = int(subprocess.check_output(
                [sys.executable, "-I", sys.argv[1], sys.executable, "-I", "-c", child],
                text=True, timeout=20))
            assert held[0] == held[-4096] == 1
            print(json.dumps({
                "held_bytes": held_bytes,
                "parent_peak_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024,
                "direct_child_peak_bytes": direct,
                "isolated_child_peak_bytes": isolated,
            }, sort_keys=True))
        """)
        result = subprocess.run(
            [sys.executable, "-I", "-c", parent, str(LAUNCHER)],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        observation = json.loads(result.stdout)
        print(json.dumps({"memory_launcher_probe": observation}, sort_keys=True), flush=True)
        direct = observation["direct_child_peak_bytes"]
        isolated = observation["isolated_child_peak_bytes"]
        self.assertGreaterEqual(direct, observation["held_bytes"], observation)
        self.assertGreater(isolated, 0, observation)
        # An exec-only helper preserves the contaminated high-water mark and
        # fails this check. A fork from the clean helper starts a new history.
        self.assertGreaterEqual(direct - isolated, 64 * 1024 * 1024, observation)


if __name__ == "__main__":
    unittest.main(verbosity=2)
