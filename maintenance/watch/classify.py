#!/usr/bin/env python3
"""classify.py — classify an upstream drift signal as minor | major | breaking.

Pure functions, importable by collect-drift.py (the watcher) AND the later fix-router.
Rules mirror plan.md "Change classification":

  minor     additive / in-range / no deploy-affecting change → auto-PR candidate
  major     pin floor/ceiling change, api-version change, renamed surface, new/removed
            deploy path, OR a `latest` that fails the harness → gated (approval required)
  breaking  the PINNED set itself regresses (red on what we ship) → gated + blocker

This module only sees registry + upstream metadata, so it classifies *structurally*.
Harness results (which can promote minor→major or flag breaking) are merged in later by
the E2E layer; `escalate_with_harness()` expresses that.
"""
from __future__ import annotations

from packaging.specifiers import SpecifierSet
from packaging.version import InvalidVersion, Version

MINOR, MAJOR, BREAKING = "minor", "major", "breaking"


def _spec_of(requirement: str, name: str) -> str:
    spec = requirement.split(name, 1)[1].lstrip()
    # drop a leading extras group, e.g. "[opentelemetry]>=1.2.3" -> ">=1.2.3"
    if spec.startswith("["):
        spec = spec[spec.index("]") + 1:].lstrip()
    return spec


def _is_exact(spec: str) -> bool:
    return spec.startswith("==")


def classify_package(pkg: dict, latest: str | None) -> tuple[str, str]:
    """Return (classification, reason) for a package row given the latest PyPI version."""
    name = pkg["name"]
    spec = _spec_of(pkg["requirement"], name)
    if not latest:
        return MINOR, "no upstream version observed"
    try:
        lv = Version(latest)
    except InvalidVersion:
        return MAJOR, f"unparseable upstream version {latest!r} — needs human review"

    try:
        admits = lv in SpecifierSet(spec, prereleases=True)
    except Exception:
        return MAJOR, f"unparseable specifier {spec!r}"

    if _is_exact(spec):
        pinned = spec[2:]
        if pinned == latest:
            return MINOR, "exact pin matches latest"
        return MAJOR, f"exact pin {spec} != latest {latest} (pin change required)"

    if not admits:
        return MAJOR, f"latest {latest} excluded by pin {spec} (ceiling bump)"

    try:
        floor = Version(str(pkg.get("floor") or "0"))
        if lv.major > floor.major:
            return MAJOR, f"in-range but major-version jump {floor.major}->{lv.major}"
    except InvalidVersion:
        pass
    return MINOR, f"latest {latest} satisfied by {spec} (no pin change)"


def classify_api_version(pin: str, latest_ga: str | None) -> tuple[str, str]:
    if not latest_ga:
        return MINOR, "no GA observed (data-plane/preview or unqueryable)"
    if latest_ga == pin:
        return MINOR, "api-version current"
    return MAJOR, f"newer GA api-version {latest_ga} > pinned {pin}"


def classify_doc(changed: bool, first_seen: bool) -> tuple[str, str]:
    if first_seen:
        return MINOR, "baseline hash recorded (first observation)"
    if changed:
        return MAJOR, "doc content changed — owning skill needs review"
    return MINOR, "doc unchanged"


def escalate_with_harness(structural: str, harness: str | None) -> str:
    """Merge a structural class with a harness verdict on the PINNED set."""
    if harness == "fail":
        return BREAKING
    return structural
