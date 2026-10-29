"""Non-compiling regression checks for the native memory experiment's controls."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

AREA = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("restoration_memory_runner", AREA / "run.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class MemoryControls(unittest.TestCase):
    def pair(self):
        # The retained failing pair is intentionally not made to pass. A separate
        # synthetic fixture tests the new schema; its numbers are not measurements.
        row = {
            "inputCount": 200, "savedIDCount": 201, "validatedItemCount": 100,
            "itemStride": 40, "indexStride": 8, "checkpointCount": 1,
            "orderReservationCount": 200, "orderCapacity": 254, "mapCapacity": 192,
            "beforeBytes": 1000, "checkpointBytes": 3000, "checkpointDeltaBytes": 2000,
        }
        return row, copy.deepcopy(row)

    def test_equal_controlled_shapes_allow_different_heap_deltas(self):
        before, after = self.pair()
        after.update(checkpointBytes=2500, checkpointDeltaBytes=1500)
        runner.validate_pair(before, after, "memory")

    def test_original_failure_remains_unqualified(self):
        evidence = json.loads((AREA / "evidence/native-capacity-failure.json").read_text())
        before, after = evidence["failing_pair"]
        # Even if a caller falsely tags the old rows as reserved, the original
        # capacity mismatch is still fatal. Never rewrite the historical file.
        for row in (before, after):
            row["orderReservationCount"] = row["inputCount"]
        with self.assertRaisesRegex(AssertionError, "Different container shape: orderCapacity"):
            runner.validate_pair(before, after, "memory")

    def test_invalid_accounting_and_reservation_are_rejected(self):
        for field, value in (
            ("orderReservationCount", 100),  # unique count is not input upper bound
            ("orderCapacity", 199),
            ("mapCapacity", 99),
            ("checkpointCount", 2),
            ("checkpointDeltaBytes", 1999),
            ("validatedItemCount", 99),
        ):
            with self.subTest(field=field):
                before, after = self.pair()
                after[field] = value
                with self.assertRaises(AssertionError):
                    runner.validate_pair(before, after, "memory")

    def test_reservation_and_checkpoint_injections_are_reversible(self):
        text = "prefix\n" + runner.ORDER_MARKER + "loop\n" + runner.MARKER + "suffix\n"
        controlled = runner.instrument_memory(text)
        self.assertLess(controlled.index(runner.ORDER_INJECTION), controlled.index("loop\n"))
        self.assertLess(controlled.index("loop\n"), controlled.index(runner.INJECTION))
        self.assertEqual(controlled.replace(runner.ORDER_INJECTION, "").replace(runner.INJECTION, ""), text)
        self.assertIn("currentOrder.capacity == restorationReservedOrderCapacity", controlled)
        self.assertIn("currentOrder.count == byID.count", controlled)

    def test_missing_duplicate_and_reordered_markers_fail_closed(self):
        for text in (
            runner.MARKER,
            runner.ORDER_MARKER,
            runner.ORDER_MARKER * 2 + runner.MARKER,
            runner.ORDER_MARKER + runner.MARKER * 2,
            runner.MARKER + runner.ORDER_MARKER,
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                runner.instrument_memory(text)

    def test_timing_does_not_require_memory_control_fields(self):
        before, after = self.pair()
        for row in (before, after):
            for field in ("orderCapacity", "orderReservationCount", "checkpointCount"):
                del row[field]
        runner.validate_pair(before, after, "timing")


if __name__ == "__main__":
    unittest.main()
