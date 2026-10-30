#!/usr/bin/env python3
"""Standalone full-suite regression; historical performance runner remains unchanged."""
import argparse, pathlib, shutil, subprocess, json, hashlib, sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
def main():
 p=argparse.ArgumentParser(); p.add_argument('--output',type=pathlib.Path,required=True); a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=False)
 sources=['Sources/IlliquidCore/Playlist/FolderPlaylist.swift', 'Sources/IlliquidCore/Playlist/PlaylistMutation.swift', 'Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift', 'Sources/IlliquidCore/Utilities/NormalizedFileURL.swift']
 tests=['Tests/IlliquidCoreTests/NormalizedFileURLPersistenceKeyTests.swift', 'Tests/IlliquidCoreTests/PR144NormalizedFileURLPersistenceKeyTests.swift', 'Tests/IlliquidCoreTests/NormalizedFileIdentityTests.swift', 'Tests/IlliquidCoreTests/FileIdentityByteQualificationTests.swift', 'Tests/IlliquidCoreTests/PR201NormalizedFileURLPersistenceKeyTests.swift']
 helpers=['Tests/Support/PR199NativeFixtures/PR199NativeFixtures.m', 'Tests/Support/PR199NativeFixtures/include/PR199NativeFixtures.h']
 inputs=sources+tests+helpers
 hashes={x:hashlib.sha256((ROOT/x).read_bytes()).hexdigest() for x in inputs}
 (a.output/'inputs.json').write_text(json.dumps(hashes,indent=2))
 for config in ['debug','release']:
  work=a.output/config;work.mkdir()
  for src in inputs:
   dest=work/src;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/src,dest)
  (work/'Package.swift').write_text('// swift-tools-version: 6.1\nimport PackageDescription\n#if canImport(Darwin)\nlet nativeFixtureTargets: [Target] = [\n    .target(name: "PR199NativeFixtures", path: "Tests/Support/PR199NativeFixtures",\n            publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])])\n]\nlet nativeFixtureDependencies: [Target.Dependency] = ["PR199NativeFixtures"]\n#else\nlet nativeFixtureTargets: [Target] = []\nlet nativeFixtureDependencies: [Target.Dependency] = []\n#endif\n\nlet package = Package(name: "IdentityRegression", targets: [.target(name: "IlliquidCore", path: "Sources/IlliquidCore"), .testTarget(name: "IlliquidCoreTests", dependencies: [.target(name: "IlliquidCore")] + nativeFixtureDependencies, path: "Tests/IlliquidCoreTests")] + nativeFixtureTargets)\n')
  cmd=['swift','test','--package-path',str(work),'--no-parallel','--jobs','2','-c',config]
  if sys.platform!='darwin': cmd+=['--use-integrated-swift-driver']
  (a.output/(config+'-command.json')).write_text(json.dumps(cmd))
  with (a.output/(config+'.log')).open('w') as log:
   subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
 for x,h in hashes.items():
  if hashlib.sha256((ROOT/x).read_bytes()).hexdigest()!=h: raise RuntimeError('Input changed: '+x)
 (a.output/'completion.json').write_text(json.dumps({'executed':['debug','release'],'input_hashes_verified':True}))
if __name__=='__main__': main()
