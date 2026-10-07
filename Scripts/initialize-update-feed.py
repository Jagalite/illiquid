#!/usr/bin/env python3
"""Initialize GitHub-hosted update metadata inside GitHub Actions; never reset an existing feed."""
import argparse
import json
import os
from pathlib import Path
import subprocess

REPO = "Jagalite/illiquid"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("dist/update-publishing"))
    args = parser.parse_args()
    secret = os.environ["SPARKLE_PRIVATE_KEY"]
    expected = os.environ["SPARKLE_PUBLIC_KEY"]
    # Derive and compare the public key without exposing the private seed.
    derive = '''import CryptoKit
import Foundation
let input = FileHandle.standardInput.readDataToEndOfFile()
let text = String(data: input, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: text)!)
print(key.publicKey.rawRepresentation.base64EncodedString())
'''
    actual = subprocess.check_output(["swift", "-e", derive], input=secret, text=True).strip()
    if actual != expected:
        raise ValueError("SPARKLE_PUBLIC_KEY does not match the signing secret")
    existing = subprocess.run(["gh", "api", f"repos/{REPO}/releases/tags/appcast"], capture_output=True, text=True)
    if existing.returncode == 0:
        if not any(a["name"] == "appcast.xml" for a in json.loads(existing.stdout)["assets"]):
            raise ValueError("Existing appcast release is missing its feed; inspect before proceeding")
        print("Existing feed preserved; nothing published")
        return
    if "HTTP 404" not in existing.stderr:
        raise RuntimeError("Unable to check existing feed: " + existing.stderr)
    args.output.mkdir(parents=True, exist_ok=True)
    feed = args.output / "appcast.xml"
    feed.write_text('<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                    '<title>Illiquid updates</title><link>https://github.com/Jagalite/illiquid</link>'
                    '<description>Signed Illiquid updates</description></channel></rss>\n')
    for options in [[], ["--verify"]]:
        subprocess.run([str(args.tools.resolve() / "sign_update"), "--ed-key-file", "-", *options, str(feed)],
                       input=secret, text=True, check=True)
    notes = args.output / "hosting-notes.md"
    notes.write_text("Hosts the signed Illiquid update feed. This is infrastructure, not an application release.\n")
    subprocess.run(["gh", "release", "create", "appcast", str(feed), "--repo", REPO,
                    "--target", "main", "--prerelease", "--latest=false", "--title", "Illiquid update feed",
                    "--notes-file", str(notes)], check=True)


if __name__ == "__main__":
    main()
