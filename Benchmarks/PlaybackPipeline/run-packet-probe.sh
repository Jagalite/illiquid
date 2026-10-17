#!/usr/bin/env bash
# Linux-only ownership checks against FFmpeg 7.1.5's real allocator/buffers.
# The actual macOS SDK suite is PacketOwnershipTests, not this adapter probe.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$here/../.." && pwd)
if [[ $# != 1 ]]; then echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 2; fi
out=$1
if [[ -e "$out" ]]; then echo 'Output directory must not already exist.' >&2; exit 2; fi
mkdir -p "$out"
out=$(cd -- "$out" && pwd)
python3 "$here/packet_probe.py" --output "$out"
swiftc --version > "$out/compiler.txt"
for variant in baseline candidate; do
  source="$root/Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift"
  define=()
  if [[ $variant == baseline ]]; then source="$here/baseline/FFmpegPacket.swift"; define=(-D BASELINE); fi
  for opt in Onone O; do
    exe="$out/$variant-$opt"
    printf '%s %s\n' "$variant" "$opt"
    swiftc "-$opt" -swift-version 6 -warnings-as-errors -I "$out" \
      "$here/PacketProbeSupport.swift" "$source" "$here/PacketOwnershipProbe.swift" \
      "${define[@]}" -Xlinker -l:libavcodec.so.61 -Xlinker -l:libavutil.so.59 \
      -o "$exe" > "$exe.build.log" 2>&1
    "$exe" > "$exe.json"
    cat "$exe.json"
  done
done
python3 - "$out" "$root" <<'PY'
import json,hashlib,sys
from pathlib import Path
out,root=map(Path,sys.argv[1:]);rows=[]
for variant in ['baseline','candidate']:
 source=(root/'Benchmarks/PlaybackPipeline/baseline/FFmpegPacket.swift') if variant=='baseline' else (root/'Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift')
 b=source.read_bytes()
 if variant=='baseline':assert hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest()=='5a8f25f44a3965f4c6657e013484a00bd9dc9bca'
 for opt in ['Onone','O']:
  rows.append(dict(variant=variant,optimization=opt,source_sha256=hashlib.sha256(b).hexdigest(),result=json.loads((out/f'{variant}-{opt}.json').read_text())))
(out/'results.json').write_text(json.dumps(rows,indent=2))
PY
