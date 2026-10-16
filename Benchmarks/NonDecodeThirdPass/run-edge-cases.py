#!/usr/bin/env python3
"""Run untimed edge diagnostics after run-inventory.py --build-only or a full run."""
import argparse, hashlib, json, pathlib, platform, subprocess
H=pathlib.Path(__file__).resolve().parent;R=H.parent.parent
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--inventory-build',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
if any(a.output.iterdir()):p.error('output must be empty')
rows=[];logs=[];manifest={}
for variant in ['v2','v3']:
    src=R/'Sources/IlliquidNativePlayback/Media'
    inputs=[a.inventory_build/variant/'Cache.swift',a.inventory_build/variant/'Disk.swift',
        src/'ThumbnailPromotionMailbox.swift',R/'Sources/IlliquidCore/Player/ThumbnailPolicy.swift',
        R/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',
        R/'Benchmarks/NonDecodeFollowup/PreviewAdapters.swift',H/'InventoryEdgeCases.swift']
    binary=a.output/variant
    cmd=['swiftc','-O','-swift-version','6','-warnings-as-errors',*(['-D','CANDIDATE'] if variant=='v3' else []),
        *map(str,inputs),*(['-lcrypto'] if platform.system()=='Linux' else []),'-o',str(binary)]
    for command in [cmd,[str(binary)]]:
        c=subprocess.run(command,text=True,capture_output=True,timeout=120)
        logs.append(dict(command=command,stdout=c.stdout,stderr=c.stderr,returncode=c.returncode))
        if c.returncode:raise RuntimeError(c.stderr or c.stdout)
    row=json.loads(c.stdout);row['variant']=variant;rows.append(row)
    manifest[variant]={str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
(a.output/'results.json').write_text(json.dumps(rows,indent=2))
(a.output/'commands.json').write_text(json.dumps(logs,indent=2))
(a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(json.dumps(rows,indent=2))
