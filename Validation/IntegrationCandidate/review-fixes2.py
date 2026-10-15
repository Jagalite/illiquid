"""Apply exact reviewed follow-up edits; validate materialized source identity."""
import hashlib
import json
from pathlib import Path

def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()

manifest_path = Path('evidence/candidate-source-manifest.json')
manifest = {item['path']: item for item in json.loads(manifest_path.read_text())}
records = json.loads(Path('Validation/IntegrationCandidate/review-fixes2.json').read_text())
for item in records:
    path = Path(item['path'])
    assert path.parts[0] in ('Sources', 'Tests', 'Scripts') and '..' not in path.parts
    original = path.read_bytes()
    assert blob(original) == item['base'], str(path)
    lines = original.decode().splitlines(keepends=True)
    assert all(a['end'] <= b['start'] for a, b in zip(item['edits'], item['edits'][1:]))
    for edit in reversed(item['edits']):
        assert 0 <= edit['start'] <= edit['end'] <= len(lines)
        lines[edit['start']:edit['end']] = edit['text'].splitlines(keepends=True)
    data = ''.join(lines).encode()
    assert blob(data) == item['sha'], (str(path), blob(data), item['sha'])
    path.write_bytes(data)
    manifest[str(path)] = {'path': str(path), 'sha': item['sha']}
for path, sha in {
    'Sources/IlliquidPlayer/Player/PlaybackToolsStore.swift': '27c7945775edb11834a2368fb1163a90e58b7fc9',
    'Tests/IlliquidPlayerTests/PlaybackProductNativeIntegrationTests.swift': '71ab6b25c81fda9d9ae87c898d97050fc98b03f2',
}.items():
    assert blob(Path(path).read_bytes()) == sha, path
    manifest[path] = {'path': path, 'sha': sha}
manifest_path.write_text(json.dumps(list(manifest.values()), indent=2))
print('Reviewed transaction, projection and native qualification sources verified')
