#!/usr/bin/env python3
"""Copy a finished Kyoto job record and log into a receipt directory.

Writes NAME.job.json (the `kyoto show` record) and NAME.log. Explorer
progress lines are dropped from the stored log; the SHA-256 and line count of
the complete log are kept in the job record under `receipt`.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys

KYOTO = os.environ.get("KYOTO", "/Volumes/seed1/Projects/kyoto/kyoto.py")


def kyoto(*args):
    return subprocess.run([sys.executable, KYOTO, *args], capture_output=True, text=True,
                          check=True).stdout


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: save-kyoto-receipt.py JOB_ID NAME DIRECTORY")
    job, name, directory = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
    record = json.loads(kyoto("show", job))
    if record.get("status") in ("queued", "running"):
        raise SystemExit(f"{job} has not finished")
    log = kyoto("logs", job)
    record["receipt"] = {"logSha256": hashlib.sha256(log.encode()).hexdigest(),
                         "logLines": log.count("\n")}
    directory.mkdir(parents=True, exist_ok=True)
    for path in (directory / f"{name}.job.json", directory / f"{name}.log"):
        if path.exists():
            raise SystemExit(f"{path} exists; receipts are never overwritten")
    (directory / f"{name}.job.json").write_text(json.dumps(record, indent=1, sort_keys=True) + "\n")
    (directory / f"{name}.log").write_text(
        "".join(line for line in log.splitlines(keepends=True)
                if not line.startswith("[state-space-progress]")))
    print(f"{name}: {record.get('status')} exit {record.get('exit_code')}")


if __name__ == "__main__":
    main()
