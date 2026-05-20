---
title: Reference — Prompts
description: All 9 slash commands the skillpack ships, with inputs and step lists.
---

The skillpack ships **9 slash commands** under `.github/prompts/` (or your client's equivalent target). Six form the linear lifecycle; three are operational.

| Prompt | Purpose | Lifecycle stage |
| --- | --- | --- |
| [`/plan-agent`](#plan-agent) | Interview + scaffold a new agent OR onboard existing code | Pre-deploy |
| [`/prepare-deploy`](#prepare-deploy) | Per-capability gate dispatch + initialize `agent-status.json` | Pre-deploy |
| [`/configure-rbac`](#configure-rbac) | Identity discovery + Phase 1/2/3 RBAC grants (+ `post_publish` re-fan) | Post-deploy |
| [`/verify-agent`](#verify-agent) | Drift check + smoke test + capability verification | Post-deploy |
| [`/setup-evals`](#setup-evals) | Continuous + scheduled + cloud red-team eval rules | Post-deploy |
| [`/setup-purview`](#setup-purview) | Toggle Purview integration + wire DLP middleware | Operational |
| [`/publish-teams`](#publish-teams) | Orchestrate Teams / M365 Copilot publish + identity-flip RBAC re-fan | Operational |
| [`/troubleshoot`](#troubleshoot) | Symptom → diagnosis matrix | Operational |
| [`/audit-drift`](#audit-drift) | Read-only declared-vs-observed reconciliation | Operational |

## /plan-agent

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `agent_name` | ✓ | kebab-case, e.g. `learn-agent` |
| `description` | ✓ | one-liner — what the agent does + which tools/data |
| `operator_mode` | – | `true|false` (default `true`). Stamped into `agent-capabilities.yaml`; downstream prompts read it from there. Set `false` for SOC-monitored environments where unauthorized attempts trigger alerts. |

**Skills referenced:** `foundry-patterns` · `foundry-deploy` · `foundry-multi-agent` · `foundry-guardrails` · `foundry-purview` · `foundry-teams-workiq` · `foundry-roles` (+ `foundry-agent-playbook` for recipe lookups).

**Steps:**
- **Step 0a** — Target discovery + caller-role preflight. Runs [`discover-target.sh`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-target.sh) to find account / project / ACR / model in one call; then [`preflight-roles.sh plan-agent`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-roles/scripts/preflight-roles.sh) for batch role check. Stamps `operator_mode: true` + `target:` block in `agent-capabilities.yaml`.
- **Step 0b** — Model selection via [`select-model.sh`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/select-model.sh). Auto-selects when unambiguous (hint match → single deployment → first agents-capable); interactive only when `MODEL_SELECTION_METHOD=manual-needed`. Stamps `model:` block.
- **Step 0c** — Track selection (A wrap / B scaffold / C prompt agent).
- **Tracks A/B/C** generate the agent files.
- **Step 4** — Capability interview (toolbox / knowledge / fabric / teams / guardrails / purview / evals).
- **Step 5** — Wire only declared capabilities.

**Writes:** `agent-capabilities.yaml` (with `target:` and `model:` blocks; populated capability blocks for what the user said yes to). Optionally agent-framework template files (`Dockerfile`, `agent.yaml`, `main.py`, `requirements.txt`, `tools.py`, `guardrails.py`).

**Anti-synthesis guard:** the prompt forbids `az`/`curl`/`python -c` shortcuts and forbids echoing model names from recipes/samples. Every value comes from a listed MCP tool or an explicit user picklist selection.

## /prepare-deploy

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `agent_path` | ✓ | e.g. `agents/learn-agent` |
| `resource_group` | – | discovered from manifest `target:` if omitted |
| `deep_network` | – | `true|false` (default `false`). Enables NSG / Azure Firewall / SEP walkers (TD-10 Layer 1). Adds 60–120s per source. Has no effect when `network.class == public`. |

**Skills referenced:** `foundry-deploy` · `foundry-identity` · `foundry-roles` · `foundry-knowledge` · `foundry-fabric` · `foundry-guardrails` · `foundry-purview` · `foundry-teams-workiq` · `foundry-prod-readiness` · `foundry-failure-modes`.

**Steps:**
0. **Caller-role + target preflight (FAIL-FAST).** Reads `operator_mode` + `target:` from `agent-capabilities.yaml`; exports `OPERATOR_MODE` for downstream scripts. Only re-elicits on missing fields (runs [`discover-target.sh`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-target.sh) if needed). Batch role check via [`preflight-roles.sh prepare-deploy`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-roles/scripts/preflight-roles.sh) for `Contributor` on RG + `Azure AI Developer` on project.
1. Detect agent kind (hosted vs prompt).
2. Foundry resource validation (re-uses Step 0 target; only re-prompts for ACR on Track H).
   - **Step 2.4** — Model deployment validation. If `MODEL_DEPLOYMENT_NAME` already populated by `discover-target.sh` or `/plan-agent` Step 0b, validates it exists; 3-way fork only on 404 (pick existing / deploy-with-consent / print runbook).
   - **Step 2.5** — Read `agent-capabilities.yaml` and dispatch per-capability Phase A.
3. `azure.yaml` validation.
4. RBAC preflight recap (already enforced in Step 0).
5. `apm audit`.
6. Hand off to `azd up`.

**Writes:** `agent-status.json` `preflight.capabilities.*`, `network.*`, `drift.capability_hash_at_preflight`. May also stamp the `target:` and `model:` blocks back into `agent-capabilities.yaml` if Step 0 had to elicit them.

## /configure-rbac

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `agent_path` | ✓ | e.g. `agents/learn-agent` |
| `agent_name` | ✓ | matches `agent.yaml` name |
| `foundry_account` | – | discovered |
| `resource_group` | – | discovered |
| `subscription_id` | – | discovered |
| `post_publish` | – | `true|false` (default `false`). When `true`, skips Phase 1/2 and re-fans Phase 3 against the published **application identity** instead of the project identity (run after `/publish-teams`). TD-2 close-out. |

**Skills referenced:** `foundry-identity` · `foundry-roles` · `foundry-deploy` · `foundry-knowledge` · `foundry-fabric` · `foundry-guardrails` · `foundry-purview` · `foundry-teams-workiq`.

**Steps:**
1. Discover identities; stamp `identities` into status. *(skipped when `post_publish=true`)*
2. Phase 1 (AcrPull) + Phase 2 (5 runtime roles); stamp `rbac.phases_completed`. *(skipped when `post_publish=true`)*
3. Phase 3 capability-aware grants (Fabric / CS / knowledge sources / Purview DLP); stamp `rbac.capability_grants` per success or `rbac.pending` per runbook.
4. Re-baseline `drift.capability_hash_at_rbac`.

**`post_publish` mode (TD-2 close-out).** When `true`, skips Steps 1–2 and re-fans Phase 3 against `publish.application_identity_principal_id` (from `agent-status.json`, stamped by `/publish-teams`). Writes to `rbac.capability_grants_post_publish` (preserves pre-publish state for audit). Skips `fabric` and `purview` rows (account/project-scoped, not identity-scoped). Stamps `publish.rbac_refanned_at`.

**Writes:** `agent-status.json` `identities`, `rbac.*`, `drift.capability_hash_at_rbac`, optionally `rbac.capability_grants_post_publish` + `publish.rbac_refanned_at`.

## /verify-agent

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `agent_name` | ✓ | matches `agent.yaml` name |
| `test_query` | ✓ | simple test message sent to the agent |
| `agent_path` | – | enables per-capability post-deploy gates from `agent-capabilities.yaml` |

**Skills referenced:** `foundry-deploy` · `foundry-observability` · `foundry-guardrails` · `foundry-purview` · `foundry-fabric` · `foundry-teams-workiq` · `foundry-failure-modes`.

**Steps:**
- **Step −1** Drift check (capability hash) — STOPs and asks user if drift detected.
- 0. Discover endpoint; stamp `deploy`.
- 1. Invoke endpoint with `test_query`.
- 2. Interpret response.
- 3. Tool spans (KQL).
- 4. Guardrail spans (KQL).
- 5. Report.
- 6. Per-capability post-deploy verification.
- 7. Stamp `verify` block.

**Writes:** `agent-status.json` `deploy`, `verify.{last_run_at, last_run_status, capability_results, ...}`.

## /setup-evals

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `agent_name` | ✓ | e.g. `my-agent-v3` |
| `agent_path` | – | reads `agent-capabilities.yaml` for evaluator auto-selection |
| `agent_role` | – | override: `orchestrator` \| `ingestion` \| `enrichment` \| `narrative` \| `prompt` |
| `judge_model` | – | override judge model deployment |
| `include_scheduled` | – | `true|false` (default `true`). Skips scheduled eval when `false` or when not declared in manifest. |
| `include_redteam` | – | `true|false` (default `true`). Skips cloud red-team when `false`, not declared, or region unsupported. |

**Skills referenced:** `foundry-evals` · `foundry-observability` · `foundry-guardrails` · `foundry-roles`.

**Steps:**
0. Role preflight (`Azure AI User` on project).
1. Read manifest.
2. Continuous eval — `ensure_continuous_eval.py` (always).
3. Scheduled eval — `ensure_scheduled_eval.py` (preview; opt-in).
4. Cloud red-team — `ensure_redteam.py` (preview + region-locked; opt-in).
5. Verify (KQL + portal pointer).
6. Explain behavior.
7. Optional one-off eval.

**Writes (planned):** `agent-status.json` `evals.{continuous_rule_id, scheduled_rule_id, redteam_scan_id, evaluators, judge_model, last_setup_at}`.

## /setup-purview

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `foundry_account` | ✓ | the Foundry AI Services account name where the Purview toggle is flipped |

**Skills referenced:** `foundry-purview` · `foundry-guardrails`.

**Steps:**
1. Confirm tenant licensing (M365 E5 / Agent 365).
2. Confirm caller has admin role for the toggle.
3. Flip the Purview toggle in the Foundry account.
4. Verify DSPM inventory in Purview portal.
5. Verify audit signal in Purview Audit search.
6. Optional: create DLP policy in Purview portal.
7. Wire Layer 1.5 DLP middleware in `agent-capabilities.yaml` + `main.py`.
8. Disclose limitations.

## /publish-teams

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `agent_path` | ✓ | e.g. `agents/learn-agent` |
| `agent_name` | ✓ | matches `agent.yaml` name |
| `bot_app_id` | – | Bot Framework Entra app ID — discovered from `agent-capabilities.yaml` `workiq_teams.bot_app_id` if omitted |
| `m365_admin_runbook_only` | – | `true|false` (default `false`). When `true`, skip publish + RBAC re-fan; only re-emit the M365 admin approval runbook from existing publish state. Useful if the admin lost the original message. |

**Skills referenced:** `foundry-teams-workiq` · `foundry-identity` · `foundry-deploy` · `foundry-evals` · `foundry-purview` · `foundry-roles`.

Orchestrates publishing a deployed Foundry agent to Microsoft Teams / M365 Copilot. Handles both agent object models (new vs legacy) and — critically — the **identity flip** that happens at publish time: per MS Learn, tool calls authenticated by agent identity use the **application identity** after publishing, not the project identity. Pre-publish RBAC grants from `/configure-rbac` break silently unless re-fanned.

**Steps:**
0. If `m365_admin_runbook_only=true`, jump to Step 7.
1. Detect agent object model via `mcp_foundry_mcp_agent_get`. Legacy (`identity == null`) falls back to the existing `teamsapp` runbook in [foundry-teams-workiq SKILL](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-teams-workiq/SKILL.md).
2. Preflight (hard gates) via [`preflight-publish.sh`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-teams-workiq/scripts/preflight-publish.sh): `Microsoft.BotService` RP registered, no BYO-VNet ↔ public Bot Service mismatch, continuous-eval rule present, Purview middleware enabled, publish-metadata secret scan clean.
3. Patch `agent.yaml` to add `BotServiceRbac` authorization scheme + `activity_protocol.enabled: true` (idempotent YAML merge).
4. Print the publish CLI (`azd ai agent publish …`) — operator runs it (mutating event stays operator-visible).
5. Capture identity flip: read `identity.applicationPrincipalId` post-publish; stamp `agent-status.json` `publish` block.
6. Dispatch `/configure-rbac post_publish=true` to re-fan Phase 3 grants against the application identity. Writes to `rbac.capability_grants_post_publish` (preserves pre-publish state). Stamps `publish.rbac_refanned_at`.
7. Emit M365 admin approval runbook (paste-ready message with governance attestation: eval rule, Purview state, network class, last verify). Stamp `publish.m365_admin_approval_runbook_emitted_at`.
8. Announce post-15-minute verification step (`/verify-agent` against the published surface).

**Writes:** `agent-status.json` `publish.*` (new schema v1.1 section); dispatches `/configure-rbac` for `rbac.capability_grants_post_publish.*`.

**Full flow doc:** [foundry-teams-workiq/publish-flow.md](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-teams-workiq/publish-flow.md).

## /troubleshoot

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `symptom` | ✓ | free text — error message, HTTP code, or observed behavior |
| `agent_name` | – | which agent is affected (helps narrow the lookup) |

**Skills referenced:** `foundry-failure-modes`.

**Routes** to the matching entry in [foundry-failure-modes](/skills/) and surfaces the one-line fix. Common entry points: `container exits 1`, `403 on first invoke`, `tool spans missing`, `model not found`, `version stuck creating`.

## /audit-drift

**Parameters:**

| Input | Required | Notes |
| --- | --- | --- |
| `agent_path` | ✓ | e.g. `agents/learn-agent` |
| `agent_name` | ✓ | matches `agent.yaml` name |
| `subscription_id` | – | discovered |
| `resource_group` | – | discovered |
| `foundry_account` | – | discovered |
| `project_name` | – | discovered |
| `report_path` | – | default `.audit-reports/<agent_name>-<YYYY-MM-DD>.md` |
| `include_reverse_drift` | – | `true|false` (default `true`). Scan for live state not declared in manifest. |

**Skills referenced:** `foundry-deploy` · `foundry-identity` · `foundry-knowledge` · `foundry-prod-readiness` · `foundry-roles`.

**Hard rule:** read-only. Never mutates Azure, Foundry, Purview, or `agent-capabilities.yaml`. The only writes are: (a) the markdown report file, (b) the `verify` block in `agent-status.json`.

**Steps:**
0. Caller `Reader` preflight.
1. Read `agent-capabilities.yaml` + `agent-status.json`.
2. Capability hash check.
3. Identities cross-reference.
4. Walk capability blocks (toolbox / knowledge — including per-kind control-plane content checks / guardrails / purview / evals / network / RBAC). Forward + reverse drift.
5. Compose markdown report.
6. Stamp `agent-status.json` `verify.{last_audit_at, audit_summary, audit_report_path}`.
7. Print SUMMARY + RECOMMENDATIONS to user.

**Operational notes:** designed for weekly CI scheduling. **NOT** a PR gate (live state changes without code edits) — gate PRs on `/verify-agent` instead.

## Reading further

- [Lifecycle](/concepts/lifecycle/) — what each prompt writes to `agent-status.json` and when to re-run.
- [Personas and roles](/concepts/personas-and-roles/) — the runbook handoff for tenant-scoped operations.
- [Reference: Scripts](/reference/scripts/) — every runnable script the prompts invoke.
