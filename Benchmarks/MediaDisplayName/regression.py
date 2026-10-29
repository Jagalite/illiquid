"""Explicit correctness-only comparison against frozen focal code and current support."""
import hashlib

BASELINE_SHA256 = "546229819194a5844bc052e3837a21296921f4b11e6191ebdc82c0c7c5e64910"
CANDIDATE_SHA256 = "cc3c1ac628498798384c3e93973ffa0dcd6f21036b1f1de779cd54c82cc944d1"

# Only these reviewed integration changes may replace historical support bytes.
SUPPORT_PINS = {
    "MediaMetadataHints.swift": "9df354b5f319aee2d29799b601562e46571d664650bfb298133f7425939ba53a",
    "Sources/IlliquidCore/MediaMetadataHints.swift": "9df354b5f319aee2d29799b601562e46571d664650bfb298133f7425939ba53a",
    "Sources/IlliquidApp/SidebarValues.swift": "23bdbd458576bb1889df14cd8881c23a71e3a338840c6dcb3eff30e3d3c3920a",
}


def validate_mode(enabled, correctness_only, *, skip_tests=False, summarize_only=False):
    if enabled and (not correctness_only or skip_tests or summarize_only):
        raise ValueError("Current-source regression requires complete correctness-only verification; timing, skipped tests and summary replay are forbidden")


def select_sources(baseline, candidate, focal):
    if baseline.keys() != candidate.keys() or focal not in baseline:
        raise ValueError("Regression source inventories differ or focal source is missing")
    digest = lambda raw: hashlib.sha256(raw).hexdigest()
    if digest(baseline[focal]) != BASELINE_SHA256:
        raise ValueError("Frozen focal baseline changed")
    if baseline[focal] == candidate[focal]:
        raise ValueError("Regression candidate is a no-op focal replacement")
    if digest(candidate[focal]) != CANDIDATE_SHA256:
        raise ValueError("Candidate focal source differs from the exact reviewed pin")
    for name in baseline:
        if name != focal and baseline[name] != candidate[name]:
            if digest(candidate[name]) != SUPPORT_PINS.get(name):
                raise ValueError(f"Unreviewed unrelated support change: {name}")
    selected = {name: baseline[name] if name == focal else raw for name, raw in candidate.items()}
    receipt = {
        "mode": "current-source-regression", "timing_allowed": False,
        "baseline_focal_revision": "ea2ff568237e2667f7b1aeee67b11a44ebe95b72",
        "sources": {name: {
            "role": "focal" if name == focal else "support",
            "baseline_origin": "frozen-baseline" if name == focal else "captured-current-source",
            "candidate_origin": "captured-current-source",
            "historical_sha256": digest(baseline[name]),
            "baseline_sha256": digest(selected[name]), "candidate_sha256": digest(candidate[name]),
        } for name in candidate},
        "qualification": "Current-source correctness regression only; not historical performance qualification",
    }
    return selected, receipt
