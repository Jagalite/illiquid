#!/usr/bin/env python3
"""Publish a bounded, reproducible evidence bundle from a GitHub Actions job."""
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["RUNNER_TEMP"]) / "media-metadata-merge"
root.mkdir(parents=True, exist_ok=True)
run = {"id": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
       "sha": os.environ["GITHUB_SHA"], "event": os.environ["GITHUB_EVENT_NAME"],
       "job": os.environ["GITHUB_JOB"],
       "url": f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"}
(root / "github-run.json").write_text(json.dumps(run, indent=2) + "\n")
paths = set(root.glob("*.json")) | set(root.glob("*.jsonl")) | set(root.glob("logs/*.log"))
files = {str(path.relative_to(root)): path.read_text() for path in sorted(paths) if path.is_file()}
compressed = {path.name: base64.b64encode(path.read_bytes()).decode()
              for path in sorted(root.glob("verification-*.json.gz"))}
packed = gzip.compress(json.dumps({"text_files": files, "binary_files_base64": compressed},
                                 sort_keys=True).encode(), compresslevel=9, mtime=0)
if len(packed) > 4 * 1024 * 1024:
    raise SystemExit("Evidence exceeds log bundle bound; use the uploaded artifact")
print("METADATA_MERGE_BUNDLE_SHA256 " + hashlib.sha256(packed).hexdigest())
payload = base64.b64encode(packed).decode()
chunks = [payload[start:start + 12000] for start in range(0, len(payload), 12000)]
for index, chunk in enumerate(chunks):
    print("METADATA_MERGE_BUNDLE_PART " + json.dumps({"index": index, "parts": len(chunks), "chunk": chunk}))
if "summary.json" in files:
    summary = json.loads(files["summary.json"])
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as out:
        out.write("## Media metadata merging\n\n")
        out.write(f"Baseline/candidate debug and release tests passed; {summary['verification_cases']:,} complete metadata cases match.\n\n")
        if not summary["tests_only"]:
            out.write("| Case | Baseline ns | Candidate ns | Paired time reduction |\n")
            out.write("|---|---:|---:|---:|\n")
            for row in summary["results"]:
                metric = row["metrics"]["elapsed_ns"]
                out.write(f"| {row['id']} | {metric['baseline_median_ns']:.1f} | "
                          f"{metric['candidate_median_ns']:.1f} | {metric['paired_median_reduction_percent']:.1f}% |\n")
            out.write("\nComplete in-memory metadata merge and PlexMatch lookup timings. "
                      "Does not measure sidecar file I/O, directory scans, UI responsiveness, playback, or energy. "
                      "\n")

