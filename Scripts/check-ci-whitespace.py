#!/usr/bin/env python3
"""Check changed-line whitespace with a resolved, recorded CI comparison base."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True).strip()


def commit(ref: str) -> str:
    return git("rev-parse", "--verify", f"{ref}^{{commit}}")


def comparison(event_name: str, event: dict, explicit_base: str | None = None) -> dict:
    checkout = commit("HEAD")
    before = event.get("before")
    if explicit_base:
        head = checkout
        base_ref = explicit_base
        policy = "explicit-base-merge-base"
    elif event_name == "pull_request":
        head = commit(event["pull_request"]["head"]["sha"])
        base_ref = event["pull_request"]["base"]["sha"]
        policy = "pull-request-merge-base"
    elif event_name in ("push", "workflow_dispatch"):
        head = commit(event["after"]) if event_name == "push" else checkout
        base_ref = "refs/remotes/origin/" + event["repository"]["default_branch"]
        policy = "default-branch-merge-base"
    else:
        raise ValueError("Use --base outside a push, pull_request or workflow_dispatch event")
    base_tip = commit(base_ref)
    base = git("merge-base", base_tip, head)
    # A push/manual run on the default branch must still check changed lines.
    # New topic branches compare all branch changes against the default branch.
    if base == head and not explicit_base and event_name != "pull_request":
        if event_name == "push" and before and set(before) != {"0"}:
            base = commit(before)
            policy = "push-before"
        else:
            base = commit(f"{head}^")
            policy = "head-parent"
    return {
        "event_name": event_name, "policy": policy, "checkout_head": checkout,
        "head": head, "requested_base": base_ref, "resolved_base_tip": base_tip,
        "comparison_base": base, "event_before": before,
        "command": ["git", "diff", "--check", base, head, "--"],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--base", help="Explicit local/manual comparison ref (resolved via merge-base)")
    args = parser.parse_args()
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = json.loads(Path(event_path).read_text()) if event_path else {}
    receipt = comparison(os.environ.get("GITHUB_EVENT_NAME", "local"), event, args.base)
    result = subprocess.run(receipt["command"], capture_output=True, text=True)
    receipt.update(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print("WHITESPACE_CHECK " + json.dumps(receipt, sort_keys=True), flush=True)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
