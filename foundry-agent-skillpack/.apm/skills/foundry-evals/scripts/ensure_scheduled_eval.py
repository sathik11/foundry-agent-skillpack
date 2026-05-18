#!/usr/bin/env python3
"""Idempotently create or update a scheduled-eval for an agent (preview).

Reads agent-capabilities.yaml when present; CLI flags override.

Usage:
  python ensure_scheduled_eval.py \
      --project-endpoint https://<acct>.services.ai.azure.com/api/projects/<proj> \
      --project-scope    /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<acct>/projects/<proj> \
      --agent-name       <name> \
      --agent-path       ./agents/<name> \
      [--cron            "0 2 * * *"] \
      [--timezone        UTC] \
      [--dataset-jsonl   eval/regression-set.jsonl] \
      [--dataset-id      my-regression-v3] \
      [--evaluators      task_adherence,groundedness] \
      [--dry-run]

Env: YES=1 to skip confirm.

Exit codes: 0 success / 1 missing role / 2 invalid input or aborted.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

from _common import (
    confirm_or_abort, get_project_client, load_capabilities, preflight_role,
    print_summary, resolve_evaluators, split_builtin_custom,
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--project-endpoint", required=True)
    p.add_argument("--project-scope",    required=True)
    p.add_argument("--agent-name",       required=True)
    p.add_argument("--agent-path",       required=True)
    p.add_argument("--cron",             default=None, help="Cron expression — daily 02:00 UTC default if not in manifest")
    p.add_argument("--timezone",         default=None)
    p.add_argument("--dataset-jsonl",    default=None, help="Path to JSONL dataset (relative to agent-path)")
    p.add_argument("--dataset-id",       default=None, help="Existing Foundry dataset id")
    p.add_argument("--evaluators",       default=None)
    p.add_argument("--dry-run",          action="store_true")
    return p.parse_args()


def upload_jsonl(client, jsonl_path: Path, name_hint: str) -> str:
    """Upload a JSONL file as a Foundry dataset. Versioned by content hash so
    re-uploads of the same file return the same dataset id."""
    h = hashlib.sha256(jsonl_path.read_bytes()).hexdigest()[:12]
    name = f"{name_hint}-{h}"
    try:
        existing = client.datasets.get(name=name)
        return existing.id
    except Exception:  # noqa: BLE001
        pass
    with jsonl_path.open("rb") as fh:
        ds = client.datasets.upload(name=name, file=fh, type="jsonl")
    return ds.id


def main() -> int:
    args = parse_args()

    preflight_role(
        scope=args.project_scope, role="Azure AI User",
        action="setup-evals", why=f"Create scheduled-eval for {args.agent_name}",
    )

    caps = load_capabilities(args.agent_path)
    sched = (caps.get("capabilities", {}).get("evals", {}) or {}).get("scheduled", {}) or {}

    cron      = args.cron      or sched.get("cron", "0 2 * * *")
    timezone  = args.timezone  or sched.get("timezone", "UTC")

    dataset_jsonl = args.dataset_jsonl or (sched.get("dataset", {}) or {}).get("path")
    dataset_id    = args.dataset_id    or (sched.get("dataset", {}) or {}).get("dataset_id")
    if not (dataset_jsonl or dataset_id):
        print("[x] No dataset provided. Pass --dataset-jsonl or --dataset-id (or set evals.scheduled.dataset in manifest).", file=sys.stderr)
        return 2

    explicit = None
    if args.evaluators:
        explicit = [{"id": e.strip()} for e in args.evaluators.split(",") if e.strip()]
    elif sched.get("evaluators"):
        explicit = sched["evaluators"]
    role = (caps.get("capabilities", {}).get("evals", {}) or {}).get("role")
    evaluators = resolve_evaluators(role=role, capabilities=caps, explicit=explicit)
    builtin, custom = split_builtin_custom(evaluators)

    schedule_name    = f"scheduled-eval-{args.agent_name}"
    eval_object_name = f"scheduled-eval-{args.agent_name}"

    print_summary("Plan", {
        "schedule_name":   schedule_name,
        "eval_object":     eval_object_name,
        "cron":            cron,
        "timezone":        timezone,
        "dataset":         dataset_jsonl or f"id={dataset_id}",
        "evaluators (built-in)": builtin,
        "evaluators (custom)":   custom or "(none)",
        "target":          f"{args.agent_name} (latest)",
    })

    if args.dry_run:
        print("[i] --dry-run set; no API calls made.")
        return 0
    confirm_or_abort("Apply this plan?")

    try:
        from azure.ai.projects.models import (
            AzureAIAgentTarget,
            EvaluationScheduleTask,
            ProjectsSchedule,
            RecurrenceTrigger,
        )
    except ImportError:
        print("[x] azure-ai-projects>=2.0.0 not installed", file=sys.stderr)
        return 2

    client = get_project_client(args.project_endpoint)

    # Resolve dataset_id if JSONL provided.
    if dataset_jsonl:
        p = Path(args.agent_path) / dataset_jsonl
        if not p.exists():
            print(f"[x] Dataset file not found: {p}", file=sys.stderr)
            return 2
        dataset_id = upload_jsonl(client, p, name_hint=f"ds-{args.agent_name}")
        print(f"[+] Dataset uploaded as id={dataset_id}")

    # Create / update eval object.
    try:
        eval_object = client.evals.create_or_update(
            name=eval_object_name,
            evaluators={e: {"id": e} for e in evaluators},
            data_source={"type": "dataset_id", "dataset_id": dataset_id},
            metadata={"agent_name": args.agent_name, "kind": "scheduled"},
        )
    except AttributeError:
        eval_object = client.evals.create(
            name=eval_object_name,
            evaluators={e: {"id": e} for e in evaluators},
            data_source={"type": "dataset_id", "dataset_id": dataset_id},
        )

    schedule = ProjectsSchedule(
        name=schedule_name,
        trigger=RecurrenceTrigger.from_cron(cron, time_zone=timezone) if hasattr(RecurrenceTrigger, "from_cron")
                else RecurrenceTrigger(frequency="day", interval=1, time_zone=timezone),
        task=EvaluationScheduleTask(
            target=AzureAIAgentTarget(name=args.agent_name, version="latest"),
            eval_id=eval_object.id,
        ),
        enabled=True,
    )
    try:
        client.schedules.create_or_update(name=schedule.name, schedule=schedule)
    except AttributeError:
        client.schedules.create(schedule=schedule)

    print(f"[+] Scheduled-eval '{schedule_name}' is in place.")
    print(f"    Next run per cron: {cron} ({timezone})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
