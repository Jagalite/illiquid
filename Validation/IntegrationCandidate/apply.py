"""Materialize the reviewed candidate on its exact source snapshot.

This temporary branch transports line edits for large files; it is not a
production patch runner. Both inputs and outputs are git-blob hash checked.
Only the resulting source files enter PR #3, using normal leased ref updates.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent

def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()

def apply(record):
    path = ROOT / record['path']
    assert record['path'].startswith(('Sources/', 'Tests/', 'Scripts/'))
    assert '..' not in Path(record['path']).parts
    original = path.read_bytes() if path.exists() else b''
    assert (blob(original) if path.exists() else None) == record['base'], record['path']
    lines = original.decode().splitlines(keepends=True)
    edits = record['edits']
    assert all(a['end'] <= b['start'] for a, b in zip(edits, edits[1:]))
    for edit in reversed(edits):
        assert 0 <= edit['start'] <= edit['end'] <= len(lines)
        lines[edit['start']:edit['end']] = edit['text'].splitlines(keepends=True)
    data = ''.join(lines).encode()
    assert blob(data) == record['sha'], (record['path'], blob(data), record['sha'])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return {'path': record['path'], 'sha': blob(data)}

records = json.loads((HERE / 'shell-edits.json').read_text())
edits = []
for part in range(1, 4):
    edits += json.loads((HERE / f'coordinator-edits-{part}.json').read_text())
edits.append({'start': 2651, 'end': 2651, 'text': (HERE / 'CoordinatorExtension.swift').read_text()})
records.append({'path': 'Sources/IlliquidPlayer/Player/PlaybackController.swift',
                'base': 'fc4d550e5ce151fdccf10f150f25ea7c6a4484af',
                'sha': 'c54447ac2626868b31c29d587aa307d1d2200526', 'edits': edits})
manifest = [apply(record) for record in records]
for path, sha in {
    'Sources/IlliquidApp/App/PlaybackAppIntents.swift': 'bcd53c624cd90830a77e0f428b7e063bf20a6f7b',
    'Sources/IlliquidApp/UI/PlaybackToolsViews.swift': '6d1d8684fea83f76fb71f3f821d4328564da5fed',
    'Tests/IlliquidPlayerTests/PlaybackProductTransactionTests.swift': '671b2dc6aa5fb0fe71fe664dcf870853d1ead6fa',
}.items():
    actual = blob((ROOT / path).read_bytes())
    assert actual == sha, (path, actual, sha)
    manifest.append({'path': path, 'sha': actual})
(ROOT / 'evidence').mkdir(exist_ok=True)
(ROOT / 'evidence/candidate-source-manifest.json').write_text(json.dumps(manifest, indent=2))
print(f'Applied and verified {len(manifest)} candidate source files')
