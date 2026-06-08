# RBAC Matrix

Apply in three phases. Phase 1 is one-time per project. Phase 2 is per agent. Phase 3 is per data resource the agent touches.

> Reusable wrapper: [scripts/grant-rbac.sh](scripts/grant-rbac.sh) — applies Phase 1 + Phase 2 in one call.

## Phase 1 — Image Pull (one-time)

| Identity | Role | Scope |
|----------|------|-------|
| Project MI | `AcrPull` | ACR registry |

## Phase 2 — Runtime (per agent)

> Foundry RBAC role rename (TD-30): `Azure AI {User,Owner,Account Owner,Project Manager}` were renamed to `Foundry {…}` (role IDs unchanged). `Azure AI Developer` is **not** a hosted-agent role — per Microsoft Learn it is "insufficient for Hosted agent scenarios" — and has been removed from this matrix. See [foundry-roles/role-matrix.md](../foundry-roles/role-matrix.md#rename-rollout-note-microsoft-foundry-rbac-2026).

| Identity | Role | Scope |
|----------|------|-------|
| Per-agent | `Foundry User` | **Account** (critical) |
| Per-agent | `Foundry User` | Project |
| Per-agent | `Cognitive Services OpenAI User` | Account |
| Per-agent | `Cognitive Services User` | Account |

## Phase 3 — Data Access (capability-driven)

| Resource | Role | Scope |
|----------|------|-------|
| Fabric Lakehouse | Workspace Member (or custom) | Fabric workspace |
| OneLake | Workspace Member or OneLake custom Read | Fabric workspace (NOT Azure Storage RBAC) |
| Cosmos DB | `Cosmos DB Built-in Data Contributor` | Cosmos account |
| Content Safety | `Cognitive Services User` | CS resource |

> RBAC propagation: **5–15 minutes**. After granting, POST a new version (or env-var-only redeploy if env vars changed).

## Capability-aware grants (called by `/configure-rbac`)

Apply only when the matching capability is declared in `agent-capabilities.yaml`:

| When manifest declares… | Grant | Scope | Notes |
|---|---|---|---|
| `fabric.enabled: true` | Workspace `<role>` (Member by default) | Fabric workspace | Print-only today (TD-1). Use Fabric portal or REST with Fabric-aud token. |
| `guardrails.layers` includes `content_safety` | `Cognitive Services User` | Content Safety resource | Then env-var-only redeploy with `AZURE_CONTENT_SAFETY_ENDPOINT`. |
| `toolbox.mcp_servers[].project_connection_id` set | (none — connection ACL handles it) | n/a | Verify connection has the user as Owner; agent uses connection-bound SP. |
| `workiq_teams.enabled: true` | (none auto) | n/a | Bot app + M365 admin Agent 365 registration are user-driven. See [foundry-teams-workiq](../foundry-teams-workiq/SKILL.md). |
| `purview.enabled: true` | (none per-agent) | n/a | Toggle is account-scoped. |

## Identity-not-yet-existing pattern

For every per-agent grant: the `instance_identity.principal_id` does not exist until `azd up` creates the first version.

- `/prepare-deploy` (Phase A) **records** which grants are needed
- `/configure-rbac` (Phase B, run post-deploy) **executes** them once the principal exists

Do not attempt RBAC pre-deploy with a placeholder principal — it fails `PrincipalNotFound` and is not idempotent.
