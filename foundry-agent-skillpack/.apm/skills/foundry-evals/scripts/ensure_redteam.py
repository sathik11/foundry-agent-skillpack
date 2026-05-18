#!/usr/bin/env python3
"""Idempotently create or update a cloud red-team scan for an agent (preview).

Region-locked. Hard-fails preflight if the project's region is unsupported.

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

Env: YES=1 to skip confirm.

Exit codes: 0 success / 1 missing role / 2 invalid input / 3 region not supported.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from _common import (
    confirm_or_abort, get_project_client, load_capabilities, preflight_role,
    print_summary,
)

# As of 2026-05-14. Update when Foundry expands the supported region list.
SUPPORTED_REGIONS: set[str] = {
    "eastus2", "francecentral", "swedencentral", "switzerlandwest", "northcentralus",
}


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
    if region not in SUPPORTED_REGIONS:
        print(f"[x] Cloud red-team is not available in region '{args.project_region}'.", file=sys.stderr)
        print(f"    Supported (as of 2026-05-14): {', '.join(sorted(SUPPORTED_REGIONS))}", file=sys.stderr)
        print( "    Either: (a) deploy a separate Foundry project in a supported region for red-team only,", file=sys.stderr)
        print( "            (b) run PyRIT-in-CI fallback (foundry-guardrails/scripts/redteam.yml),", file=sys.stderr)
        print( "            (c) wait for the region to be added.", file=sys.stderr)
        return 3

    preflight_role(
        scope=args.project_scope, role="Azure AI User",
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
