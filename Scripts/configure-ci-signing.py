#!/usr/bin/env python3
"""Import Illiquid's signing identity into a disposable GitHub runner keychain."""
import base64
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Commands may contain passwords: never log argv or credential output.
        raise SystemExit(f"{Path(args[0]).name} {args[1]} failed (exit {result.returncode})")
    return result.stdout


if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
    raise SystemExit("Signing credential setup is restricted to disposable GitHub-hosted runners")
if os.environ.get("RUNNER_OS") != "macOS":
    raise SystemExit("Signing requires a macOS runner")
directory = Path(os.environ["RUNNER_TEMP"]) / "illiquid-signing"
keychain = directory / "release.keychain-db"
original = directory / "original-keychains.json"
if len(sys.argv) == 2 and sys.argv[1] == "cleanup":
    if original.exists():
        run("security", "list-keychains", "-d", "user", "-s", *json.loads(original.read_text()))
    if keychain.exists():
        run("security", "delete-keychain", str(keychain))
    for name in ("certificate.p12", "original-keychains.json"):
        (directory / name).unlink(missing_ok=True)
    print("Removed temporary signing keychain and credential files")
    sys.exit(0)
required = ("APPLE_APPLICATION_CERT_P12_BASE64", "APPLE_APPLICATION_CERT_PASSWORD",
            "APPLE_NOTARY_USERNAME", "APPLE_NOTARY_PASSWORD", "APPLE_TEAM_ID")
missing = [name for name in required if not os.environ.get(name)]
if missing:
    raise SystemExit("Missing Illiquid repository secrets: " + ", ".join(missing))
team = os.environ["APPLE_TEAM_ID"]
if not re.fullmatch(r"[A-Z0-9]{10}", team):
    raise SystemExit("APPLE_TEAM_ID must be a 10-character Apple team identifier")
directory.mkdir(mode=0o700)
original.write_text(json.dumps(shlex.split(run("security", "list-keychains", "-d", "user"))))
password = secrets.token_urlsafe(40)
certificate = directory / "certificate.p12"
certificate.write_bytes(base64.b64decode("".join(os.environ[required[0]].split()), validate=True))
certificate.chmod(0o600)
try:
    run("security", "create-keychain", "-p", password, str(keychain))
    run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
    run("security", "unlock-keychain", "-p", password, str(keychain))
    run("security", "list-keychains", "-d", "user", "-s", str(keychain), *json.loads(original.read_text()))
    run("security", "import", str(certificate), "-k", str(keychain), "-P",
        os.environ[required[1]], "-T", "/usr/bin/codesign")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain))
    identities = re.findall(r'"(Developer ID Application: [^"\n]+)"',
                            run("security", "find-identity", "-v", "-p", "codesigning", str(keychain)))
    identities = [name for name in identities if name.endswith(f"({team})")]
    if len(identities) != 1:
        raise SystemExit("P12 must contain exactly one valid Developer ID Application identity for APPLE_TEAM_ID")
    run("xcrun", "notarytool", "store-credentials", "illiquid-notary", "--keychain", str(keychain),
        "--apple-id", os.environ["APPLE_NOTARY_USERNAME"], "--password", os.environ["APPLE_NOTARY_PASSWORD"],
        "--team-id", team)
    with open(os.environ["GITHUB_ENV"], "a") as output:
        for name, value in {"DEVELOPER_ID_APPLICATION": identities[0],
                            "ILLIQUID_SIGNING_KEYCHAIN": str(keychain),
                            "ILLIQUID_NOTARY_KEYCHAIN": str(keychain),
                            "ILLIQUID_NOTARY_PROFILE": "illiquid-notary"}.items():
            if "\n" in value or "\r" in value:
                raise SystemExit("Invalid multiline signing configuration")
            output.write(f"{name}={value}\n")
    print("Configured Illiquid Developer ID signing and validated notarization credentials")
finally:
    certificate.unlink(missing_ok=True)
