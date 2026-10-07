#!/usr/bin/env python3
"""Measure production source-tab deduplication in an optimized standalone harness.

Extracts the exact types from AppModel.swift, plus NormalizedFileURL.swift.
This measures caller work, not filesystem access or full SwiftUI layout.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--counts', default='100,500,1000')
a = p.parse_args()
counts = [int(x) for x in a.counts.split(',')]
if any(x < 1 or x > 100000 for x in counts): p.error('counts must be 1...100000')
root = Path(__file__).resolve().parents[1]
a.output.mkdir(parents=True, exist_ok=True)
model = (root/'Sources/IlliquidApp/App/AppModel.swift').read_text()
item = model[model.index('struct SourceTabItem:'):model.index('\nstruct SourceTab:', model.index('struct SourceTabItem:'))]
merging = model[model.index('enum SourceTabItems {'):model.index('\nenum SourceTabStore {')]
normalization = (root/'Sources/IlliquidCore/Utilities/NormalizedFileURL.swift').read_text()
source = normalization+'\n'+item+'\n'+merging+'\n'+'''
for count in COUNTS {
    let input = (0..<count).map { SourceTabItem(kind: .file, url: URL(fileURLWithPath: "/benchmark/episode-\\($0).mkv")) }
    for repeatIndex in 0..<3 {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = SourceTabItems.merging(input, with: input.reversed())
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        precondition(result == input)
        print("{\\"count\\":\\(count),\\"repeat\\":\\(repeatIndex),\\"wall_ms\\":\\(elapsed)}")
    }
}
'''.replace('COUNTS', str(counts))
sourcepath = a.output/'main.swift'
sourcepath.write_text(source)
executable = a.output/'source-items-profile'
subprocess.run(['swiftc', '-O', str(sourcepath), '-o', str(executable)], check=True)
result = subprocess.run([str(executable.resolve())], check=True, capture_output=True, text=True, timeout=240)
rows = [json.loads(line) for line in result.stdout.splitlines()]
(a.output/'results.json').write_text(json.dumps({'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'compiler': subprocess.check_output(['swiftc','--version'],text=True).strip(), 'optimization':'-O', 'runs': rows}, indent=2)+'\n')
print(result.stdout)
