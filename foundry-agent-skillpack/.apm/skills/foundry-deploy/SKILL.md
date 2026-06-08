---
name: foundry-deploy
description: Build, deploy, and manage Foundry hosted agent versions — scaffold, SDK surface, REST API, version lifecycle, external MCP, capability manifest
---

# Foundry Deploy — Router

| Task | Read |
|------|------|
| Scaffold a new container-based agent (5 files) | [scaffold.md](scaffold.md) |
| **Source-code (zip) deploy path — preview, api-version `2025-11-15-preview`** | [code-deploy.md](code-deploy.md) |
| Container-side vs caller-side Python deps per capability | [runtime-dependencies.md](runtime-dependencies.md) |
| SDK pattern, pinned versions, env vars | [sdk-surface.md](sdk-surface.md) |
| Control-plane REST (`api-version=v1`) | [rest-api.md](rest-api.md) |
| Versions: states, redeploy, rollback, content-addressable dedup | [version-lifecycle.md](version-lifecycle.md) |
| Attach external MCP servers as tools | [external-mcp.md](external-mcp.md) |
| Front the MCP with APIM AI Gateway (auth, rate limit, OAuth, audit) | [apim-as-mcp-frontdoor.md](apim-as-mcp-frontdoor.md) |
| Declare capabilities (toolbox, fabric, guardrails…, `deploy_mode`) | [capabilities-manifest.md](capabilities-manifest.md) |
| **Pick / validate the model deployment (single source of truth for `/plan-agent` Step 0b + `/prepare-deploy` Step 2.4)** | [model-selection.md](model-selection.md) |
| **Per-agent durable state (`agent-status.json`) — schema** | [agent-status-schema.md](agent-status-schema.md) |
| Per-agent state helper (read/update/hash/drift) | [scripts/agent_status.py](scripts/agent_status.py) |
| **Target discovery (account + project + ACR + model in one call)** | [scripts/discover-target.sh](scripts/discover-target.sh) |
| **Full project topology assessment (connections, capabilityHosts, network injection, deployments inventory, hosted agents, identity) — read-only, drives `/assess-project`** | [project-topology.md](project-topology.md) + [scripts/discover-project-topology.sh](scripts/discover-project-topology.sh) + [scripts/discover-project-topology.py](scripts/discover-project-topology.py) |
| **One-shot `/assess-project` wrapper (preflight + discover + format in a single tool round-trip; propagates exit 4 for picklist dispatch)** | [scripts/assess-project.sh](scripts/assess-project.sh) |
| **Bring-your-own capability host bootstrap (account + project, BYO Cosmos/AI Search/Storage) — REST contract, two-scope ordering, RBAC, idempotency** | [capability-host-bootstrap.md](capability-host-bootstrap.md) |
| **`/add-capability-host` mutator (dry-run by default, `--no-dry-run` to apply; backs the `/add-capability-host` prompt)** | [scripts/add-capability-host.sh](scripts/add-capability-host.sh) |
| **Auto-select model deployment (no interactive picklist)** | [scripts/select-model.sh](scripts/select-model.sh) |
| **Guarded azd init (checks for .git / azure.yaml / file clobber)** | [scripts/safe-azd-init.sh](scripts/safe-azd-init.sh) |
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
- **Two deploy paths.** `deploy_mode: container` (default — Docker + ACR) and `deploy_mode: code` (preview — zip + Foundry-built image). They are mutually exclusive on a single agent version. See [code-deploy.md](code-deploy.md) for the preview path and required `Foundry-Features` header.
- **Code-deploy versioning is content-addressable.** A new version is minted only when the zip's SHA-256 or definition changes. "No new version after redeploy" is the expected outcome when nothing changed.

