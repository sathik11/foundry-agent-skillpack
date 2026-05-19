---
description: Apply RBAC grants for a deployed Foundry hosted agent — base two-identity matrix plus capability-aware grants from agent-capabilities.yaml
input:
  - agent_path: "Path to the agent folder (e.g. agents/learn-agent)"
  - agent_name: "The deployed agent name (e.g. learn-agent)"
  - foundry_account: "Foundry account name (optional — will discover)"
  - resource_group: "Azure resource group (optional — will discover)"
  - subscription_id: "Azure subscription ID (optional — will discover)"
  - post_publish: "Re-fan mode: when 'true', skip Phase 1/2 and re-apply Phase 3 capability grants against the published application identity instead of the per-agent project identity. Set this after /publish-teams flips the agent from project identity to application identity (TD-2). Default 'false'."
mcp:
  - azure
  - foundry
---

# Configure RBAC: ${input:agent_name}

Use **foundry-identity** (base matrix) + capability-aware grants from **foundry-fabric**, **foundry-guardrails**, **foundry-teams-workiq**, **foundry-purview**. Writes durable per-agent state via [agent_status.py](../skills/foundry-deploy/scripts/agent_status.py) (schema: [agent-status-schema.md](../skills/foundry-deploy/agent-status-schema.md)).

> **`post_publish` mode (TD-2).** When invoked with `post_publish=true` (typically by `/publish-teams` after a Teams / M365 Copilot publish flipped the runtime identity), this prompt SKIPS Steps 1–2 and re-runs Step 3 with the **application identity** (Bot Framework app principal) as the target instead of the per-agent project identity. The pre-publish `rbac.capability_grants` entries are preserved for audit; the new grants are written under `rbac.capability_grants_post_publish`. Stamps `publish.rbac_refanned_at` on success. See [foundry-teams-workiq/publish-flow.md § Step 6 — Post-publish RBAC re-fan](../skills/foundry-teams-workiq/publish-flow.md#step-6--post-publish-rbac-re-fan).

## Step 0 — Discover + operator mode (Azure MCP)

Read `operator_mode` from `${input:agent_path}/agent-capabilities.yaml` (default `true` if absent). Export as `OPERATOR_MODE` for all downstream grant scripts — this controls whether they attempt the action (try-first) or immediately emit a runbook.

Discover any inputs not provided: subscription, RG, Foundry account/project, ACR, Content Safety resource (if guardrails declared). Use the same discovery pattern as `/prepare-deploy` Step 0.

> **If `${input:post_publish} == "true"`:** also read `publish.application_identity_principal_id` and `publish.bot_app_id` from `agent-status.json`. STOP with a clear error if either is missing — `/publish-teams` must have run first and stamped them.

## Step 1 — Get identities

> **If `${input:post_publish} == "true"`:** skip the helper call and use `publish.application_identity_principal_id` from `agent-status.json` as `TARGET_PRINCIPAL` for Step 3. Skip Step 2 entirely. Jump to Step 3.

Use the wrapper from **foundry-identity**:

```bash
.agents/skills/foundry-identity/scripts/check-identities.sh \
  <subscription_id> <rg> <foundry_account> <project> ${input:agent_name}
```

It prints `PROJECT_MI=...` and `AGENT_PRINCIPAL=...`. If `AGENT_PRINCIPAL` is empty, STOP and tell the user to run `/prepare-deploy` and `azd up` first.

**Stamp into `agent-status.json`** (creates the file if `/prepare-deploy` was skipped):

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py init \
  --agent-path ${input:agent_path} --agent-name ${input:agent_name} --agent-kind hosted

python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section identities \
  --json '{"project_mi_principal_id":"<PROJECT_MI>","agent_principal_id":"<AGENT_PRINCIPAL>","discovered_at":"<now>"}'
```

## Step 2 — Phase 1 + Phase 2 (single call)

```bash
.agents/skills/foundry-identity/scripts/grant-rbac.sh \
  <subscription_id> <rg> <foundry_account> <project> <acr_name> ${input:agent_name}
```

This applies AcrPull (Project MI) plus the five runtime roles (per-agent identity). Idempotent.

**Stamp completion into `agent-status.json`:**

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section rbac \
  --json '{"phases_completed":["phase1_image_pull","phase2_runtime"],"last_grant_at":"<now>"}'
```

## Step 3 — Phase 3: Capability-aware grants

> **Re-fan mode (`post_publish=true`).** Loop the same per-capability table below, but pass `TARGET_PRINCIPAL=<publish.application_identity_principal_id>` instead of `AGENT_PRINCIPAL` to each grant. Write outcomes to `rbac.capability_grants_post_publish.<key>` (NOT the original `rbac.capability_grants.<key>` — that block records pre-publish state for audit). Skip `fabric` and `purview` rows (they target the project/account, not the runtime identity, so publish-time identity change doesn't affect them).

Load `${input:agent_path}/agent-capabilities.yaml`. For each declared capability, apply the matching grant from **foundry-identity** § "Capability-aware grants":

| Manifest block | Action |
|---|---|
| `knowledge.sources[]` | Per source: run `.agents/skills/foundry-knowledge/scripts/verify-source-rbac.sh <kind> <resource_id> <CALLER_OID> <AGENT_PRINCIPAL>` to determine which grants are missing, then apply the role per [foundry-knowledge](../skills/foundry-knowledge/SKILL.md) sub-doc for that kind. (Project MI is granted once per Search service for `foundry_iq` / `blob_via_indexer` / `ai_search_direct`.) |
| `fabric.enabled: true` | Print Fabric portal steps + REST snippet (TD-1, print-only). Ask the user if they want to attempt the API call — needs Fabric-aud token. |
| `guardrails.layers` includes `content_safety` | Run `.agents/skills/foundry-guardrails/scripts/grant-cs-access.sh ${input:agent_name} <cs_resource_id>`; then env-var-only redeploy with `AZURE_CONTENT_SAFETY_ENDPOINT`. |
| `toolbox.mcp_servers[].project_connection_id` | Verify the connection grants the agent identity access (Foundry portal → Connection → Access). Print steps. |
| `workiq_teams.enabled: true` | Print Teams Admin Center upload + M365 Admin Agent 365 registration steps. |
| `purview.enabled: true` | No per-agent grant. Confirm toggle is ON (per **foundry-purview** Phase A). |

**Stamp each grant outcome into `agent-status.json`** under `rbac.capability_grants` (when applied) or `rbac.pending` (when runbook-only). Use dotted-key naming `<top>.<sub>.<name>`:

```bash
# Successful grant
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --path 'rbac.capability_grants.guardrails.content_safety.cs-prod' \
  --json '{"role":"Cognitive Services User","scope":"<cs_resource_id>","granted_to":"<AGENT_PRINCIPAL>","granted_at":"<now>"}'

# Runbook-only (e.g. Fabric)
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section rbac \
  --json '{"pending":[{"key":"fabric.workspace.<workspace>","reason":"print-only TD-1","runbook_emitted":true,"noted_at":"<now>"}]}'
```

## Step 4 — Verify and announce propagation window

Print the applied roles. State: "RBAC propagation: 5–15 minutes for new principals. Run `/verify-agent` after 10 minutes."

If any capability grant could not be auto-applied (Fabric, Teams, Purview toggle), surface them as a checklist of remaining manual steps.

**Re-baseline the capability hash** so `/verify-agent` can detect post-RBAC drift:

```bash
HASH=$(python .agents/skills/foundry-deploy/scripts/agent_status.py hash --agent-path ${input:agent_path})
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --path 'drift.capability_hash_at_rbac' \
  --json "\"$HASH\""
```

**If `${input:post_publish} == "true"`:** also stamp the re-fan completion timestamp:

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --path 'publish.rbac_refanned_at' \
  --json "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
```
