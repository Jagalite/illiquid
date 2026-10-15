"""Store verified source blobs in this same repository, never commits or refs.

Runs after all qualification steps succeed. A subsequent connector operation
constructs the source-only product commits with strict branch-head leases.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess

assert os.environ['GITHUB_REPOSITORY'] == 'Jagalite/illiquid'
assert os.environ['GITHUB_REF'] == 'refs/heads/work/pr3-integration-qualification'
manifest = json.loads(Path('evidence/candidate-source-manifest.json').read_text())
for item in manifest:
    path = Path(item['path'])
    assert str(path) == 'Package.swift' or (path.parts[0] in ('Sources', 'Tests', 'Scripts') and '..' not in path.parts)
    data = path.read_bytes()
    expected = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    assert expected == item['sha']
    response = subprocess.run(['gh', 'api', '--method', 'POST',
        'repos/Jagalite/illiquid/git/blobs', '--input', '-'],
        input=json.dumps({'content': base64.b64encode(data).decode(), 'encoding': 'base64'}),
        text=True, capture_output=True, check=True)
    assert json.loads(response.stdout)['sha'] == expected
print('Verified source blobs stored; no refs or commits changed')
