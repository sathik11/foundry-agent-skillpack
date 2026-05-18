---
title: Convergent lifecycle scripts
description: How the skillpack's ensure_* scripts converge your agent to the desired state — eval rules, red-team scans, RBAC grants, and state management.
---

The skillpack ships Python and Bash scripts that follow a **convergent** pattern: each script checks the current state of a resource, compares it to the desired state declared in your `agent-capabilities.yaml`, and creates or updates only what's missing. Re-running a script after it has already succeeded is always safe — it converges to the same end state.

> **Convergent** means "bring the system to the desired state regardless of where it is now." The same principle that drives infrastructure-as-code tools like Terraform and Bicep, applied to your agent's lifecycle resources.

## The `ensure_*` naming convention

Every convergent script follows the same contract:

| Property | Guarantee |
| --- | --- |
| **Create if missing** | First run provisions the resource (eval rule, red-team scan, RBAC grant, state file) |
| **Update if stale** | Subsequent runs detect drift and reconcile to the manifest |
| **No-op if current** | If the resource already matches desired state, exit 0 with no side effects |
| **Confirm before mutating** | Interactive prompt unless `YES=1` (CI mode) |
| **Preflight before trying** | Check caller roles, region support, and prerequisites — fail fast with a runbook |

## Script inventory

### Eval & red-team (`foundry-evals/scripts/`)

| Script | What it converges |
| --- | --- |
| `ensure_continuous_eval.py` | Continuous eval rule — evaluators, sample rate, judge model |
| `ensure_scheduled_eval.py` | Scheduled eval run — cron, dataset, evaluators |
| `ensure_redteam.py` | Cloud red-team scan — risk categories, attack strategies, region gate |

All three read `agent-capabilities.yaml` to derive defaults (evaluators from `evals.role`, risk categories from `guardrails.layer`). CLI flags override the manifest.

### Guardrails & governance (`foundry-guardrails/scripts/`)

| Script | What it converges |
| --- | --- |
| `guardrails.py` | Vendored middleware — copied into agent container, tuned per-agent |
| `purview_dlp_middleware.py` | Purview DLP middleware — blocks PII/PHI egress at the agent boundary |

These are **vendored** (copied, not imported) so each agent gets its own config. The convergent property here is: re-running the copy overwrites with the latest version.

### State management (`foundry-deploy/scripts/`)

| Script | What it converges |
| --- | --- |
| `agent_status.py init` | `agent-status.json` — creates if absent, no-op if present |
| `agent_status.py update` | Merges a section or sets a dotted path — atomic `.tmp` + rename |
| `agent_status.py drift` | Compares capability hash — exits 1 if capabilities changed since last RBAC grant |

### Knowledge & identity

| Script | What it converges |
| --- | --- |
| `scan_knowledge_refs.py` | Scans agent source for knowledge-source signals; emits draft YAML (never auto-modifies) |
| `preflight-role.sh` | Checks caller RBAC — emits runbook if role is missing, exits 0 if granted |

## Why "convergent" and not "idempotent"?

Both terms apply — the scripts are mathematically idempotent (running twice = running once). But **convergent** better describes the intent: these scripts don't just "not break things on re-run" — they actively **detect drift and reconcile**. If someone manually deletes an eval rule, re-running the script recreates it. If the manifest changes, re-running the script updates the resource to match.

## How the coding agent uses them

The slash commands (`/setup-evals`, `/configure-rbac`, `/verify-agent`) invoke these scripts via the prompt files. The coding agent:

1. Reads the relevant skill markdown for context
2. Resolves parameters from `agent-capabilities.yaml` + user input
3. Runs the `ensure_*` script with `--dry-run` first (when available)
4. Shows the plan and asks for confirmation
5. Runs for real, then updates `agent-status.json` with the result

Because the scripts are convergent, the coding agent can safely retry on transient failures without worrying about duplicate resources.
