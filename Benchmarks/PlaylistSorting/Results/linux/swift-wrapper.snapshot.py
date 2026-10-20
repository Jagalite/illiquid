#!/usr/bin/env python3
import os, sys
swift = "/tmp/illiquid-swift-6.3.2/usr/bin/swift"
env = os.environ.copy()
lib = "/tmp/illiquid-swift-deps/usr/lib/x86_64-linux-gnu"
env["LD_LIBRARY_PATH"] = lib + ((":" + env["LD_LIBRARY_PATH"]) if env.get("LD_LIBRARY_PATH") else "")
args = sys.argv[1:]
if args and args[0] in ("build", "test"):
    args.insert(1, "--use-integrated-swift-driver")
os.execve(swift, [swift, *args], env)
