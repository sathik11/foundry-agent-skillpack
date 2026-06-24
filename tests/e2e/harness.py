#!/usr/bin/env python3
"""harness.py — W4 smoke harness: run a scenario JOURNEY through the guarded driver (W3) against
the provisioned baseline, then check deterministic assertions on the produced artifacts.

This is the user-replication smoke test the maintainer described: drive the /commands via the LLM
on real infra, capture the result, assert the expected artifacts/state, and emit a verdict +
feedback bundle to iterate on. The DRIVER verdict (how the run went) and the ASSERTION verdict
(did it produce the right artifacts) are reported separately.

Usage:
  harness.py --scenario tests/e2e/scenarios/01-greenfield.yaml \
      --workdir <agent-repo-root> [--backend opencode] [--run-id <id>] [--skip-driver]

  --skip-driver   only re-check assertions against an existing workdir (no LLM run) — for
                  iterating on assertions without burning a full journey.

Exit: 0 only if BOTH driver verdict == completed AND all assertions pass.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DRIVER = HERE / "driver" / "run_driver.py"


def load_status(workdir: Path, agent_rel: str | None) -> dict | None:
    """Find agent-status.json under the workdir (best-effort)."""
    candidates = []
    if agent_rel:
        candidates.append(workdir / agent_rel / "agent-status.json")
    candidates += list(workdir.glob("agents/*/agent-status.json"))
    for c in candidates:
        if c.exists():
            try:
                return json.loads(c.read_text())
            except json.JSONDecodeError:
                return None
    return None


def dotted(d: dict, path: str):
    cur = d
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def check_assertions(scenario: dict, workdir: Path) -> list[dict]:
    results = []
    status = load_status(workdir, _agent_rel(scenario))
    for a in scenario.get("assertions", []):
        kind = a["kind"]
        ok = False
        detail = ""
        if kind == "path_exists":
            ok = (workdir / a["path"]).exists()
            detail = a["path"]
        elif kind == "agent_status":
            if status is None:
                detail = "agent-status.json not found"
            else:
                val = dotted(status, a["field"])
                ok = (val == a.get("equals"))
                detail = f"{a['field']}={val!r} (want {a.get('equals')!r})"
        else:
            detail = f"unknown assertion kind {kind}"
        results.append({"kind": kind, "desc": a.get("desc", ""), "ok": ok, "detail": detail})
    return results


def _agent_rel(scenario: dict) -> str | None:
    for a in scenario.get("assertions", []):
        if a.get("kind") == "path_exists" and "/agent-capabilities.yaml" in a.get("path", ""):
            return str(Path(a["path"]).parent)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--backend", default="opencode", choices=["opencode", "codex"])
    ap.add_argument("--model", default=None)
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--skip-driver", action="store_true")
    args = ap.parse_args()

    scenario = yaml.safe_load(Path(args.scenario).read_text())
    workdir = Path(args.workdir).resolve()
    run_id = args.run_id or f"{scenario['id']}-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}"
    art = REPO / "tests" / "e2e" / "artifacts" / run_id
    art.mkdir(parents=True, exist_ok=True)

    driver_verdict = {"verdict": "skipped", "reason": "--skip-driver"}
    if not args.skip_driver:
        budgets = scenario.get("budgets", {})
        prompt_file = art / "prompt.md"
        prompt_file.write_text(scenario["prompt"])
        cmd = [
            sys.executable, str(DRIVER),
            "--backend", args.backend,
            "--prompt-file", str(prompt_file),
            "--workdir", str(workdir),
            "--artifacts", str(art),
            "--wall-clock", str(budgets.get("wall_clock", 2400)),
            "--no-progress", str(budgets.get("no_progress", 1200)),
            "--loop-threshold", str(budgets.get("loop_threshold", 4)),
        ]
        if args.model:
            cmd += ["--model", args.model]
        print(f"[harness] running driver for scenario '{scenario['id']}' (run {run_id})…")
        subprocess.run(cmd)
        vf = art / "verdict.json"
        driver_verdict = json.loads(vf.read_text()) if vf.exists() else {"verdict": "unknown", "reason": "no verdict.json"}

    assertions = check_assertions(scenario, workdir)
    passed = sum(a["ok"] for a in assertions)
    total = len(assertions)
    all_ok = passed == total and driver_verdict.get("verdict") in ("completed", "skipped")

    report = {
        "scenario": scenario["id"],
        "run_id": run_id,
        "backend": args.backend,
        "driver_verdict": driver_verdict.get("verdict"),
        "driver_reason": driver_verdict.get("reason"),
        "assertions_passed": passed,
        "assertions_total": total,
        "assertions": assertions,
        "overall": "pass" if all_ok else "fail",
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
    (art / "harness-report.json").write_text(json.dumps(report, indent=2) + "\n")

    print(f"\n=== Smoke report: {scenario['id']} ({run_id}) ===")
    print(f"driver: {report['driver_verdict']} ({report['driver_reason']})")
    for a in assertions:
        print(f"  [{'ok' if a['ok'] else 'FAIL'}] {a['desc']}: {a['detail']}")
    print(f"assertions: {passed}/{total}")
    print(f"OVERALL: {report['overall'].upper()}")
    print(f"artifacts: {art}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
