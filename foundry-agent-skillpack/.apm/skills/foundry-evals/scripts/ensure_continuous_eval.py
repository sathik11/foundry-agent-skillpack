#!/usr/bin/env python3
"""Idempotently create or update the continuous-eval rule for an agent.

Reads agent-capabilities.yaml when present; CLI flags override.

Usage:
  python ensure_continuous_eval.py \
      --project-endpoint https://<acct>.services.ai.azure.com/api/projects/<proj> \
      --project-scope    /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<acct>/projects/<proj> \
      --agent-name       <name> \
      [--agent-path      ./agents/<name>] \
      [--judge-model     gpt-5.4-mini-1] \
      [--sample-rate     0.2] \
      [--max-hourly-runs 100] \
      [--evaluators      relevance,task_adherence,indirect_attack] \
      [--dry-run]

Env:
  YES=1   skip the confirm prompt (for CI)

Exit codes:
  0 success / no-op
  1 caller lacks Foundry User on project (runbook already emitted)
  2 user aborted, or invalid input
"""
from __future__ import annotations

import argparse
import sys
from typing import Any

from _common import (
    confirm_or_abort, get_project_client, load_capabilities, preflight_role,
    print_summary, resolve_evaluators, split_builtin_custom,
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--project-endpoint", required=True)
    p.add_argument("--project-scope",    required=True,
                   help="Full ARM scope of the Foundry project (used for Foundry User preflight)")
    p.add_argument("--agent-name",       required=True)
    p.add_argument("--agent-path",       default=None,
                   help="Path to agent folder containing agent-capabilities.yaml")
    p.add_argument("--judge-model",      default=None)
    p.add_argument("--sample-rate",      type=float, default=None)
    p.add_argument("--max-hourly-runs",  type=int, default=None)
    p.add_argument("--evaluators",       default=None,
                   help="Comma-separated explicit list; overrides capability-derived selection")
    p.add_argument("--dry-run",          action="store_true")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # 1. Preflight role.
    preflight_role(
        scope=args.project_scope, role="Foundry User",
        action="setup-evals", why="Create continuous-eval rule for {}".format(args.agent_name),
    )

    # 2. Load manifest + resolve config.
    caps = load_capabilities(args.agent_path) if args.agent_path else {}
    cont = (caps.get("capabilities", {}).get("evals", {}) or {}).get("continuous", {}) or {}

    judge_model = args.judge_model or cont.get("judge_model")
    if not judge_model:
        print("[x] --judge-model not provided and no judge_model in manifest", file=sys.stderr)
        return 2

    sample_rate     = args.sample_rate     if args.sample_rate     is not None else cont.get("sample_rate", 0.2)
    max_hourly_runs = args.max_hourly_runs if args.max_hourly_runs is not None else cont.get("max_hourly_runs", 100)

    explicit = None
    if args.evaluators:
        explicit = [{"id": e.strip()} for e in args.evaluators.split(",") if e.strip()]
    elif cont.get("evaluators"):
        explicit = cont["evaluators"]

    role = (caps.get("capabilities", {}).get("evals", {}) or {}).get("role")
    evaluators = resolve_evaluators(role=role, capabilities=caps, explicit=explicit)
    builtin, custom = split_builtin_custom(evaluators)

    rule_name = f"continuous-eval-{args.agent_name}"
    eval_object_name = f"eval-{args.agent_name}"

    print_summary("Plan", {
        "rule_name":       rule_name,
        "eval_object":     eval_object_name,
        "agent_name":      args.agent_name,
        "judge_model":     judge_model,
        "sample_rate":     sample_rate,
        "max_hourly_runs": max_hourly_runs,
        "evaluators (built-in)": builtin,
        "evaluators (custom)":   custom or "(none)",
    })

    if args.dry_run:
        print("[i] --dry-run set; no API calls made.")
        return 0
    confirm_or_abort("Apply this plan?")

    # 3. Create or fetch the eval object, then create-or-update the rule.
    #
    # The exact azure-ai-projects API surface for evaluation rules is moving;
    # we use the documented model classes and rely on the SDK's
    # `evaluation_rules.create_or_update` (or `evals.create` + `evaluation_rules.create`)
    # contract — see continuous-eval.md.
    try:
        from azure.ai.projects.models import (
            ContinuousEvaluationRuleAction,
            EvaluationRule,
            EvaluationRuleEventType,
            EvaluationRuleFilter,
        )
    except ImportError:
        print("[x] azure-ai-projects>=2.0.0 not installed in current env", file=sys.stderr)
        print("    pip install \"azure-ai-projects>=2.0.0,<3\" azure-identity pyyaml", file=sys.stderr)
        return 2

    client = get_project_client(args.project_endpoint)

    # Custom evaluators must already be registered. Validate fast.
    if custom:
        try:
            registered = {e.id for e in client.evaluators.list()}
        except Exception as exc:  # noqa: BLE001 — preview SDK
            print(f"[!] Could not list registered evaluators ({exc!r}); skipping custom validation", file=sys.stderr)
            registered = set()
        unknown = [c for c in custom if c not in registered]
        if unknown and registered:
            print(f"[x] Custom evaluators not registered: {unknown}", file=sys.stderr)
            print("    Register via the Custom Evaluators API first, then re-run.", file=sys.stderr)
            return 2

    # Ensure the eval object exists. The wrapper key it on a stable name so
    # repeated runs don't accumulate orphan eval objects.
    try:
        eval_object = client.evals.create_or_update(
            name=eval_object_name,
            evaluators={e: {"id": e} for e in evaluators},
            metadata={"agent_name": args.agent_name},
        )
    except AttributeError:
        # Older preview surface: evals.create only.
        eval_object = client.evals.create(
            name=eval_object_name,
            evaluators={e: {"id": e} for e in evaluators},
        )

    rule = EvaluationRule(
        name=rule_name,
        event_type=EvaluationRuleEventType.RESPONSE_COMPLETED,
        filter=EvaluationRuleFilter(agent_name=args.agent_name),
        actions=[ContinuousEvaluationRuleAction(eval_id=eval_object.id)],
        enabled=True,
        sampling_percent=int(round(sample_rate * 100)),
        max_hourly_runs=max_hourly_runs,
    )

    try:
        client.evaluation_rules.create_or_update(rule_name=rule.name, rule=rule)
    except AttributeError:
        client.evaluation_rules.create(rule=rule)

    print(f"[+] Continuous-eval rule '{rule_name}' is in place.")
    print(f"    eval_id = {eval_object.id}")
    print("    First runs will appear in the Foundry portal Monitor tab once traffic flows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
