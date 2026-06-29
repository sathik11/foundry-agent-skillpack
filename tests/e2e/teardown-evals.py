#!/usr/bin/env python3
"""teardown-evals.py — best-effort cleanup of the continuous-eval rule + eval object an e2e
scenario creates on the standing baseline project.

cleanup-sweep.sh only deletes ARM resources tagged ephemeral/azd-managed. The continuous-eval
RULE (`continuous-eval-<agent>`) and EVAL OBJECT (`eval-<agent>`) created by ensure_continuous_eval.py
are *data-plane* objects inside the Foundry project, not standalone ARM resources, so the sweep can
never see them. Scenario 04 (which runs /setup-evals for real) must therefore call this script in
its teardown so a live run never leaves an eval rule running against the baseline.

Best-effort by design: it NEVER hard-fails. Missing SDK, missing creds, an already-deleted rule, or
a preview-SDK method rename all degrade to a logged no-op (exit 0) so it is safe to wire behind
`if: always()` in CI. Pass --strict to exit non-zero when a delete is attempted and errors.

Usage:
  teardown-evals.py \
      --project-endpoint https://<acct>.services.ai.azure.com/api/projects/<proj> \
      --agent-name <name> [--rule-name <r>] [--eval-object <e>] [--strict]
"""
from __future__ import annotations

import argparse
import sys


def log(msg: str) -> None:
    print(f"[teardown-evals] {msg}", file=sys.stderr)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project-endpoint", required=True)
    p.add_argument("--agent-name", required=True)
    p.add_argument("--rule-name", default=None,
                   help="Override the rule name (default continuous-eval-<agent>)")
    p.add_argument("--eval-object", default=None,
                   help="Override the eval object name (default eval-<agent>)")
    p.add_argument("--strict", action="store_true",
                   help="Exit non-zero if an attempted delete errors (default: best-effort no-op)")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    rule_name = args.rule_name or f"continuous-eval-{args.agent_name}"
    eval_name = args.eval_object or f"eval-{args.agent_name}"

    try:
        from azure.ai.projects import AIProjectClient
        from azure.identity import DefaultAzureCredential
    except ImportError:
        log("azure-ai-projects/azure-identity not installed — nothing to clean (no-op).")
        return 0

    try:
        client = AIProjectClient(
            endpoint=args.project_endpoint, credential=DefaultAzureCredential())
    except Exception as exc:  # noqa: BLE001 — auth/preview surface
        log(f"could not build AIProjectClient ({exc!r}) — no-op.")
        return 0 if not args.strict else 1

    errors = 0

    # 1. Delete the continuous-eval rule (stops sampling new traffic).
    try:
        client.evaluation_rules.delete(rule_name)
        log(f"deleted rule '{rule_name}'.")
    except AttributeError:
        log("evaluation_rules.delete not on this SDK build — skipping rule delete.")
    except Exception as exc:  # noqa: BLE001 — already-gone / preview surface
        log(f"rule delete best-effort ({rule_name}): {exc!r}")
        errors += 1

    # 2. Delete the eval object. Resolve its id first (delete keys on id, not name).
    try:
        eval_id = None
        for ev in client.evals.list():
            if getattr(ev, "name", None) == eval_name:
                eval_id = getattr(ev, "id", None)
                break
        if eval_id is None:
            log(f"eval object '{eval_name}' not found — nothing to delete.")
        else:
            client.evals.delete(eval_id=eval_id)
            log(f"deleted eval object '{eval_name}' ({eval_id}).")
    except AttributeError:
        log("evals.delete/list not on this SDK build — skipping eval-object delete.")
    except Exception as exc:  # noqa: BLE001 — already-gone / preview surface
        log(f"eval-object delete best-effort ({eval_name}): {exc!r}")
        errors += 1

    if errors and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
