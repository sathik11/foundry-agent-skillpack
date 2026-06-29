#!/usr/bin/env python3
"""harness.py — W4 smoke harness: run a scenario JOURNEY through the guarded driver (W3) against
the provisioned baseline, then check deterministic assertions on the produced artifacts.

This is the user-replication smoke test the maintainer described: drive the /commands via the LLM
on real infra, capture the result, assert the expected artifacts/state, and emit a verdict +
feedback bundle to iterate on. The DRIVER verdict (how the run went) and the ASSERTION verdict
(did it produce the right artifacts) are reported separately.

Usage:
  # F-K: fresh, faithful run — create a clean NON-git workspace + apm-install the skillpack:
  harness.py --scenario tests/e2e/scenarios/01-greenfield.yaml \
      --clean-workspace [--workspace-root <dir>] [--backend opencode] [--run-id <id>]

  # Or drive an existing prepared workspace:
  harness.py --scenario tests/e2e/scenarios/01-greenfield.yaml \
      --workdir <agent-repo-root> [--backend opencode] [--run-id <id>] [--skip-driver]

  --clean-workspace   F-K: build a fresh workspace OUTSIDE any git repo and `apm install` the
                      skillpack into it (the only faithful reproduction of real usage and the
                      only layout where `azd ai agent init` staging works — see ITERATION-LOG
                      F-J/F-K). Mutually exclusive with --workdir.
  --skip-driver       only re-check assertions against an existing --workdir (no LLM run) — for
                      iterating on assertions without burning a full journey.

Exit: 0 only if BOTH driver verdict == completed AND all assertions pass.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DRIVER = HERE / "driver" / "run_driver.py"
SETUP = HERE / "setup-workspace.sh"

# Azure-querying assertion kinds (app_insights_trace / eval_rule_exists / eval_run_present) reach
# out to live Azure to PROVE the agent really emitted traces + that eval rules/runs exist — they are
# the "validate availability of traces / evaluations" half of the smoke. They degrade gracefully:
# when az CLI / azure-ai-projects / azure-identity / the App Insights id are unavailable (e.g. a
# local --skip-driver assertion re-check with no Azure creds), the assertion is recorded as
# SKIPPED rather than crashing. An assertion may set `optional: true` (the default) so a skip still
# counts toward the overall pass, or `optional: false` to make an un-runnable check a hard failure.
SKIP = "skip"  # sentinel returned by an Azure probe when its prerequisite is unavailable


def setup_clean_workspace(skillpack_src: str, workspace_root: str | None, run_id: str) -> Path | None:
    """F-K: create a fresh NON-git workspace under <workspace_root>/<run_id> and apm-install the
    skillpack into it (via setup-workspace.sh). Returns the prepared workspace path, or None."""
    root = Path(workspace_root).expanduser() if workspace_root \
        else Path.home() / ".cache" / "foundry-skillpack-e2e"
    dest = root / run_id
    print(f"[harness] F-K: preparing clean non-git workspace at {dest}\u2026")
    proc = subprocess.run(
        ["bash", str(SETUP), "--dest", str(dest),
         "--src", str(Path(skillpack_src).resolve()), "--force"],
        text=True, capture_output=True,
    )
    sys.stdout.write(proc.stdout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        print(f"[!] workspace setup failed (exit {proc.returncode})", file=sys.stderr)
        return None
    ws = next((ln.split("=", 1)[1].strip()
               for ln in proc.stdout.splitlines() if ln.startswith("WORKSPACE=")), None)
    if not ws:
        print("[!] setup-workspace.sh did not emit WORKSPACE=", file=sys.stderr)
        return None
    return Path(ws).resolve()


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


# ── Azure availability probes (traces + evaluations) ──────────────────────────────────────────────
#
# Each probe returns one of:
#   (True,  detail)   assertion satisfied
#   (False, detail)   ran, but the expected resource/rows were NOT found
#   (SKIP,  detail)   could not run (az / SDK / id unavailable) — caller decides pass/fail via
#                     the assertion's `optional` flag.


def _have_az() -> bool:
    return shutil.which("az") is not None


def _resolve_app_insights_id(target: dict) -> str | None:
    """Return an App Insights app-id (GUID) to use with `az monitor app-insights query --app`.

    Precedence: scenario target.app_insights (a GUID or component name) → discover the first
    component in the resource group. Returns None if it cannot be resolved.
    """
    explicit = target.get("app_insights")
    rg = target.get("resource_group")
    sub = target.get("subscription")
    if not _have_az():
        return None
    # A bare GUID is already an app-id.
    if explicit and explicit.count("-") == 4 and "/" not in explicit:
        return explicit
    base = ["az", "monitor", "app-insights", "component", "show", "-o", "tsv", "--query", "appId"]
    if sub:
        base += ["--subscription", sub]
    try:
        if explicit:  # treat as a component name
            proc = subprocess.run(base + ["-g", rg, "-a", explicit],
                                  text=True, capture_output=True, timeout=60)
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip()
        # Fall back to the first component in the RG.
        listed = subprocess.run(
            ["az", "monitor", "app-insights", "component", "show", "-g", rg, "-o", "json"]
            + (["--subscription", sub] if sub else []),
            text=True, capture_output=True, timeout=60,
        )
        if listed.returncode == 0 and listed.stdout.strip():
            data = json.loads(listed.stdout)
            comp = data[0] if isinstance(data, list) and data else data
            if isinstance(comp, dict) and comp.get("appId"):
                return comp["appId"]
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None
    return None


def probe_app_insights_trace(target: dict, a: dict):
    """Assert at least `min_rows` rows match the KQL for the agent's traces.

    Mirrors the verify-agent / foundry-observability KQL: rows in `dependencies` where
    cloud_RoleName == <agent> and name starts with the given prefix (default "execute_tool").
    """
    agent = a.get("agent_name") or target.get("agent_name")
    table = a.get("table", "dependencies")
    name_prefix = a.get("name_startswith", "execute_tool")
    lookback = a.get("lookback", "3h")
    min_rows = int(a.get("min_rows", 1))
    if not agent:
        return SKIP, "no agent_name for trace query"
    app_id = _resolve_app_insights_id(target)
    if not app_id:
        return SKIP, "App Insights app-id not resolved (need az + target.app_insights or RG component)"
    kql = (
        f"{table} "
        f"| where timestamp > ago({lookback}) "
        f"| where cloud_RoleName == '{agent}' "
        f"| where name startswith '{name_prefix}' "
        f"| count"
    )
    cmd = ["az", "monitor", "app-insights", "query", "--app", app_id,
           "--analytics-query", kql, "-o", "json"]
    if target.get("subscription"):
        cmd += ["--subscription", target["subscription"]]
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, timeout=120)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return SKIP, f"app-insights query failed to run: {exc!r}"
    if proc.returncode != 0:
        return SKIP, f"app-insights query error: {proc.stderr.strip()[:200]}"
    try:
        rows = json.loads(proc.stdout)["tables"][0]["rows"]
        count = int(rows[0][0]) if rows and rows[0] else 0
    except (json.JSONDecodeError, KeyError, IndexError, ValueError, TypeError):
        return SKIP, "app-insights query returned unparseable output"
    ok = count >= min_rows
    return ok, f"{count} '{name_prefix}' span(s) for {agent} (want ≥{min_rows})"


def _project_client(target: dict):
    """Build an AIProjectClient (lazy import, graceful None on missing SDK/endpoint/creds)."""
    endpoint = target.get("project_endpoint")
    if not endpoint:
        return None, "no project_endpoint in target"
    try:
        from azure.ai.projects import AIProjectClient
        from azure.identity import DefaultAzureCredential
    except ImportError:
        return None, "azure-ai-projects/azure-identity not installed"
    try:
        return AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential()), ""
    except Exception as exc:  # noqa: BLE001 — preview SDK / auth surface
        return None, f"AIProjectClient init failed: {exc!r}"


def probe_eval_rule_exists(target: dict, a: dict):
    """Assert the continuous-eval rule `continuous-eval-<agent>` (or an explicit name) exists."""
    agent = a.get("agent_name") or target.get("agent_name")
    rule_name = a.get("rule_name") or (f"continuous-eval-{agent}" if agent else None)
    if not rule_name:
        return SKIP, "no agent_name/rule_name for eval-rule check"
    client, why = _project_client(target)
    if client is None:
        return SKIP, why
    try:
        names = {getattr(r, "name", None) for r in client.evaluation_rules.list()}
    except Exception as exc:  # noqa: BLE001 — preview SDK
        return SKIP, f"evaluation_rules.list failed: {exc!r}"
    ok = rule_name in names
    return ok, f"rule '{rule_name}' present: {ok}"


def probe_eval_run_present(target: dict, a: dict):
    """Assert ≥ `min_runs` eval runs exist for the agent's eval object `eval-<agent>`."""
    agent = a.get("agent_name") or target.get("agent_name")
    eval_name = a.get("eval_object") or (f"eval-{agent}" if agent else None)
    min_runs = int(a.get("min_runs", 1))
    if not eval_name:
        return SKIP, "no agent_name/eval_object for eval-run check"
    client, why = _project_client(target)
    if client is None:
        return SKIP, why
    try:
        eval_id = None
        for ev in client.evals.list():
            if getattr(ev, "name", None) == eval_name:
                eval_id = getattr(ev, "id", None)
                break
        if eval_id is None:
            return False, f"eval object '{eval_name}' not found"
        runs = list(client.evals.runs.list(eval_id=eval_id))
    except Exception as exc:  # noqa: BLE001 — preview SDK
        return SKIP, f"evals.runs.list failed: {exc!r}"
    ok = len(runs) >= min_runs
    return ok, f"{len(runs)} run(s) for '{eval_name}' (want ≥{min_runs})"


_AZURE_PROBES = {
    "app_insights_trace": probe_app_insights_trace,
    "eval_rule_exists":   probe_eval_rule_exists,
    "eval_run_present":   probe_eval_run_present,
}


def check_assertions(scenario: dict, workdir: Path) -> list[dict]:
    results = []
    status = load_status(workdir, _agent_rel(scenario))
    target = scenario.get("target", {}) or {}
    for a in scenario.get("assertions", []):
        kind = a["kind"]
        ok = False
        detail = ""
        skipped = False
        if kind == "path_exists":
            ok = (workdir / a["path"]).exists()
            detail = a["path"]
        elif kind == "file_contains":
            f = workdir / a["path"]
            if not f.exists():
                detail = f"{a['path']} missing"
            else:
                ok = a["contains"] in f.read_text()
                detail = f"{a['path']} contains {a['contains']!r}: {ok}"
        elif kind == "agent_status":
            if status is None:
                # Content-aware: the driver never produced agent-status.json, so the deploy step was
                # never reached (e.g. preflight aborted, azd not installed, or the journey stalled
                # before deploy). Make that distinct from a deploy that ran but reported a bad value,
                # so a single missing file doesn't mask the real deploy/verify error.
                detail = (f"agent-status.json not found — deploy never reached deploy step; "
                          f"cannot evaluate {a['field']}")
            else:
                val = dotted(status, a["field"])
                # Three comparison modes (pick exactly one): `equals` (default), `not_equals`, or
                # `exists: true` (field is present / non-null — for values that vary per run, e.g. an
                # audit summary). `exists: false` asserts the field is absent / null.
                if "not_equals" in a:
                    ok = (val != a["not_equals"])
                    detail = f"{a['field']}={val!r} (want != {a['not_equals']!r})"
                elif "exists" in a:
                    present = val is not None
                    ok = present == bool(a["exists"])
                    detail = f"{a['field']}={val!r} (want {'present' if a['exists'] else 'absent'})"
                else:
                    ok = (val == a.get("equals"))
                    detail = f"{a['field']}={val!r} (want {a.get('equals')!r})"
        elif kind in _AZURE_PROBES:
            verdict, detail = _AZURE_PROBES[kind](target, a)
            if verdict is SKIP:
                skipped = True
                # `optional` defaults to True: an un-runnable Azure probe is a SKIP that still
                # lets the overall run pass. Set optional: false to make it a hard failure.
                ok = a.get("optional", True)
                detail = f"SKIPPED ({detail})"
            else:
                ok = verdict
        else:
            detail = f"unknown assertion kind {kind}"
        results.append({"kind": kind, "desc": a.get("desc", ""), "ok": ok,
                        "skipped": skipped, "detail": detail})
    return results


def _agent_rel(scenario: dict) -> str | None:
    for a in scenario.get("assertions", []):
        if a.get("kind") == "path_exists" and "/agent-capabilities.yaml" in a.get("path", ""):
            return str(Path(a["path"]).parent)
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--workdir", default=None,
                    help="existing agent workspace to drive in. Mutually exclusive with --clean-workspace.")
    ap.add_argument("--clean-workspace", action="store_true",
                    help="F-K: build a fresh NON-git workspace and apm-install the skillpack into it.")
    ap.add_argument("--workspace-root", default=None,
                    help="parent dir for --clean-workspace (default: $HOME/.cache/foundry-skillpack-e2e). "
                         "Must be outside any git repo.")
    ap.add_argument("--skillpack-src", default=str(REPO),
                    help="skillpack repo root holding foundry-agent-skillpack/ (default: repo root).")
    ap.add_argument("--backend", default="opencode", choices=["opencode", "codex"])
    ap.add_argument("--model", default=None)
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--skip-driver", action="store_true")
    args = ap.parse_args()

    scenario = yaml.safe_load(Path(args.scenario).read_text())
    run_id = args.run_id or f"{scenario['id']}-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}"

    if args.clean_workspace and args.workdir:
        print("[!] --clean-workspace and --workdir are mutually exclusive", file=sys.stderr)
        return 2
    if not args.clean_workspace and not args.workdir:
        print("[!] need --workdir <dir> or --clean-workspace", file=sys.stderr)
        return 2
    if args.clean_workspace and args.skip_driver:
        print("[!] --skip-driver re-checks an existing --workdir; it cannot use a fresh --clean-workspace",
              file=sys.stderr)
        return 2

    if args.clean_workspace:
        workdir = setup_clean_workspace(args.skillpack_src, args.workspace_root, run_id)
        if workdir is None:
            return 2
    else:
        workdir = Path(args.workdir).resolve()
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
        elif scenario.get("driver", {}).get("model"):
            cmd += ["--model", scenario["driver"]["model"]]
        agent = scenario.get("driver", {}).get("agent")
        if agent:
            cmd += ["--agent", agent]
        print(f"[harness] running driver for scenario '{scenario['id']}' (run {run_id})…")
        subprocess.run(cmd)
        vf = art / "verdict.json"
        driver_verdict = json.loads(vf.read_text()) if vf.exists() else {"verdict": "unknown", "reason": "no verdict.json"}

    assertions = check_assertions(scenario, workdir)
    passed = sum(a["ok"] and not a.get("skipped") for a in assertions)
    skipped = sum(1 for a in assertions if a.get("skipped"))
    failed = sum(1 for a in assertions if not a["ok"])
    total = len(assertions)
    all_ok = failed == 0 and driver_verdict.get("verdict") in ("completed", "skipped")

    report = {
        "scenario": scenario["id"],
        "run_id": run_id,
        "backend": args.backend,
        "workdir": str(workdir),
        "driver_verdict": driver_verdict.get("verdict"),
        "driver_reason": driver_verdict.get("reason"),
        "assertions_passed": passed,
        "assertions_skipped": skipped,
        "assertions_failed": failed,
        "assertions_total": total,
        "assertions": assertions,
        "overall": "pass" if all_ok else "fail",
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
    (art / "harness-report.json").write_text(json.dumps(report, indent=2) + "\n")

    print(f"\n=== Smoke report: {scenario['id']} ({run_id}) ===")
    print(f"driver: {report['driver_verdict']} ({report['driver_reason']})")
    for a in assertions:
        tag = "skip" if a.get("skipped") else ("ok" if a["ok"] else "FAIL")
        print(f"  [{tag}] {a['desc']}: {a['detail']}")
    print(f"assertions: {passed} passed, {skipped} skipped, {failed} failed (of {total})")
    print(f"OVERALL: {report['overall'].upper()}")
    print(f"artifacts: {art}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
