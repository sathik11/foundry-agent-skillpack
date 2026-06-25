#!/usr/bin/env python3
"""Idempotently create or update a cloud red-team scan for an agent (preview).

Region-gated (preview). The supported-region set below is a *snapshot* of a Learn doc
that changes as the feature expands toward GA, so it is treated as advisory: --dry-run
and the REDTEAM_ALLOW_UNSUPPORTED_REGION override both bypass the hard gate, and the
live service remains authoritative. Only cloud red-team + the hosted risk/safety
evaluators are region-limited — batch/quality evals (continuous + scheduled) run in
~30 regions incl. westus, so they are NOT gated here. See TD-9.

Usage:
  python ensure_redteam.py \
      --project-endpoint https://<acct>.services.ai.azure.com/api/projects/<proj> \
      --project-scope    /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<acct>/projects/<proj> \
      --project-region   eastus2 \
      --agent-name       <name> \
      --agent-path       ./agents/<name> \
      [--risk-categories violence,hate_unfairness,prohibited_actions] \
      [--attack-strategies base64,jailbreak,indirect_jailbreak] \
      [--num-objectives 10] \
      [--cron "0 3 * * 0"] \
      [--one-shot] \
      [--dry-run]

Env:
  YES=1                              skip confirm.
  REDTEAM_ALLOW_UNSUPPORTED_REGION=1 bypass the region gate (the snapshot below is stale-prone;
                                     the live service is authoritative).

Exit codes: 0 success / 1 missing role / 2 invalid input / 3 region not supported.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from _common import (
    confirm_or_abort, get_project_client, load_capabilities, preflight_role,
    print_summary,
)

# Snapshot of "Risk and safety evaluators and AI red teaming region support" as of 2026-06-15.
# Source of truth (re-verify every automation run — this set churns as the preview expands):
#   https://learn.microsoft.com/azure/ai-foundry/concepts/evaluation-regions-limits-virtual-network
# NOTE: the region list moved OUT of the run-ai-red-teaming-cloud how-to into the doc above.
SUPPORTED_REGIONS: set[str] = {
    "eastus2", "northcentralus", "francecentral", "swedencentral", "switzerlandwest",
    "australiaeast",
}
REGION_DOC = (
    "https://learn.microsoft.com/azure/ai-foundry/concepts/"
    "evaluation-regions-limits-virtual-network"
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--project-endpoint",   required=True)
    p.add_argument("--project-scope",      required=True)
    p.add_argument("--project-region",     required=True, help="Foundry project region (e.g. eastus2)")
    p.add_argument("--agent-name",         required=True)
    p.add_argument("--agent-path",         required=True)
    p.add_argument("--risk-categories",    default=None)
    p.add_argument("--attack-strategies",  default=None)
    p.add_argument("--num-objectives",     type=int, default=None)
    p.add_argument("--cron",               default=None)
    p.add_argument("--one-shot",           action="store_true",
                   help="Skip schedule creation; create a single immediate run only")
    p.add_argument("--dry-run",            action="store_true")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    region = args.project_region.lower().replace(" ", "")
    override = os.environ.get("REDTEAM_ALLOW_UNSUPPORTED_REGION", "").strip().lower() not in ("", "0", "false", "no")
    if region not in SUPPORTED_REGIONS:
        print(f"[!] Region '{args.project_region}' is not in the cached cloud red-team region set.", file=sys.stderr)
        print(f"    Cached (snapshot 2026-06-15): {', '.join(sorted(SUPPORTED_REGIONS))}", file=sys.stderr)
        print(f"    This list churns as the preview expands \u2014 verify against the live doc:", file=sys.stderr)
        print(f"    {REGION_DOC}  (section: Risk and safety evaluators and AI red teaming region support)", file=sys.stderr)
        if args.dry_run or override:
            why = "--dry-run" if args.dry_run else "REDTEAM_ALLOW_UNSUPPORTED_REGION"
            print(f"[i] {why} set \u2014 continuing; the service is authoritative if the snapshot is stale.", file=sys.stderr)
        else:
            print( "    Options: (a) set REDTEAM_ALLOW_UNSUPPORTED_REGION=1 if the live doc lists this region,", file=sys.stderr)
            print( "             (b) deploy a separate Foundry project in a supported region for red-team only,", file=sys.stderr)
            print( "             (c) run PyRIT-in-CI fallback (foundry-guardrails/scripts/redteam.yml).", file=sys.stderr)
            return 3

    preflight_role(
        scope=args.project_scope, role="Foundry User",
        action="setup-redteam", why=f"Create cloud red-team scan for {args.agent_name}",
    )

    caps = load_capabilities(args.agent_path)
    rt = (caps.get("capabilities", {}).get("evals", {}) or {}).get("redteam", {}) or {}

    risk_categories = (args.risk_categories.split(",") if args.risk_categories
                       else rt.get("risk_categories", ["violence", "hate_unfairness"]))
    attack_strategies = (args.attack_strategies.split(",") if args.attack_strategies
                         else rt.get("attack_strategies", ["base64", "jailbreak", "indirect_jailbreak"]))
    num_objectives = (args.num_objectives if args.num_objectives is not None
                      else rt.get("num_objectives", 10))
    cron = args.cron or (rt.get("schedule", {}) or {}).get("cron")

    risk_categories   = [r.strip() for r in risk_categories if r.strip()]
    attack_strategies = [a.strip() for a in attack_strategies if a.strip()]

    # Prohibited Actions requires a taxonomy file in eval/.
    if "prohibited_actions" in risk_categories:
        taxonomy = Path(args.agent_path) / "eval" / "prohibited-actions-taxonomy.json"
        if not taxonomy.exists():
            print(f"[!] prohibited_actions risk requested but taxonomy missing: {taxonomy}", file=sys.stderr)
            print( "    Drop this category, or generate via the Prohibited Actions workflow:", file=sys.stderr)
            print( "    https://learn.microsoft.com/azure/foundry/how-to/develop/run-ai-red-teaming-cloud", file=sys.stderr)
            risk_categories = [r for r in risk_categories if r != "prohibited_actions"]
            if not risk_categories:
                print("[x] No risk categories left after dropping prohibited_actions. Aborting.", file=sys.stderr)
                return 2

    cell_count = len(risk_categories) * len(attack_strategies)
    estimated_prompts = cell_count * num_objectives

    print_summary("Plan", {
        "scan_name":          f"redteam-{args.agent_name}",
        "target":             f"{args.agent_name} (latest)",
        "region":             region,
        "risk_categories":    risk_categories,
        "attack_strategies":  attack_strategies,
        "num_objectives":     num_objectives,
        "estimated_prompts":  estimated_prompts,
        "schedule":           cron if cron and not args.one_shot else "(one-shot, no schedule)",
    })

    if args.dry_run:
        print("[i] --dry-run set; no API calls made.")
        return 0
    confirm_or_abort(f"Run ~{estimated_prompts} adversarial prompts against the agent?")

    try:
        from azure.ai.projects.models import (
            AttackStrategy,
            AzureAIAgentTarget,
            ProjectsSchedule,
            RecurrenceTrigger,
            RedTeam,
            RiskCategory,
        )
    except ImportError:
        print("[x] azure-ai-projects>=2.0.0 not installed", file=sys.stderr)
        return 2

    client = get_project_client(args.project_endpoint)

    def _to_enum(enum_cls, value: str):
        try:
            return getattr(enum_cls, value.upper())
        except AttributeError:
            print(f"[x] Unknown {enum_cls.__name__}: {value}", file=sys.stderr)
            sys.exit(2)

    red_team = RedTeam(
        target=AzureAIAgentTarget(name=args.agent_name, version="latest"),
        attack_strategies=[_to_enum(AttackStrategy, s) for s in attack_strategies],
        risk_categories=[_to_enum(RiskCategory, r) for r in risk_categories],
        num_objectives=num_objectives,
        display_name=f"redteam-{args.agent_name}",
    )

    created = client.red_teams.create(red_team=red_team)
    print(f"[+] Red-team scan created: name={created.name} status={created.status}")

    if cron and not args.one_shot:
        schedule = ProjectsSchedule(
            name=f"redteam-{args.agent_name}",
            trigger=RecurrenceTrigger.from_cron(cron) if hasattr(RecurrenceTrigger, "from_cron")
                    else RecurrenceTrigger(frequency="week", interval=1),
            task={"red_team_id": created.name},
            enabled=True,
        )
        try:
            client.schedules.create_or_update(name=schedule.name, schedule=schedule)
        except AttributeError:
            client.schedules.create(schedule=schedule)
        print(f"[+] Schedule '{schedule.name}' created (cron='{cron}')")

    print("    Watch results: Foundry portal → Evaluation → AI red teaming")
    return 0


if __name__ == "__main__":
    sys.exit(main())
