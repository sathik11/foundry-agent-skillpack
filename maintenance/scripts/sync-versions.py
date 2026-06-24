#!/usr/bin/env python3
"""sync-versions.py — render shipped pin files + docs from maintenance/versions.yaml.

SINGLE SOURCE OF TRUTH = maintenance/versions.yaml. This script is the only thing allowed
to write the pinned-dependency regions of the shipped files. Those regions are delimited by
markers so human prose around them is preserved.

Usage:
  sync-versions.py --check     # exit 1 if any managed block drifts from versions.yaml (CI gate)
  sync-versions.py --write     # rewrite managed blocks in place
  sync-versions.py --report    # print the registry vs latest_seen drift summary (no file I/O)

Maintainer/CI-only. Never shipped (lives under maintenance/, outside .apm/).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
REG = REPO / "maintenance" / "versions.yaml"

DEPLOY = REPO / "foundry-agent-skillpack" / ".apm" / "skills" / "foundry-deploy"

# (file, marker_id, kind) where kind selects comment syntax: "pip" or "md"
# Each marker_id maps to a render function below.
TARGETS = [
    (DEPLOY / "templates" / "requirements.txt.template", "container_agent_framework", "pip"),
    (DEPLOY / "templates" / "langgraph-byo" / "requirements.txt.template", "container_langgraph", "pip"),
    (DEPLOY / "sdk-surface.md", "sdk_surface_table", "md"),
    (REPO / "README.md", "supported_sdk", "md"),
    (REPO / "maintenance" / "SUPPORTED.md", "supported_sdk_full", "md"),
]


def load_registry() -> dict:
    with REG.open() as fh:
        return yaml.safe_load(fh)


def pkg_index(reg: dict) -> dict[str, dict]:
    return {p["name"]: p for p in reg["packages"]}


def _spec(pkg: dict) -> str:
    """Version specifier portion of the requirement (everything after the name)."""
    return pkg["requirement"].split(pkg["name"], 1)[1].lstrip()


# ---------- renderers (return the lines that go BETWEEN the markers) ----------

def render_requirements(reg: dict, profile: str) -> list[str]:
    idx = pkg_index(reg)
    return [idx[name]["requirement"] for name in reg["profiles"][profile]]


def render_sdk_table(reg: dict, *_a) -> list[str]:
    idx = pkg_index(reg)
    out = ["| Package | Pin |", "|---|---|"]
    for name in reg["profiles"]["sdk_surface_table"]:
        out.append(f"| `{name}` | `{_spec(idx[name])}` |")
    return out


def _supported_rows(reg: dict) -> list[str]:
    idx = pkg_index(reg)
    rows = ["| Package | Supported version | Path |", "|---|---|---|"]
    seen: set[str] = set()
    for profile in ("container_agent_framework", "container_langgraph", "caller_side"):
        for name in reg["profiles"][profile]:
            if name in seen:
                continue
            seen.add(name)
            p = idx[name]
            rows.append(f"| `{name}` | `{_spec(p)}` | {p['deploy_path']} |")
    return rows


def render_supported_sdk(reg: dict, *_a) -> list[str]:
    """Compact block for README."""
    m = reg["meta"]
    out = [
        f"> **Supported SDK matrix** — verified {m['last_verified']} against baseline "
        f"`{m['baseline_tag']}`. Generated from `maintenance/versions.yaml`; do not edit by hand.",
        "",
    ]
    out += _supported_rows(reg)
    return out


def render_supported_sdk_full(reg: dict, *_a) -> list[str]:
    """Full mirror for maintenance/SUPPORTED.md (packages + api-versions)."""
    m = reg["meta"]
    out = [
        f"_Verified {m['last_verified']} · baseline `{m['baseline_tag']}` · skillpack "
        f"v{m['skillpack_version']}. Generated from `maintenance/versions.yaml`._",
        "",
        "## Supported SDK packages",
        "",
    ]
    out += _supported_rows(reg)
    out += ["", "## Supported ARM api-versions", "", "| Resource type | Pinned api-version |", "|---|---|"]
    for a in reg["api_versions"]:
        out.append(f"| {a['resource_type']} | `{a['pin']}` |")
    return out


RENDERERS = {
    "container_agent_framework": render_requirements,
    "container_langgraph": render_requirements,
    "sdk_surface_table": render_sdk_table,
    "supported_sdk": render_supported_sdk,
    "supported_sdk_full": render_supported_sdk_full,
}


# ---------- marker handling ----------

def markers(marker_id: str, kind: str) -> tuple[str, str]:
    if kind == "pip":
        return (f"# >>> versions:auto:{marker_id} >>>", f"# <<< versions:auto:{marker_id} <<<")
    return (f"<!-- versions:auto:{marker_id} -->", f"<!-- /versions:auto:{marker_id} -->")


def splice(text: str, start: str, end: str, body: list[str]) -> str:
    lines = text.splitlines()
    try:
        i = next(n for n, ln in enumerate(lines) if ln.strip() == start)
        j = next(n for n, ln in enumerate(lines) if ln.strip() == end)
    except StopIteration:
        raise SystemExit(
            f"[!] markers not found ({start} / {end}). Add them to the file once, then re-run --write."
        )
    if j <= i:
        raise SystemExit(f"[!] end marker precedes start marker for {start}")
    new = lines[: i + 1] + body + lines[j:]
    return "\n".join(new) + ("\n" if text.endswith("\n") else "")


def process(write: bool) -> int:
    reg = load_registry()
    drift = 0
    for path, marker_id, kind in TARGETS:
        start, end = markers(marker_id, kind)
        if not path.exists():
            if marker_id == "supported_sdk_full":
                path.write_text(
                    "<!-- MAINTAINER/CI-ONLY — generated. Do not edit. -->\n"
                    "# Supported SDK & api-versions\n\n"
                    f"{start}\n{end}\n"
                )
            else:
                print(f"[!] target missing: {path}")
                drift += 1
                continue
        body = RENDERERS[marker_id](reg, marker_id)
        text = path.read_text()
        if marker_id == "supported_sdk_full" and start not in text:
            text = (
                "<!-- MAINTAINER/CI-ONLY — generated. Do not edit. -->\n"
                "# Supported SDK & api-versions\n\n"
                f"{start}\n{end}\n"
            )
        updated = splice(text, start, end, body)
        if updated != text:
            drift += 1
            rel = path.relative_to(REPO)
            if write:
                path.write_text(updated)
                print(f"[~] wrote {rel}")
            else:
                print(f"[drift] {rel} (block '{marker_id}' out of sync with versions.yaml)")
    return drift


def report() -> int:
    reg = load_registry()
    print(f"# versions.yaml — baseline {reg['meta']['baseline_tag']} (verified {reg['meta']['last_verified']})\n")
    print(f"{'package':40} {'pinned':28} {'latest_seen':16} finding")
    for p in reg["packages"]:
        spec = _spec(p) or "(=)"
        latest = p.get("latest_seen") or "-"
        finding = p.get("finding")
        flag = f"  <-- {finding}" if finding else ""
        print(f"{p['name']:40} {spec:28} {str(latest):16} {finding or '-'}{flag}")
    print("\n# api-versions")
    for a in reg["api_versions"]:
        latest = a.get("latest_ga_seen") or "-"
        finding = a.get("finding")
        flag = f"  <-- {finding}" if finding else ""
        print(f"{a['resource_type']:55} {a['pin']:22} -> {latest}{flag}")
    print("\n(DRIFT = an open finding in maintenance/findings-backlog.md; in-range floor pins are not flagged)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="exit 1 on drift (CI gate)")
    g.add_argument("--write", action="store_true", help="rewrite managed blocks")
    g.add_argument("--report", action="store_true", help="print registry vs latest_seen")
    args = ap.parse_args()

    if args.report:
        return report()
    if args.write:
        process(write=True)
        return 0
    drift = process(write=False)
    if drift:
        print(f"\n[!] {drift} managed block(s) drifted. Run: python maintenance/scripts/sync-versions.py --write")
        return 1
    print("[ok] all managed blocks match versions.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
