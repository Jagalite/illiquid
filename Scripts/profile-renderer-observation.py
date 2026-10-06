#!/usr/bin/env python3
"""Benchmark the exact renderer journal sources in isolated optimized processes.

Example: --before /path/to/original.swift --output /tmp/journal-results
This compresses enqueue/clock events; it is not a long-duration playback test.
"""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/SuperplayrNativePlayback/Diagnostics/RendererObservationJournal.swift'
CONTRACT = SOURCE.with_name('DifferentialHarnessContract.swift')

def enum(text, name):
    start = text.index('public enum ' + name + ':')
    return text[start:text.index('\n}', start) + 2]

MAIN = r'''
import Darwin
let count = Int(CommandLine.arguments[1])!
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func residentMaximum() -> Int { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return usage.ru_maxrss }
let initialRSS = residentMaximum()
var journal = DifferentialRendererObservationJournal(epoch: 1)
let enqueueStart = now()
for index in 0..<count {
  let start = Double(index) / 100
  journal.recordEnqueued(kind: index % 2 == 0 ? .video : .audio,
    interval: DifferentialMediaInterval(start: start, end: start + 0.04)!, epoch: 1)
}
let enqueueMS = Double(now() - enqueueStart) / 1e6
let retainedRSS = residentMaximum()
journal.markDemuxEOF(epoch: 1)
let observationStart = now()
for index in 0..<100 {
  journal.observeRendererClock(mediaTime: Double(count) / 200, monotonicSeconds: Double(index), epoch: 1)
}
let observationMS = Double(now() - observationStart) / 1e6
precondition(!journal.isRendererDrained)
journal.observeRendererClock(mediaTime: Double(count), monotonicSeconds: 101, epoch: 1)
precondition(journal.isRendererDrained)
let resetStart = now()
journal = DifferentialRendererObservationJournal(epoch: 2)
let resetMS = Double(now() - resetStart) / 1e6
precondition(!journal.isRendererDrained)
print(String(data: try JSONSerialization.data(withJSONObject: [
  "count": count, "enqueue_ms": enqueueMS, "eof_100_observations_ms": observationMS,
  "reset_ms": resetMS, "initial_max_rss_bytes": initialRSS,
  "after_enqueue_max_rss_bytes": retainedRSS, "final_max_rss_bytes": residentMaximum()
]), encoding: .utf8)!)
'''

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--before', required=True, type=Path)
    p.add_argument('--after', default=SOURCE, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--repeats', default=5, type=int)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    contract = CONTRACT.read_text()
    support = '\n'.join(enum(contract, n) for n in ['DifferentialStreamKind', 'DifferentialReadiness'])
    result = {'runs': [], 'sha256': {}}
    with tempfile.TemporaryDirectory(prefix='illiquid-journal-') as temp:
        temp = Path(temp)
        for role in ['before', 'after']:
            source = getattr(args, role).read_text()
            result['sha256'][role] = hashlib.sha256(source.encode()).hexdigest()
            path = temp / (role + '.swift')
            path.write_text(support + '\n' + source + '\n' + MAIN)
            subprocess.run(['swiftc', '-O', str(path), '-o', str(temp / role)], check=True)
            (args.output / (role + '.swift')).write_text(path.read_text())
        for repeat in range(args.repeats):
            for count in [1000, 100000, 770000]:
                for role in (['before', 'after'] if repeat % 2 == 0 else ['after', 'before']):
                    value = json.loads(subprocess.check_output([str(temp / role), str(count)], text=True))
                    result['runs'].append(dict(value, role=role, repeat=repeat))
                    print(role, count, value['eof_100_observations_ms'], flush=True)
        (args.output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
if __name__ == '__main__': main()
