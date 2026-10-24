#!/usr/bin/env python3
"""Execute production dialog callbacks with fake UI; no app build or GUI input.

Run through Kyoto: kyoto.py submit -- python3 Scripts/tests/subtitle-delay-dialog-tests.py
Uses an isolated temporary Swift compilation, never the product's .build directory.
"""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def section(text, start, end):
    """Keep production bodies verbatim between unique declaration anchors."""
    assert text.count(start) == 1, start
    tail = text.split(start, 1)[1]
    assert tail.count(end) == 1, end
    return start + tail.split(end, 1)[0]


def main():
    model = (ROOT / 'Sources/IlliquidApp/App/AppModel.swift').read_text()
    osd = (ROOT / 'Sources/IlliquidApp/App/PlaybackOSD.swift').read_text()
    parser = section(model, 'enum SubtitleDelayInput {', 'enum PlayerWindowPointerPolicy {')
    callback = section(model, '    private func presentSubtitleDelayPanel(',
                       '    private func addContextItem(')
    shortcuts = section(osd, '    static func shortcuts(supportsFrameStep:',
                        '    private var shortcuts:')
    fixture = (ROOT / 'Tests/AgentUI/Fixtures/subtitle-delay-dialog.swift').read_text()
    source = (fixture.replace('// PRODUCTION_PARSER', parser)
              .replace('// PRODUCTION_CALLBACK', callback)
              .replace('// PRODUCTION_SHORTCUTS', shortcuts))
    with tempfile.TemporaryDirectory(prefix='illiquid-subtitle-delay-tests-') as temporary:
        directory = Path(temporary)
        swift = directory / 'DialogTests.swift'
        swift.write_text(source)
        executable = directory / 'dialog-tests'
        subprocess.run([
            'swiftc', '-swift-version', '6', '-parse-as-library',
            str(ROOT / 'Sources/IlliquidCore/Utilities/NormalizedFileURL.swift'),
            str(ROOT / 'Sources/IlliquidCore/Player/MediaSource.swift'),
            str(swift), '-o', str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    main()
