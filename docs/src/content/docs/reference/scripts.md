---
title: Reference — Scripts
description: Every runnable script the skillpack ships, by skill.
---

The skillpack ships scripts under each skill's `scripts/` folder. Most are bash; some are Python. All are idempotent (safe to re-run); read-only checks degrade gracefully on missing Reader.

## foundry-roles

| Script | What it does | Reader required |
| --- | --- | --- |
| [`preflight-role.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-roles/scripts/preflight-role.sh) | Single-call: do I have role X on scope Y? Emits runbook on failure | Reader on scope |
| [`runbook-emit.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-roles/scripts/runbook-emit.sh) | Standalone runbook emitter | none |
| [`list-my-roles.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-roles/scripts/list-my-roles.sh) | Debug: dump every role the caller has across declared scopes | Reader on scopes |

## foundry-identity

| Script | What it does |
| --- | --- |
| [`check-identities.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-identity/scripts/check-identities.sh) | Discover Project MI + per-agent SP for a deployed agent |
| [`grant-rbac.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-identity/scripts/grant-rbac.sh) | Apply Phase 1 (AcrPull) + Phase 2 (5 runtime roles) in one call |

## foundry-deploy

| Script | What it does |
| --- | --- |
| [`agent_status.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/agent_status.py) | The only writer of `agent-status.json`. Subcommands: `init`, `read`, `update`, `hash`, `drift` |

## foundry-knowledge

| Script | What it does |
| --- | --- |
| [`scan_knowledge_refs.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/scan_knowledge_refs.py) | Brownfield regex scanner; emits draft `knowledge.sources[]` block |
| [`verify-source-rbac.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/verify-source-rbac.sh) | Per-source caller + per-agent SP RBAC verifier |
| [`verify-source-network.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/verify-source-network.sh) | Per-source network-class compatibility check (HARD-BLOCK on Fabric in network-isolated agents) |

## foundry-evals

| Script | What it does |
| --- | --- |
| [`_common.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-evals/scripts/_common.py) | Shared helpers (manifest load, role preflight, evaluator resolution, dedup) |
| [`ensure_continuous_eval.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-evals/scripts/ensure_continuous_eval.py) | Idempotent continuous-eval rule create/update via `azure-ai-projects` |
| [`ensure_scheduled_eval.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-evals/scripts/ensure_scheduled_eval.py) | Idempotent scheduled-eval (preview) — uploads JSONL or references existing dataset |
| [`ensure_redteam.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-evals/scripts/ensure_redteam.py) | Idempotent cloud red-team (preview); region-gated; one-shot or scheduled |

## foundry-guardrails

| Script | What it does |
| --- | --- |
| [`guardrails.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-guardrails/scripts/guardrails.py) | Vendored Layer 1 middleware (jailbreak, XPIA, length, optional CS) |
| [`purview_dlp_middleware.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-guardrails/scripts/purview_dlp_middleware.py) | Vendored Layer 1.5 — Purview DLP enforcement (audit_only / warn / block) |
| [`grant-cs-access.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-guardrails/scripts/grant-cs-access.sh) | Phase B grant: per-agent SP → Cognitive Services User on CS resource |
| [`grant-purview-dlp-access.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-guardrails/scripts/grant-purview-dlp-access.sh) | Phase B grant: tenant-scoped (Purview Information Protection Reader + AIP Service Reader); emits Tenant Admin runbook |
| [`redteam.yml`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-guardrails/scripts/redteam.yml) | PyRIT-in-CI fallback (when cloud red-team region not available) |
| [`kql/guardrail-spans.kql`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-guardrails/scripts/kql/guardrail-spans.kql) | App Insights query: guardrail span count by layer |

## foundry-skills

| Script | What it does |
| --- | --- |
| [`example-script-runner.py`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-skills/scripts/example-script-runner.py) | Canonical safe `script_runner` for `SkillsProvider` (path-traversal guard, 60s timeout, OTel span) |

## foundry-prod-readiness

| Script | What it does |
| --- | --- |
| [`network/check-foundry-network-mode.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/scripts/network/check-foundry-network-mode.sh) | Foundry account network class + ACR public-access flag |
| [`network/check-source-network.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/scripts/network/check-source-network.sh) | Per-resource posture (publicNetworkAccess, ACL defaultAction, IP/VNet rules, PE count) |
| [`network/check-private-endpoint.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/scripts/network/check-private-endpoint.sh) | List PEs on a resource and their approval state |
| [`network/check-private-dns.sh`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/scripts/network/check-private-dns.sh) | Verify the right private DNS zone is linked to the agent's VNet |

## foundry-observability

| Asset | What it does |
| --- | --- |
| [`scripts/kql/`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/tree/main/foundry-agent-skillpack/.apm/skills/foundry-observability/scripts/kql) | KQL cookbook — tool spans, guardrail spans, eval cross-reference, cost queries |

## Conventions

- **Bash**: `set -euo pipefail`; positional args validated with `${1:?usage…}`; `chmod +x`.
- **Python**: standalone (no own `requirements.txt`); `from __future__ import annotations`; lazy SDK imports for optional deps.
- **All scripts**: idempotent; safe to re-run; read-only checks degrade to checklist if Reader missing; mutating scripts emit runbooks when role-preflight fails.

## Read next

- [Reference: Prompts](/reference/prompts/) — the slash commands these scripts back.
- [Reference: Role matrix](/reference/role-matrix/) — every action's required role + scope.
