#!/usr/bin/env python3
"""Aggregate every completed history group, including unequal repetition counts."""
from __future__ import annotations
import argparse
import json
import statistics
from pathlib import Path

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('refusing to overwrite an existing summary')
    rows = [json.loads(line) for line in args.input.read_text().splitlines() if line.strip()]
    keys = [(r['count'], r['mode'], r['variant'], r['repeat']) for r in rows]
    if not rows or len(keys) != len(set(keys)):
        parser.error('empty evidence or duplicate observation identities')
    groups = sorted({key[:3] for key in keys})
    summary = []
    metrics = ['mutation_total_ns', 'operation_ns', 'writes', 'set_payload_bytes',
               'allocation_requests', 'allocation_request_bytes']
    for count, mode, variant in groups:
        group = [r for r in rows if (r['count'], r['mode'], r['variant']) == (count, mode, variant)]
        entry = dict(count=count, mode=mode, variant=variant, samples=len(group))
        for metric in metrics:
            if metric in group[0]:
                values = [r[metric] for r in group]
                entry[metric] = dict(median=statistics.median(values), min=min(values), max=max(values))
        summary.append(entry)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2))
    print(f'{len(rows)} unique observations in {len(groups)} groups')

if __name__ == '__main__':
    main()
