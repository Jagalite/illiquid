#!/usr/bin/env python3
"""Export reviewed source/assets without history or private qualification artifacts.
The destination must not exist. Does not commit, push or alter the source repo.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT_FILES = {'.gitignore', 'README.md', 'DISTRIBUTING.md', 'LICENSE', 'LICENSING.md', 'THIRD_PARTY_NOTICES.md', 'Package.swift', 'Package.resolved'}
CODE_ROOTS = {'Sources', 'Tests', 'Validation', 'Scripts', 'Resources', 'Licenses'}
ARTWORK = {'Documentation/Design/IlliquidLiquidGlass/droplet-controls-concept.png', 'Documentation/Design/IlliquidLiquidGlass/quiet-waterline-concept.png'}


def include(name):
    p = Path(name)
    if '__pycache__' in p.parts or p.suffix in {'.pyc', '.log'}:
        return False
    if name in ROOT_FILES or name in ARTWORK:
        return True
    if p.parts[0] in CODE_ROOTS or name.startswith('TestFixtures/Fonts/'):
        return True
    if p.parts[0] == 'Documentation':
        return p.suffix == '.md' and not any(part in {'Qualification', 'PublicationAudit', 'Design'} for part in p.parts)
    if p.parts[0] == 'Benchmarks':
        return 'results' not in p.parts and p.suffix in {'.md', '.py', '.sh', '.swift', '.c', '.h', '.m'}
    return False


def normalize(text):
    # Privacy examples use neutral absolute paths so negative path tests retain
    # their semantics. Neither environment dumps nor structured traces ship.
    text = re.sub(r'/Users/[A-Za-z0-9._-]+', '/private/tmp/user', text)
    text = re.sub(r'/home/[A-Za-z0-9._-]+', '/private/tmp/user', text)
    text = re.sub(r'/Volumes/[A-Za-z0-9._-]+', '/private/tmp/volume', text)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--receipt', type=Path, required=True, help='Private receipt outside the public destination')
    args = parser.parse_args()
    source = args.source.resolve()
    destination = args.destination.resolve()
    receipt = args.receipt.resolve()
    if destination.exists() or destination.is_relative_to(source) or receipt.is_relative_to(destination):
        raise SystemExit('Use a new destination outside the source and an external receipt')
    names = set(subprocess.check_output(['git', '-C', str(source), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().rstrip('\0').split('\0'))
    selected = sorted(n for n in names if n and include(n) and (source/n).is_file())
    destination.mkdir(parents=True)
    records = []
    for name in selected:
        old = source/name
        if old.is_symlink():
            raise SystemExit('Review symlink before exporting: ' + name)
        new = destination/name
        new.parent.mkdir(parents=True, exist_ok=True)
        raw = old.read_bytes()
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            text = None
        if text is not None and not name.startswith('Licenses/') and not name.startswith('TestFixtures/Fonts/'):
            text = normalize(text)
            if new.suffix == '.md':
                def link(match):
                    target = match.group(2)
                    if target.startswith(('https:', 'http:', 'mailto:', '#')):
                        return match.group(0)
                    relative = target.split('#', 1)[0]
                    if not relative:
                        return match.group(0)
                    resolved = (old.parent/relative).resolve()
                    if resolved.is_relative_to(source) and resolved.relative_to(source).as_posix() in selected:
                        return match.group(0)
                    return match.group(1) + ' (reference omitted from this source export)'
                text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', link, text)
            new.write_text(text)
        else:
            new.write_bytes(raw)
        shutil.copymode(old, new)
        records.append({'path': name, 'sha256': hashlib.sha256(new.read_bytes()).hexdigest(), 'changed_for_export': new.read_bytes() != raw})
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({'history': 'fresh export; no source Git objects copied', 'files': records, 'excluded_counts_by_root': dict(Counter(Path(n).parts[0] for n in names if n and n not in selected)), 'excluded_paths': sorted(names-set(selected))}, indent=2)+'\n')
    print(f'Exported {len(records)} files; {sum(r["changed_for_export"] for r in records)} normalized/updated; no Git history copied')


if __name__ == '__main__':
    main()
