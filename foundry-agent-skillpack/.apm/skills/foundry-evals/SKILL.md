---
name: foundry-evals
description: Continuous evaluation, scheduled evaluation, and cloud red-team for Foundry hosted agents — declared in agent-capabilities.yaml, created via azure-ai-projects SDK so rules are PR-reviewable and audited inside Foundry
---

# Foundry Evaluations — Router

| Topic | Read |
|---|---|
| Continuous eval (sampling live traffic) | [continuous-eval.md](continuous-eval.md) |
| Scheduled eval (preview — periodic against dataset) | [scheduled-eval.md](scheduled-eval.md) |
| Cloud red-team (preview — region-restricted) | [redteam.md](redteam.md) |
| Built-in evaluators + capability mapping | [evaluator-catalog.md](evaluator-catalog.md) |
| Idempotent rule create/update | [scripts/ensure_continuous_eval.py](scripts/ensure_continuous_eval.py) |
| Idempotent scheduled-eval create/update | [scripts/ensure_scheduled_eval.py](scripts/ensure_scheduled_eval.py) |
| Idempotent red-team create/update | [scripts/ensure_redteam.py](scripts/ensure_redteam.py) |
| Shared client + role check | [scripts/_common.py](scripts/_common.py) |

## One-line truths

- **No magic flag.** Setting `ENABLE_INSTRUMENTATION=true` only emits OTel. Continuous eval, scheduled eval, and red-team are **explicit resources** you create via `azure-ai-projects>=2.0.0` (or the portal).
- **Same backing store as the portal.** SDK-created rules show up in the Monitor tab dashboard with the same `report_url`. Audit lives inside Foundry.
- **Required role:** `Azure AI User` on the project. Preflighted by [foundry-roles](../foundry-roles/scripts/preflight-role.sh).
- **Custom evaluators are a separate flow.** Register them first via the Custom Evaluators API, then reference by ID. Don't mix built-in and unregistered custom IDs in one rule.
- **Red-team is region-locked** (East US 2 / France Central / Sweden Central / Switzerland West / North Central US as of 2026-05-14). The `ensure_redteam.py` script hard-fails preflight with the region list — it does not skip silently.

## Cross-skill references

- Role preflight (`Azure AI User`) → [foundry-roles/role-matrix.md](../foundry-roles/role-matrix.md)
- Capability declarations that drive evaluator selection → [foundry-deploy/capabilities-manifest.md](../foundry-deploy/capabilities-manifest.md)
- Layer 1+2 runtime guardrails (CS, middleware) → [foundry-guardrails](../foundry-guardrails/SKILL.md)
- Trace dashboard reading → [foundry-observability](../foundry-observability/SKILL.md)

## Maintenance note

`azure-ai-projects` is moving fast. Pin `>=2.0.0,<3` in any consumer `requirements.txt` and bump deliberately. Class names referenced by the wrappers:
- `EvaluationRule`, `ContinuousEvaluationRuleAction`, `EvaluationRuleFilter`, `EvaluationRuleEventType`
- `ProjectsSchedule`, `RecurrenceTrigger`, `EvaluationScheduleTask`
- `RedTeam`, `AzureAIAgentTarget`, `AttackStrategy`, `RiskCategory`
