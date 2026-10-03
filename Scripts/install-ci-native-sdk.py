#!/usr/bin/env python3
"""Validate and install reviewed build inputs on an ephemeral GitHub macOS runner."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import tarfile

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'BuildInputs/native-sdk.json').read_text())
archive = root / 'BuildInputs' / manifest['archive']

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if sha(archive) != manifest['sha256']:
    raise SystemExit('SDK archive checksum mismatch')
if sha(root / 'DependencySources/source-manifest.json') != manifest['sourceManifestSHA256']:
    raise SystemExit('SDK/source manifest mismatch')
records = {r['path']: r for r in manifest['files']}
kegs = {name: PurePosixPath(value) for name, value in manifest['kegs'].items()}
for keg in kegs.values():
    if len(keg.parts) != 3 or keg.parts[0] != 'Cellar' or '..' in keg.parts:
        raise SystemExit('Invalid SDK keg')
with tarfile.open(archive) as tar:
    members = tar.getmembers()
    if len(members) != len(records) or {m.name for m in members} != set(records):
        raise SystemExit('SDK inventory mismatch')
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not any(path.is_relative_to(k) for k in kegs.values()):
            raise SystemExit('Unsafe SDK path')
        record = records[member.name]
        if member.isfile():
            if hashlib.sha256(tar.extractfile(member).read()).hexdigest() != record.get('sha256'):
                raise SystemExit('SDK member checksum mismatch: ' + member.name)
        elif member.issym():
            target = PurePosixPath(member.linkname)
            # SDK aliases must stay within the same library/header directory.
            if target.is_absolute() or '..' in target.parts or member.linkname != record.get('symlink'):
                raise SystemExit('Unsafe SDK symlink: ' + member.name)
        else:
            raise SystemExit('Unsupported SDK member')
    if os.environ.get('ILLIQUID_VERIFY_SDK_ONLY') == '1':
        print('SDK archive, members and source binding verified')
        raise SystemExit(0)
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise SystemExit('Installation is restricted to ephemeral GitHub-hosted runners')
    if platform.system() != 'Darwin' or platform.machine() != manifest['architecture']:
        raise SystemExit('SDK requires Apple Silicon macOS')
    prefix = Path('/opt/homebrew')
    # Replace only the reviewed kegs, on this disposable runner.
    for keg in kegs.values():
        destination = prefix / keg
        if destination.is_symlink():
            destination.unlink()
        elif destination.exists():
            shutil.rmtree(destination)
    tar.extractall(prefix, filter='fully_trusted')  # Inventory and all members validated above.
for name, keg in kegs.items():
    opt = prefix / 'opt' / name
    if opt.is_symlink():
        opt.unlink()
    elif opt.exists():
        raise SystemExit('Refusing to replace non-symlink opt directory: ' + str(opt))
    opt.symlink_to(prefix / keg)
pcdirs = []
for keg in kegs.values():
    for sub in ('lib/pkgconfig', 'share/pkgconfig'):
        directory = prefix / keg / sub
        if directory.is_dir():
            pcdirs.append(str(directory))
with open(os.environ['GITHUB_PATH'], 'a') as f:
    f.write(str(prefix / kegs['ffmpeg'] / 'bin') + '\n')
with open(os.environ['GITHUB_ENV'], 'a') as f:
    f.write('PKG_CONFIG_LIBDIR=' + ':'.join(pcdirs) + '\n')
    f.write('PKG_CONFIG_PATH=\n')
print('Installed checksum-verified SDK on ephemeral runner')
