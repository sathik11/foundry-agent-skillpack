---
title: The lifecycle
description: What each slash command does, in what order, and what each one writes to agent-status.json.
---

Eight slash commands. Six form the linear lifecycle (one-time per agent or per change); two are operational (run repeatedly).

## Linear lifecycle

```text
┌──────────────────┐
│  /plan-agent     │  Interview + scaffold; writes agent-capabilities.yaml + (Track B) template files.
└─────────┬────────┘
          │
┌─────────▼────────┐
│ /prepare-deploy  │  Per-capability gate dispatch; init agent-status.json; baseline drift hash.
└─────────┬────────┘
          │
┌─────────▼────────┐
│      azd up      │  External — image build, agent version create, identity assignment.
└─────────┬────────┘
          │
┌─────────▼────────┐
│ /configure-rbac  │  Identities discovered + stamped; Phase 1 + 2 + 3 grants applied; drift re-baselined.
└─────────┬────────┘
          │
┌─────────▼────────┐
│  /verify-agent   │  Drift check (Step −1); deploy block stamped; smoke test; verify block stamped.
└─────────┬────────┘
          │
┌─────────▼────────┐
│  /setup-evals    │  Continuous + (preview) scheduled + (preview) cloud red-team rules.
└──────────────────┘
```

## Operational (run repeatedly)

| When | Run |
| --- | --- |
| When something fails — diagnose by symptom | `/troubleshoot` |
| Weekly — read-only declared-vs-observed reconciliation | `/audit-drift` |

`/setup-purview` is also operational (run once when the tenant is licensed; re-run if the toggle is reset).

## What gets written to `agent-status.json` at each step

| Step | Writes |
| --- | --- |
| `/prepare-deploy` Step 2.5 | `preflight.capabilities.*`, `network.*`, `drift.capability_hash_at_preflight` |
| `/configure-rbac` Step 1 | `identities.{project_mi_principal_id, agent_principal_id}` |
| `/configure-rbac` Step 2 | `rbac.phases_completed` (`phase1_image_pull` + `phase2_runtime`) |
| `/configure-rbac` Step 3 | `rbac.capability_grants.<dotted-key>` per grant; `rbac.pending` per runbook |
| `/configure-rbac` Step 4 | `drift.capability_hash_at_rbac` (re-baseline) |
| `/verify-agent` Step −1 | (reads only — drift check; STOPs if hash mismatch) |
| `/verify-agent` Step 0 | `deploy.*` (version, image_tag, endpoint, deployed_at) |
| `/verify-agent` Step 7 | `verify.{last_run_at, last_run_status, capability_results, ...}` |
| `/audit-drift` Step 6 | `verify.{last_audit_at, audit_summary, audit_report_path}` (additive) |

## RBAC propagation

Every grant has a 5–15 minute propagation window. The lifecycle handles it as follows:

- `/configure-rbac` returns immediately after issuing grants — does NOT wait.
- `/verify-agent` is the natural "wait for propagation" gate; users typically take a coffee break between the two prompts.
- A planned `--wait-for-rbac` flag (TD-7) will poll a known endpoint until success. Until then, just wait.

## When to re-run the lifecycle

| You did this | Re-run | Why |
| --- | --- | --- |
| Edited code in `main.py` / `Dockerfile` / `requirements.txt` | `azd up` + `/verify-agent` | New version is created; identity is reused |
| Edited `agent-capabilities.yaml` (added a knowledge source, etc.) | `/prepare-deploy` + (if Phase B grants needed) `/configure-rbac` + `/verify-agent` | Drift detector will fire on `/verify-agent` Step −1 otherwise |
| Manually changed RBAC in the portal | `/audit-drift` | Surfaces the reverse drift |
| Changed nothing; weekly maintenance | `/audit-drift` | Catches forward drift (revoked grants, deleted rules) |

## Versions are immutable; identity is reused

Foundry hosted agents are versioned (`v1`, `v2`, `v3`, …). Each `azd up` after the first creates a new version. The per-agent SP identity is **reused across versions** — your Phase 2 grants don't need to be re-applied per new version.

This is why `agent-status.json` `identities.agent_principal_id` is set once at first `/configure-rbac` and rarely changes.

## What "publish" means

The skillpack uses "publish" loosely to mean "set this version as the default for invocations." The actual command is `azd ai agent version set-default <vN>`. There is no separate publish artifact; the active version *is* the publish.

A planned scheduled-eval `pass_threshold` gate (Recipe 04) is the recommended publish blocker: only promote a version where `agent-status.json` `verify.last_run_status == "pass"` AND the latest scheduled eval cleared its threshold.

## Read next

- [Personas and roles](/concepts/personas-and-roles/) — who runs what.
- [The capability manifest](/concepts/capability-manifest/) — the declarative input.
- [`agent-status.json`](/concepts/agent-status/) — the durable output.
- [Reference: Prompts](/reference/prompts/) — every prompt with its inputs and step list.
