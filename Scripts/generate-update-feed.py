#!/usr/bin/env python3
"""Generate a signed Sparkle feed without publishing or modifying release archives."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE}

def check_build_number(previous_feed, build):
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("CFBundleVersion must be a positive integer")
    root = ET.parse(previous_feed).getroot()
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Previous appcast is not an RSS feed")
    for item in root.findall("./channel/item"):
        version = item.findtext("sparkle:version", namespaces=NS)
        if version is None:
            enclosure = item.find("enclosure")
            version = enclosure.get(f"{{{SPARKLE}}}version") if enclosure is not None else None
        if version is None or not version.isdecimal():
            raise ValueError("Previous appcast has an invalid build number")
        if int(version) >= int(build):
            raise ValueError("Increment CFBundleVersion: it must exceed every published update build")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--previous-feed", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--channel", choices=["stable", "beta"], required=True)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if args.tag != f"v{version}" or not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
        raise ValueError("Release tag does not match the app version")
    check_build_number(args.previous_feed, build)
    if info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("Release must require signed updates and signed feeds")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # The secret stays on stdin. Never pass it in argv, output, or a repo file.
    secret = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not secret:
        raise ValueError("SPARKLE_PRIVATE_KEY is required; production signing runs in GitHub Actions")
    signing = ["--ed-key-file", "-"]
    def run_signed(tool, *arguments):
        subprocess.run([str(args.tools.resolve() / tool), *signing, *map(str, arguments)],
                       input=secret, text=True, check=True)
    # Refuse a corrupted or unsigned history before merging anything into it.
    run_signed("sign_update", "--verify", args.previous_feed.resolve())
    with tempfile.TemporaryDirectory(prefix="illiquid-appcast-") as directory:
        staging = Path(directory)
        archive = staging / args.archive.name
        shutil.copy2(args.archive, archive)
        # An empty signed feed loses its unused namespace; start a fresh
        # document for the first update. Nonempty history is preserved by
        # generate_appcast with --maximum-versions 0.
        if ET.parse(args.previous_feed).find("./channel/item") is not None:
            shutil.copy2(args.previous_feed, staging / "appcast.xml")
        arguments = ["--download-url-prefix", f"https://github.com/Jagalite/illiquid/releases/download/{args.tag}/",
                     "--link", "https://github.com/Jagalite/illiquid",
                     "--maximum-deltas", "0", "--maximum-versions", "0", "--versions", build]
        if args.channel == "beta":
            arguments += ["--channel", "beta"]
        run_signed("generate_appcast", *arguments, staging)
        feed = staging / "appcast.xml"
        root = ET.parse(feed).getroot()
        item = next((item for item in root.findall("./channel/item")
                     if item.findtext("sparkle:version", namespaces=NS) == build), None)
        if item is None:
            raise ValueError("Generated appcast is missing the new build")
        channel = item.findtext("sparkle:channel", namespaces=NS)
        if channel != ("beta" if args.channel == "beta" else None):
            raise ValueError("Generated appcast has the wrong update channel")
        enclosure = item.find("enclosure")
        expected_url = f"https://github.com/Jagalite/illiquid/releases/download/{args.tag}/{args.archive.name}"
        if enclosure is None or enclosure.get("url") != expected_url:
            raise ValueError("Generated appcast has the wrong archive URL")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
        subprocess.run(["swift", str(Path(__file__).with_name("verify-update-signature.swift")),
                        str(archive), signature, info["SUPublicEDKey"]], check=True)
        run_signed("sign_update", feed)
        run_signed("sign_update", "--verify", feed)
        shutil.copy2(feed, args.output)
    print(f"Signed {args.channel} feed prepared: {args.output}")


if __name__ == "__main__":
    main()
