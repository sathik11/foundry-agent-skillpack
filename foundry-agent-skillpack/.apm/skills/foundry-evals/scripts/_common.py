"""Shared helpers for the foundry-evals ensure_* scripts.

Standalone — no own requirements.txt. Consumer must have:
  pip install "azure-ai-projects>=2.0.0,<3" azure-identity pyyaml

Provides:
  load_capabilities(agent_path)     -> dict
  get_project_client(endpoint)      -> AIProjectClient
  preflight_role(scope, role)       -> raises if caller lacks role
  ensure_eval_object(client, name, evaluators, judge_model) -> eval_id
  resolve_evaluators(role, capabilities)                    -> list[str]

Conventions:
  - "Built-in evaluator" = id present in BUILT_IN_EVALUATORS below.
  - Anything else is treated as a custom evaluator id and validated against
    the project's registered custom evaluator catalog before use.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

# Built-in evaluator IDs we know about as of 2026-05-14.
# When azure-ai-projects ships new ones, add them here AND in evaluator-catalog.md.
BUILT_IN_EVALUATORS: set[str] = {
    "relevance", "coherence", "fluency",
    "groundedness", "task_adherence", "intent_resolution",
    "tool_call_accuracy",
    "violence", "sexual", "hate_unfairness", "self_harm",
    "indirect_attack", "pii_detection",
}

ROLE_BASE_EVALUATORS: dict[str, list[str]] = {
    "orchestrator": ["intent_resolution", "task_adherence", "indirect_attack"],
    "ingestion":    ["task_adherence", "tool_call_accuracy", "indirect_attack"],
    "enrichment":   ["groundedness", "fluency"],
    "narrative":    ["coherence", "fluency", "relevance", "hate_unfairness"],
    "prompt":       ["relevance", "task_adherence", "indirect_attack"],
}


def load_capabilities(agent_path: str) -> dict[str, Any]:
    """Load agent-capabilities.yaml from agent_path; return {} if missing."""
    p = Path(agent_path) / "agent-capabilities.yaml"
    if not p.exists():
        return {}
    with p.open() as fh:
        return yaml.safe_load(fh) or {}


def get_project_client(endpoint: str) -> AIProjectClient:
    """Create an AIProjectClient using DefaultAzureCredential."""
    return AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())


def preflight_role(scope: str, role: str, action: str, why: str) -> None:
    """Run preflight-role.sh from foundry-roles. Exit on failure with the runbook
    already printed by the script."""
    here = Path(__file__).resolve().parent
    preflight = here.parent.parent / "foundry-roles" / "scripts" / "preflight-role.sh"
    if not preflight.exists():
        print(f"[!] preflight-role.sh not found at {preflight} — skipping role check", file=sys.stderr)
        return
    rc = subprocess.call([
        str(preflight), role, scope,
        "--action", action, "--persona", "DevOps", "--why", why,
    ])
    if rc == 1:
        sys.exit(1)
    if rc == 2:
        print("[!] Could not verify role (no Reader on scope). Continuing best-effort.", file=sys.stderr)


def resolve_evaluators(
    role: str | None,
    capabilities: dict[str, Any],
    explicit: list[dict[str, Any]] | None,
) -> list[str]:
    """Compute the final evaluator id list from explicit declaration OR
    derive from role + capability blocks. Mirrors evaluator-catalog.md."""
    if explicit:
        return _dedup([e["id"] for e in explicit])

    if not role:
        role = capabilities.get("evals", {}).get("role", "orchestrator")
    base = list(ROLE_BASE_EVALUATORS.get(role, ROLE_BASE_EVALUATORS["orchestrator"]))

    caps = capabilities.get("capabilities", {})
    # Tooling
    toolbox = caps.get("toolbox", {}) or {}
    if toolbox.get("enabled") and toolbox.get("mcp_servers") and role != "prompt":
        base.append("tool_call_accuracy")
    # Knowledge → groundedness
    knowledge = caps.get("knowledge", {}) or {}
    sources = knowledge.get("sources", []) or []
    grounding_kinds = {
        "ai_search_direct", "foundry_iq", "blob_via_indexer",
        "file_search_basic", "file_search_standard", "sharepoint_via_iq",
        "fabric_data_agent", "fabric_direct_delta",
    }
    if any(s.get("kind") in grounding_kinds for s in sources):
        base.append("groundedness")
    # Guardrails
    guardrails = caps.get("guardrails", {}) or {}
    if "content_safety" in (guardrails.get("layers") or []):
        base += ["hate_unfairness", "self_harm"]
    # Purview → PII
    purview = caps.get("purview", {}) or {}
    if purview.get("audit_required"):
        base.append("pii_detection")
    # Teams
    teams = caps.get("workiq_teams", {}) or {}
    if teams.get("enabled"):
        base.append("coherence")

    return _dedup(base)


def _dedup(xs: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for x in xs:
        if x not in seen:
            out.append(x)
            seen.add(x)
    return out


def split_builtin_custom(evaluators: list[str]) -> tuple[list[str], list[str]]:
    """Partition into (built-in, custom)."""
    builtin = [e for e in evaluators if e in BUILT_IN_EVALUATORS]
    custom  = [e for e in evaluators if e not in BUILT_IN_EVALUATORS]
    return builtin, custom


def confirm_or_abort(prompt: str) -> None:
    """Interactive y/N gate. Honors $YES=1 for non-interactive runs."""
    if os.environ.get("YES") == "1":
        return
    if not sys.stdin.isatty():
        print("[!] non-interactive shell + YES != 1 → refusing to mutate", file=sys.stderr)
        sys.exit(2)
    ans = input(f"{prompt} [y/N]: ").strip().lower()
    if ans not in ("y", "yes"):
        print("aborted.", file=sys.stderr)
        sys.exit(2)


def print_summary(title: str, items: dict[str, Any]) -> None:
    print(f"\n── {title} ──")
    for k, v in items.items():
        if isinstance(v, list):
            v = ", ".join(map(str, v))
        print(f"  {k}: {v}")
    print()
