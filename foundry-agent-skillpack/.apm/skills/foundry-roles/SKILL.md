---
name: foundry-roles
description: Role and scope preflight for every skillpack action — single source of truth for required Azure / Entra / Foundry roles, with a runbook emitter for handoff when the caller lacks rights
---

# Foundry Roles — Router

Every executable step in this package declares the role + scope it needs. This skill is the consolidated matrix every other skill points at, plus two helpers used by the prompts.

| Topic | Read |
|---|---|
| Full role × action × scope matrix | [role-matrix.md](role-matrix.md) |
| Operator mode — try-first pattern (v0.21.0) | [operator-mode.md](operator-mode.md) |
| Runbook handoff format (when caller can't execute) | [runbook-format.md](runbook-format.md) |
| Preflight script (single role check) | [scripts/preflight-role.sh](scripts/preflight-role.sh) |
| Batch preflight (all roles for a prompt in one call) | [scripts/preflight-roles.sh](scripts/preflight-roles.sh) |
| Try-or-runbook wrapper (operator-mode core primitive) | [scripts/try-or-runbook.sh](scripts/try-or-runbook.sh) |
| Provider registration (auto-register on success, runbook on 403) | [scripts/ensure-provider-registration.sh](scripts/ensure-provider-registration.sh) |
| Runbook emitter | [scripts/runbook-emit.sh](scripts/runbook-emit.sh) |
| Caller capability dump (debug) | [scripts/list-my-roles.sh](scripts/list-my-roles.sh) |

## One-line truths

- **Reader is the floor** for any preflight (network detection, identity discovery). Without it, a script must degrade to checklist + runbook, never silently fail.
- **Operator mode (default: try-first).** Scripts attempt the action and only emit runbooks on 403. Set `operator_mode: false` in `agent-capabilities.yaml` for SOC-monitored environments where unauthorized attempts trigger alerts. See [operator-mode.md](operator-mode.md).
- **Idempotent grants.** Every grant script tolerates "role already exists" and exits 0.
- **Propagation is real.** RBAC takes 5–15 minutes after grant. Any verify step within that window is best-effort.

## Cross-skill references

- Per-agent identity discovery → [foundry-identity](../foundry-identity/SKILL.md)
- Network preflight Reader requirement → [foundry-prod-readiness/networking.md](../foundry-prod-readiness/networking.md)
- Eval rule role (`Azure AI User`) → [foundry-evals](../foundry-evals/SKILL.md)
- Capability-driven Phase B grants → [capability-gates.md](../foundry-guardrails/capability-gates.md)
