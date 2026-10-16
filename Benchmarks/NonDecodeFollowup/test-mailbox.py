#!/usr/bin/env python3
"""Test the exact Foundation-only mailbox, not CoreGraphics or the native app."""
import argparse,pathlib,shutil,subprocess,tempfile
here=pathlib.Path(__file__).resolve().parent;root=here.parent.parent
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path);a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='illiquid-mailbox-tests-') as d:
 w=pathlib.Path(d);s=w/'Sources/IlliquidNativePlayback';s.mkdir(parents=True)
 shutil.copy2(root/'Sources/IlliquidNativePlayback/Media/ThumbnailPromotionMailbox.swift',s/'ThumbnailPromotionMailbox.swift')
 t=w/'Tests/IlliquidNativePlaybackTests';t.mkdir(parents=True)
 shutil.copy2(root/'Tests/IlliquidNativePlaybackTests/ThumbnailPromotionMailboxTests.swift',t/'ThumbnailPromotionMailboxTests.swift')
 (w/'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package=Package(name:"MailboxTests",platforms:[.macOS("26.0")],targets:[.target(name:"IlliquidNativePlayback"),.testTarget(name:"IlliquidNativePlaybackTests",dependencies:["IlliquidNativePlayback"])])
''')
 r=subprocess.run(['swift','test','--package-path',str(w),'-c','release','--jobs','2'],capture_output=True,text=True)
 text=r.stdout+'\n'+r.stderr
 if a.output:
  if a.output.exists():raise SystemExit('refusing to overwrite evidence')
  a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(text)
 print(text);raise SystemExit(r.returncode)
