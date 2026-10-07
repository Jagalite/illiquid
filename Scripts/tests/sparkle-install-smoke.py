#!/usr/bin/env python3
"""Exercise signed-feed selection and installation on disposable app copies only.

Requires Sparkle's version-matched sparkle-cli (built from upstream sources).
Production keys, feeds, installed apps and preferences are never used.
"""
import argparse
import functools
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    root = Path(tempfile.mkdtemp(prefix="illiquid-sparkle-smoke-"))
    print(f"Isolated test directory: {root}", flush=True)
    key_path = root / "test-key"
    create_key = '''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: key.rawRepresentation.base64EncodedData(), attributes: [.posixPermissions: 0o600])
print(key.publicKey.rawRepresentation.base64EncodedString())
'''
    key_script = root / "create-key.swift"
    key_script.write_text(create_key)
    public = subprocess.check_output(["swift", str(key_script), str(key_path)], text=True).strip()
    secret = key_path.read_text()
    key_path.unlink()
    environment = dict(os.environ, SPARKLE_PRIVATE_KEY=secret)
    identifier = "io.github.jagalite.illiquid.update-smoke." + uuid.uuid4().hex
    old, new = root / "installed/Illiquid.app", root / "new/Illiquid.app"
    def sign(path):
        subprocess.run([str(args.tools / "sign_update"), "--ed-key-file", "-", str(path)],
                       input=secret, text=True, check=True, stdout=subprocess.DEVNULL)
    for app, build in [(old, "1"), (new, "2")]:
        app.parent.mkdir()
        subprocess.run(["ditto", str(args.app), str(app)], check=True)
        path = app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(CFBundleIdentifier=identifier, CFBundleVersion=build, SUPublicEDKey=public,
                    SUEnableAutomaticChecks=False, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
        path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server_root = root / "server"
    server_root.mkdir()
    version = info["CFBundleShortVersionString"]
    archive = server_root / f"Illiquid-{version}-macOS.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(new), str(archive)], check=True)
    previous = root / "previous.xml"
    # The previous stable release must survive publication of a newer beta,
    # even though its archive is not present in the generation directory.
    previous.write_text('''<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Test</title><item><title>Previous stable</title>
<sparkle:version>1</sparkle:version><sparkle:shortVersionString>0.0.1</sparkle:shortVersionString>
<enclosure url="https://example.com/previous.zip" length="1" type="application/octet-stream" sparkle:edSignature="previous-signature"/>
</item></channel></rss>''')
    sign(previous)
    feed = server_root / "appcast.xml"
    subprocess.run(["python3", str(repository / "Scripts/generate-update-feed.py"), "--app", str(new),
                    "--archive", str(archive), "--previous-feed", str(previous), "--output", str(feed),
                    "--tools", str(args.tools), "--tag", f"v{version}", "--channel", "beta"],
                   env=environment, check=True)
    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(server_root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    tree = ET.parse(feed)
    history = tree.findall("./channel/item")
    assert len(history) == 2, "Publishing beta must preserve stable history"
    prior = next(item for item in history if item.findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}version") == "1")
    assert prior.find("enclosure").get("url") == "https://example.com/previous.zip"
    assert prior.find("enclosure").get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature") == "previous-signature"
    tree.find("./channel/item/enclosure").set("url", f"{base}/{archive.name}")
    tree.write(feed, encoding="utf-8", xml_declaration=True)
    sign(feed)
    def run_cli(name, *options):
        result = subprocess.run([str(args.cli), str(old), "--feed-url", f"{base}/appcast.xml",
                                 "--user-agent-name", "IlliquidUpdateTest", *options],
                                text=True, capture_output=True, timeout=120)
        (root / f"{name}.log").write_text(result.stdout + result.stderr)
        return result.returncode
    try:
        assert run_cli("stable", "--probe") == 4, "Stable checks must ignore beta updates"
        assert run_cli("beta", "--probe", "--channels", "beta") == 0, "Beta update should be found"
        signed_feed = feed.read_bytes()
        feed.write_bytes(signed_feed.replace(b"Previous stable", b"Altered stable"))
        assert run_cli("tampered-feed", "--probe", "--channels", "beta") not in (0, 4), "Modified signed feed must be rejected"
        feed.write_bytes(signed_feed)
        size = archive.stat().st_size
        with archive.open("ab") as output: output.write(b"tampered")
        assert run_cli("tampered", "--check-immediately", "--channels", "beta") != 0, "Tampered update must fail"
        assert "4005" in (root / "tampered.log").read_text(), "Failure must be a signature rejection"
        assert plistlib.loads((old / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "1"
        with archive.open("r+b") as output: output.truncate(size)
        # The CLI exits on rejection before the installer helper finishes its
        # asynchronous cleanup. Retry only that specific transient resume error.
        for attempt in range(6):
            result = run_cli(f"install-{attempt}", "--check-immediately", "--channels", "beta")
            if result == 0 or "error 1004" not in (root / f"install-{attempt}.log").read_text():
                break
            time.sleep(2)
        assert result == 0, "Signed update must install"
        assert plistlib.loads((old / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "2"
        print("PASS: history preservation, stable/beta selection, feed/archive tamper rejection, and signed build 1 → 2 installation", flush=True)
    finally:
        server.shutdown()
        # This domain belongs only to the unique disposable fixture.
        subprocess.run(["defaults", "delete", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
