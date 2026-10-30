#!/usr/bin/env python3
"""Run the immutable PR206 corpus against canonical sources, not historical timings."""
from pathlib import Path
import sys
HERE = Path(__file__).resolve().parent / "ThumbnailSamplePlanning"
ROOT = Path(__file__).resolve().parents[3]
source = (HERE / "run.py").read_text()
source = source.replace('ROOT = Path(__file__).resolve().parents[2]', 'ROOT = ' + repr(str(ROOT)) + '\nROOT = Path(ROOT)')
source = source.replace('"ThumbnailSamplePlanningTests")', '"ThumbnailSamplePlanningTests", "ThumbnailSamplePrefixTests", "ThumbnailSamplePlanningAlternativeTests")')
exec(compile(source, str(HERE / "run.py"), "exec"), {"__name__": "__main__", "__file__": str(HERE / "run.py")})
