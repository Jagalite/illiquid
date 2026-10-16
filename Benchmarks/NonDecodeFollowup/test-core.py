#!/usr/bin/env python3
"""Run real persistence sources and XCTest regressions without the macOS app graph."""
import argparse, pathlib, shutil, subprocess, tempfile
here=pathlib.Path(__file__).resolve().parent;root=here.parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--configuration',choices=['debug','release'],default='release');p.add_argument('--output',type=pathlib.Path);a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='illiquid-core-tests-') as d:
 work=pathlib.Path(d);source=work/'Sources/IlliquidCore';source.mkdir(parents=True)
 for path in (here/'fixtures').glob('*.swift'):
  if path.name not in ['PlaybackPersistenceStore.swift','CoalescingPersistenceWriter.swift','PreviewCacheV1.swift','NativeThumbnailDiskCache.swift']: shutil.copy2(path,source/path.name)
 for name in ['PlaybackPersistenceStore.swift','CoalescingPersistenceWriter.swift']:shutil.copy2(root/'Sources/IlliquidCore/Persistence'/name,source/name)
 shutil.copy2(root/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',source/'NonDecodePerformance.swift')
 tests=work/'Tests/IlliquidCoreTests';tests.mkdir(parents=True)
 shutil.copy2(root/'Tests/IlliquidCoreTests/DeferredPersistenceTests.swift',tests/'DeferredPersistenceTests.swift')
 (work/'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidPersistenceTests", targets: [
 .target(name: "IlliquidCore"),
 .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
 r=subprocess.run(['swift','test','--package-path',str(work),'-c',a.configuration,'--jobs','2'],capture_output=True,text=True)
 text=r.stdout+'\n'+r.stderr
 if a.output:
  if a.output.exists():raise SystemExit('refusing to overwrite test evidence')
  a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(text)
 print(text);raise SystemExit(r.returncode)
