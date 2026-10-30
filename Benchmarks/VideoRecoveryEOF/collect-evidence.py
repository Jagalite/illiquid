#!/usr/bin/env python3
"""Retain small source/measurement receipts in CI logs as well as artifacts."""
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
run = {
    "id": os.environ["GITHUB_RUN_ID"],
    "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
    "sha": os.environ["GITHUB_SHA"],
    "event": os.environ["GITHUB_EVENT_NAME"],
    "url": f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
}
(root / "github-run.json").write_text(json.dumps(run, indent=2) + "\n")
files = {}
for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(root)
    if any(part in {"build", "module-cache", "fixtures"} for part in relative.parts):
        continue
    if path.suffix in {".json", ".jsonl", ".swift", ".py", ".h", ".xml", ".log", ".txt"}:
        files[str(relative)] = path.read_text()
packed = gzip.compress(json.dumps(files, sort_keys=True).encode(), compresslevel=9, mtime=0)
if len(packed) > 2 * 1024 * 1024:
    raise SystemExit("Evidence exceeds log bundle limit; use uploaded artifact")
print("RECOVERY_EOF_BUNDLE_SHA256 " + hashlib.sha256(packed).hexdigest())
print("RECOVERY_EOF_BUNDLE_BASE64 " + base64.b64encode(packed).decode())
