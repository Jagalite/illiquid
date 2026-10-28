#!/usr/bin/env python3
"""Run real persistence sources and XCTest regressions without the macOS app graph."""
import argparse, pathlib, shutil, subprocess, tempfile
here=pathlib.Path(__file__).resolve().parent;root=here.parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--configuration',choices=['debug','release'],default='release');p.add_argument('--output',type=pathlib.Path);p.add_argument('--v2',action='store_true');p.add_argument('--filter');a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='illiquid-core-tests-') as d:
 work=pathlib.Path(d);source=work/'Sources/IlliquidCore';source.mkdir(parents=True)
 for path in (root/'Benchmarks/NonDecodeFollowup/fixtures').glob('*.swift'):
  if path.name not in ['PlaybackPersistenceStore.swift','CoalescingPersistenceWriter.swift','PreviewCacheV1.swift','NativeThumbnailDiskCache.swift']: shutil.copy2(path,source/path.name)
 for name in ['PlaybackPersistenceStore.swift','CoalescingPersistenceWriter.swift']:
  path = here/'baseline/PlaybackPersistenceStoreV2.swift' if a.v2 and name == 'PlaybackPersistenceStore.swift' else root/'Sources/IlliquidCore/Persistence'/name
  shutil.copy2(path,source/name)
 if not a.v2: shutil.copy2(root/'Sources/IlliquidCore/Persistence/PlaybackPreferences.swift',source/'PlaybackPreferences.swift')
 shutil.copy2(root/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',source/'NonDecodePerformance.swift')
 tests=work/'Tests/IlliquidCoreTests';tests.mkdir(parents=True)
 for name in ['DeferredPersistenceTests.swift','IdempotentPersistenceTests.swift']: shutil.copy2(root/'Tests/IlliquidCoreTests'/name,tests/name)
 (work/'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidPersistenceTests", platforms: [.macOS("26.0")], targets: [
 .target(name: "IlliquidCore"),
 .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
''')
 r=subprocess.run(['swift','test','--package-path',str(work),'-c',a.configuration,'--jobs','2','-Xswiftc','-warnings-as-errors',*(['--filter',a.filter] if a.filter else [])],capture_output=True,text=True)
 text=r.stdout+'\n'+r.stderr
 if a.output:
  if a.output.exists():raise SystemExit('refusing to overwrite test evidence')
  a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(text)
 print(text);raise SystemExit(r.returncode)
