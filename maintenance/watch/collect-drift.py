#!/usr/bin/env python3
"""collect-drift.py — the upstream watcher (W2-T2).

Polls three signals, normalizes them into one structured drift-report.json, and classifies
each finding (W2-T3 via classify.py). REPORT-ONLY by default — it never edits versions.yaml,
never opens PRs. The workflow (upstream-watch.yml) runs this; the fix-router consumes the report.

Signals:
  1. PyPI       latest version per package in maintenance/versions.yaml
  2. api-version latest GA per ARM resource type (via `az provider show`)
  3. docs        content hash per Learn topic in maintenance/watch/doc-sources.yaml,
                 diffed against maintenance/watch/doc-baseline.json

Flags:
  --offline               skip all network (PyPI + docs); az still attempted unless --no-az
  --no-az                 skip api-version polling
  --update-doc-baseline   record current doc hashes as the new baseline (use after review)
  --out PATH              drift-report.json path (default maintenance/watch/drift-report.json)
  --summary PATH          markdown summary path (default: stdout only)

Dependency-light: pyyaml + packaging (installed in CI) + stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import classify  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
REG = REPO / "maintenance" / "versions.yaml"
DOC_SOURCES = REPO / "maintenance" / "watch" / "doc-sources.yaml"
DOC_BASELINE = REPO / "maintenance" / "watch" / "doc-baseline.json"
DEFAULT_OUT = REPO / "maintenance" / "watch" / "drift-report.json"

UA = {"User-Agent": "foundry-skillpack-watcher/1.0"}


def _get(url: str, timeout: int = 20) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (trusted hosts)
        return r.read()


# ---------- 1. PyPI ----------

def poll_pypi(name: str) -> str | None:
    try:
        data = json.loads(_get(f"https://pypi.org/pypi/{name}/json"))
        return data["info"]["version"]
    except Exception as e:  # network / 404 / parse
        print(f"[warn] pypi {name}: {e}", file=sys.stderr)
        return None


# ---------- 2. api-versions ----------

def poll_api_version(resource_type: str) -> str | None:
    """Latest GA api-version (non -preview) for an ARM 'Namespace/type' string."""
    if "/" not in resource_type or resource_type.startswith("Microsoft.CognitiveServices ("):
        return None  # data-plane/preview rows are not ARM-queryable
    ns, _, rtype = resource_type.partition("/")
    try:
        out = subprocess.check_output(
            ["az", "provider", "show", "-n", ns,
             "--query", f"resourceTypes[?resourceType=='{rtype}'].apiVersions",
             "-o", "tsv"],
            stderr=subprocess.DEVNULL, timeout=60, text=True,
        )
        versions = [v for v in re.split(r"\s+", out.strip()) if v]
        ga = sorted(v for v in versions if not v.endswith("-preview"))
        return ga[-1] if ga else None
    except Exception as e:
        print(f"[warn] az provider show {ns}/{rtype}: {e}", file=sys.stderr)
        return None


# ---------- 3. docs ----------

def _normalize_html(raw: bytes) -> str:
    text = raw.decode("utf-8", "replace")
    text = re.sub(r"(?is)<(script|style|nav|header|footer).*?</\1>", " ", text)
    text = re.sub(r"(?s)<!--.*?-->", " ", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)         # strip tags
    text = re.sub(r"\s+", " ", text)                  # collapse whitespace
    return text.strip()


def doc_hash(url: str) -> str | None:
    try:
        return hashlib.sha256(_normalize_html(_get(url)).encode()).hexdigest()
    except Exception as e:
        print(f"[warn] doc {url}: {e}", file=sys.stderr)
        return None


# ---------- assemble ----------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--no-az", action="store_true")
    ap.add_argument("--update-doc-baseline", action="store_true")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--summary", default=None)
    args = ap.parse_args()

    reg = yaml.safe_load(REG.read_text())
    doc_cfg = yaml.safe_load(DOC_SOURCES.read_text())
    baseline = json.loads(DOC_BASELINE.read_text()) if DOC_BASELINE.exists() else {}

    report: dict = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_tag": reg["meta"]["baseline_tag"],
        "mode": "report-only",
        "packages": [], "api_versions": [], "docs": [],
        "summary": {"minor": 0, "major": 0, "breaking": 0},
    }

    def bump(cls: str):
        report["summary"][cls] = report["summary"].get(cls, 0) + 1

    # 1. packages
    for p in reg["packages"]:
        latest = None if args.offline else poll_pypi(p["name"])
        cls, reason = classify.classify_package(p, latest)
        if cls != "minor":
            bump(cls)
        report["packages"].append({
            "name": p["name"], "pin": p["requirement"].split(p["name"], 1)[1],
            "latest": latest, "latest_seen_registry": p.get("latest_seen"),
            "class": cls, "reason": reason, "finding": p.get("finding"),
            "source_url": p.get("source_url"),
        })

    # 2. api-versions
    for a in reg["api_versions"]:
        latest = None if (args.offline or args.no_az) else poll_api_version(a["resource_type"])
        cls, reason = classify.classify_api_version(a["pin"], latest)
        if cls != "minor":
            bump(cls)
        report["api_versions"].append({
            "resource_type": a["resource_type"], "pin": a["pin"],
            "latest_ga": latest, "class": cls, "reason": reason, "finding": a.get("finding"),
        })

    # 3. docs
    new_baseline = dict(baseline)
    for d in doc_cfg["docs"]:
        h = None if args.offline else doc_hash(d["url"])
        first_seen = d["id"] not in baseline
        changed = bool(h) and not first_seen and baseline.get(d["id"]) != h
        cls, reason = classify.classify_doc(changed, first_seen and bool(h))
        if cls != "minor":
            bump(cls)
        if h:
            new_baseline[d["id"]] = h if (first_seen or args.update_doc_baseline) else baseline.get(d["id"], h)
        report["docs"].append({
            "id": d["id"], "url": d["url"], "owner": d["owner"],
            "changed": changed, "first_seen": first_seen and bool(h),
            "class": cls, "reason": reason,
        })

    # persist
    Path(args.out).write_text(json.dumps(report, indent=2) + "\n")
    fetched_docs = any(d.get("first_seen") or d.get("changed") for d in report["docs"]) or \
        any(new_baseline.get(d["id"]) for d in doc_cfg["docs"])
    if not args.offline and (args.update_doc_baseline or not DOC_BASELINE.exists()) and fetched_docs:
        existed = DOC_BASELINE.exists()
        DOC_BASELINE.write_text(json.dumps(new_baseline, indent=2, sort_keys=True) + "\n")
        print(f"[i] doc baseline {'updated' if existed else 'created'} "
              f"({len(new_baseline)} topics)", file=sys.stderr)

    md = render_markdown(report)
    if args.summary:
        Path(args.summary).write_text(md)
    print(md)
    return 0


def render_markdown(r: dict) -> str:
    s = r["summary"]
    lines = [
        f"# Upstream drift report — {r['generated_at']}",
        f"_baseline `{r['baseline_tag']}` · mode {r['mode']}_",
        "",
        f"**Summary:** {s.get('major',0)} major · {s.get('breaking',0)} breaking · "
        f"{s.get('minor',0)} minor-tracked.",
        "",
        "## Packages (non-minor)",
        "| package | pin | latest | class | reason | finding |",
        "|---|---|---|---|---|---|",
    ]
    for p in r["packages"]:
        if p["class"] == "minor" and not (p["latest"] and p["latest"] != p["latest_seen_registry"]):
            continue
        lines.append(f"| `{p['name']}` | `{p['pin']}` | {p['latest'] or '-'} | "
                     f"{p['class']} | {p['reason']} | {p['finding'] or '-'} |")
    lines += ["", "## api-versions (non-minor)",
              "| resource type | pin | latest GA | class | finding |", "|---|---|---|---|---|"]
    for a in r["api_versions"]:
        if a["class"] == "minor":
            continue
        lines.append(f"| {a['resource_type']} | `{a['pin']}` | {a['latest_ga'] or '-'} | "
                     f"{a['class']} | {a['finding'] or '-'} |")
    changed_docs = [d for d in r["docs"] if d["changed"] or d["first_seen"]]
    lines += ["", "## docs (changed / first-seen)",
              "| topic | owner | state |", "|---|---|---|"]
    for d in changed_docs:
        state = "first-seen" if d["first_seen"] else "CHANGED"
        lines.append(f"| {d['id']} | {d['owner']} | {state} |")
    if not changed_docs:
        lines.append("| _none_ | | |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit(main())
