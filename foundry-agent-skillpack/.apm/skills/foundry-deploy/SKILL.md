---
name: foundry-deploy
description: Build, deploy, and manage Foundry hosted agent versions — scaffold, SDK surface, REST API, version lifecycle, external MCP, capability manifest
---

# Foundry Deploy — Router

| Task | Read |
|------|------|
| Scaffold a new agent (5 files) | [scaffold.md](scaffold.md) |
| Container-side vs caller-side Python deps per capability | [runtime-dependencies.md](runtime-dependencies.md) |
| SDK pattern, pinned versions, env vars | [sdk-surface.md](sdk-surface.md) |
| Control-plane REST (`api-version=v1`) | [rest-api.md](rest-api.md) |
| Versions: states, redeploy, rollback | [version-lifecycle.md](version-lifecycle.md) |
| Attach external MCP servers as tools | [external-mcp.md](external-mcp.md) |
| Front the MCP with APIM AI Gateway (auth, rate limit, OAuth, audit) | [apim-as-mcp-frontdoor.md](apim-as-mcp-frontdoor.md) |
| Declare capabilities (toolbox, fabric, guardrails…) | [capabilities-manifest.md](capabilities-manifest.md) |
| **Pick / validate the model deployment (single source of truth for `/plan-agent` Step 0b + `/prepare-deploy` Step 2.4)** | [model-selection.md](model-selection.md) |
| **Per-agent durable state (`agent-status.json`) — schema** | [agent-status-schema.md](agent-status-schema.md) |
| Per-agent state helper (read/update/hash/drift) | [scripts/agent_status.py](scripts/agent_status.py) |
| Scaffold templates (agent-framework + langgraph-byo) | [templates/](templates/) |

## Cross-skill references

- RBAC matrix → [foundry-identity](../foundry-identity/SKILL.md)
- Caller-side role preflight + runbook emit → [foundry-roles](../foundry-roles/SKILL.md)
- Knowledge sources (Foundry IQ, AI Search, file-search, blob-via-search) → [foundry-knowledge](../foundry-knowledge/SKILL.md)
- Native file-based skills inside the agent (SkillsProvider) → [foundry-skills](../foundry-skills/SKILL.md)
- Middleware code → [foundry-guardrails](../foundry-guardrails/SKILL.md)
- Continuous / scheduled / cloud red-team eval wrappers → [foundry-evals](../foundry-evals/SKILL.md)
- Network class + detection scripts → [foundry-prod-readiness/networking.md](../foundry-prod-readiness/networking.md)
- Read-only declared-vs-observed reconciler → `/audit-drift` prompt (`.github/prompts/audit-drift.prompt.md` after install)
- Failure lookup → [foundry-failure-modes](../foundry-failure-modes/SKILL.md)

## Critical reminders

- Versions immutable; always POST new
- `environment_variables` full-replace
- Reserved prefixes: `FOUNDRY_*`, `AGENT_*`, `APPLICATIONINSIGHTS_*` → 400
- `FoundryAgent` v1.1.1 class silently no-ops — use client-swap (see [sdk-surface.md](sdk-surface.md))

