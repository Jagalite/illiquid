#!/usr/bin/env python3
"""Run a benchmark through a low-footprint interpreter and a fresh fork.

An exec alone can retain a large launcher's process RSS high-water mark.
The interpreter has already discarded that launcher's resident allocations;
forking here resets the child's high-water mark to this small resident set.
The benchmark still measures its complete cold process peak, not isolated heap.
"""
import os
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: fresh_process.py EXECUTABLE [ARG ...]")
    child = os.fork()
    if child == 0:
        try:
            os.execv(sys.argv[1], sys.argv[1:])
        except OSError as error:
            print(f"cannot execute benchmark: {error}", file=sys.stderr, flush=True)
            os._exit(127)
    _, status = os.waitpid(child, 0)
    code = os.waitstatus_to_exitcode(status)
    raise SystemExit(code if code >= 0 else 128 - code)


if __name__ == "__main__":
    main()
