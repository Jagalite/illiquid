import importlib.util
from pathlib import Path
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).parents[1] / 'fixtures.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class FixtureTests(unittest.TestCase):
    def test_audio_fixture_is_decodable_and_existing_evidence_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result = fixtures.generate(directory, audio_only=True)
            with wave.open(result['media']) as stream:
                self.assertEqual(stream.getnframes(), 12 * 24000)
            original = Path(result['manifest']).read_bytes()
            with self.assertRaises(ValueError):
                fixtures.generate(directory, audio_only=True)
            self.assertEqual(Path(result['manifest']).read_bytes(), original)
