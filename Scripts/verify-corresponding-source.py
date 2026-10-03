#!/usr/bin/env python3
"""Verify a companion dependency-source directory against the reviewed manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile
import posixpath

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source_directory', type=Path)
parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[1] / 'Licenses/corresponding-source-manifest.json')
args = parser.parse_args()
root = args.source_directory.resolve()
manifest = json.loads(args.manifest.read_text())
actual = json.loads((root / 'source-manifest.json').read_text())
if actual != manifest:
    raise SystemExit('Companion manifest differs from the project manifest')
count = 0
for record in manifest['records']:
    if record['status'] == 'excluded':
        continue
    for field, hash_field in [('archive', 'sha256'), ('recipe', 'recipe_sha256')]:
        if field not in record:
            continue
        path = (root / record[field]).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise SystemExit('Missing or escaping input: ' + record[field])
        if hashlib.sha256(path.read_bytes()).hexdigest() != record[hash_field]:
            raise SystemExit('Checksum mismatch: ' + record[field])
    path = root / record['archive']
    if record.get('kind') != 'patch':
        with tarfile.open(path) as archive:
            for member in archive:
                name = Path(member.name)
                if name.is_absolute() or '..' in name.parts:
                    raise SystemExit('Unsafe archive member: ' + member.name)
                if member.issym() or member.islnk():
                    target = Path(member.linkname)
                    joined = str(name.parent / target) if member.issym() else str(target)
                    normalized = Path(posixpath.normpath(joined))
                    if target.is_absolute() or normalized.parts[0] != name.parts[0]:
                        raise SystemExit('Unsafe archive link: ' + member.name)
                if name.suffix.lower() in {'.ttf', '.otf', '.ttc', '.woff', '.woff2', '.pfb', '.pfa', '.pcf', '.bdf', '.sfd', '.pdf', '.docx'}:
                    raise SystemExit('Unreviewed upstream font/document: ' + member.name)
                if member.isfile() and archive.extractfile(member).read(4) in (b'OTTO', b'wOFF', b'wOF2', b'ttcf', b'\x00\x01\x00\x00'):
                    raise SystemExit('Embedded upstream font corpus: ' + member.name)
    count += 1
for record in manifest['notice_documents']:
    path = args.manifest.resolve().parents[1] / record['path']
    # Project notices are relative to the repository, rather than to Licenses/.
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != record['sha256']:
        raise SystemExit('Notice mismatch: ' + record['path'])
print(f'Verified {count} source/resource/patch inputs and {len(manifest["notice_documents"])} notice documents')
