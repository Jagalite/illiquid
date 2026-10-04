#!/usr/bin/env python3
"""Write a portable Finder install layout before Finder opens the image."""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from ds_store import DSStore
from ds_store.store import codecs
from mac_alias import Alias

mount = Path(sys.argv[1]).resolve()
for code in (b"pBBk", b"pBB0"):
    codecs.pop(code, None)
if len(sys.argv) == 4 and sys.argv[3] == "--verify":
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        native_bookmark = store["."]["pBBk"][1] + store["."]["pBB0"][1]
    with tempfile.NamedTemporaryFile() as temporary:
        temporary.write(native_bookmark)
        temporary.flush()
        resolved = subprocess.check_output([sys.argv[2], temporary.name, "--resolve"], text=True).strip()
    if Path(resolved).resolve() != mount / ".background/InstallBackground.tiff":
        raise RuntimeError("Background bookmark resolved outside the install image")
    sys.exit(0)
background = Alias.from_bytes(subprocess.check_output([
    sys.argv[2], str(mount / ".background/InstallBackground.tiff")
]))
background.volume.disk_image_alias = None
bookmark = subprocess.check_output([
    sys.argv[2], str(mount / ".background/InstallBackground.tiff"), "--bookmark"
])
# Finder splits the native bookmark's final table: the three file-specific
# entries stay in pBBk, while the remaining entries are stored in pBB0.
header_size = struct.unpack_from("<I", bookmark, 12)[0]
table_start = header_size + struct.unpack_from("<I", bookmark, header_size)[0]
entry_count = struct.unpack_from("<I", bookmark, table_start + 16)[0]
if table_start + 20 + entry_count * 12 != len(bookmark):
    raise RuntimeError("Unexpected native background bookmark layout")
file_keys = tuple(struct.unpack_from("<I", bookmark, table_start + 20 + i * 12)[0] for i in range(3))
if file_keys != (0x1004, 0x1005, 0x1010):
    raise RuntimeError("Unexpected native background bookmark keys")
split = table_start + 20 + 3 * 12
with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
    store["."]["bwsp"] = {
        "ShowStatusBar": False,
        "ShowToolbar": False,
        "ShowTabView": False,
        "ContainerShowSidebar": False,
        "ShowSidebar": False,
        "WindowBounds": "{{140, 140}, {720, 488}}",
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": background.to_bytes(),
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "iconSize": 112.0,
        "textSize": 14.0,
        "arrangeBy": "none",
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "labelOnBottom": True,
        "showIconPreview": True,
        "showItemInfo": False,
    }
    store["."]["vSrn"] = ("long", 1)
    store["."]["pBBk"] = ("blob", bookmark[:split])
    store["."]["pBB0"] = ("blob", bookmark[split:])
    store["Illiquid.app"]["Iloc"] = (190, 234)
    store["Applications"]["Iloc"] = (530, 234)
