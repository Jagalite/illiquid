"""Reviewed workaround for Swift 6.3's isolated method reabstraction crash."""
from pathlib import Path
import hashlib
import json
p = Path('Sources/IlliquidApp/UI/PlaybackToolsViews.swift')
s = p.read_text()
for old, new in [
    ('set: setAudioChoice', 'set: { setAudioChoice($0) }'),
    ('set: setSubtitleChoice', 'set: { setSubtitleChoice($0) }'),
    ('.onAppear(perform: refresh)', '.onAppear { refresh() }'),
    ('update: player.setPlaybackSpeed', 'update: { player.setPlaybackSpeed($0) }'),
    ('update: player.setAudioDelay', 'update: { player.setAudioDelay($0) }'),
    ('update: player.setSubtitleDelay', 'update: { player.setSubtitleDelay($0) }'),
    ('update: @escaping (Double) -> Void)', 'update: @escaping @MainActor (Double) -> Void)'),
]:
    assert s.count(old) == 1, old
    s = s.replace(old, new)
p.write_text(s)
data = p.read_bytes()
sha = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
assert sha == 'c5ecf277f48ee4f7a1e20341f855c17779785574', sha
manifest_path = Path('evidence/candidate-source-manifest.json')
manifest = json.loads(manifest_path.read_text())
for item in manifest:
    if item['path'] == str(p): item['sha'] = sha
manifest_path.write_text(json.dumps(manifest, indent=2))
