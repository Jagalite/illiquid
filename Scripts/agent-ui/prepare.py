#!/usr/bin/env python3
"""Compile both cached helpers without launching an app or posting input.

Submit this command through the local build coordinator before UI operations.
"""
import json
from pathlib import Path
import sys

from agent_ui import Adapter, Failure, ROOT, envelope


def main():
    try:
        adapter = Adapter()
        paths = [adapter.compile(source) for source in (
            Path(__file__).with_name("native.swift"),
            ROOT / "Scripts/performance-app-control.swift",
        )]
        result = envelope(data={"helpers": [str(path) for path in paths],
                                "scope": "helper compilation only; no UI or product qualification"})
    except Failure as exc:
        result = envelope(exc.status, exc.data, str(exc))
    except (OSError, ValueError, TypeError) as exc:
        result = envelope("error", error=f"{type(exc).__name__}: {exc}")
    except KeyboardInterrupt:
        result = envelope("error", error="helper preparation interrupted")
    print(json.dumps(result))
    return 0 if result["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
