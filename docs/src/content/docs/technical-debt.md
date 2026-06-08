---
title: Technical debt
description: Tracked gaps, trade-offs, and partial implementations — with rationale and close-out plan for each.
---

The on-disk source of truth is [`TECHNICAL_DEBT.md`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/TECHNICAL_DEBT.md) inside the engineering package. This page is the same content rendered for the docs site.

## Open

| ID | Status | Title | Owning skill |
| --- | --- | --- | --- |
| TD-1 | Open (workaround) | Fabric workspace role assignment is print-only | foundry-fabric |
| TD-3 | Open (preview API) | WorkIQ "is agent registered" check is beta API | foundry-teams-workiq |
| TD-4 | **Partial close (v0.16.0)** | Foundry-native DLP is preview-limited — middleware ships in `audit_only` default; `block` mode requires explicit ack until API GA confirmed | foundry-guardrails (Layer 1.5) |
| TD-5 | Open (low priority) | `apm.yml` has no `repository:` cross-link to skills | (none) |
| TD-6 | Open (CI gap) | No CI gate runs `apm install` against external consumer projects | (CI) |
| TD-7 | Open (UX) | Agent identity propagation timing is not handled gracefully | foundry-identity / `/verify-agent` |
| TD-8 | Open (preview SDK drift) | `azure-ai-projects` SDK surface drift | foundry-evals |
| TD-9 | Open (region staleness) | Cloud red-team region list is hard-coded | foundry-evals |
| TD-13 | Open (deferred by design) | Brownfield code scan is regex-only | foundry-knowledge |
| TD-14 | **Planned (v0.19)** | External persistence for Invocations agents | foundry-deploy (planned) |
| TD-15 | **Planned (post-1.0)** | Microsoft Learn submission | (project) |
| TD-16 | **Planned (when users complain)** | Per-capability requirements snippets + injection helper | foundry-deploy |
| TD-17 | **Phase 1 shipped (v0.18.0)** | Docs site drift from skillpack sources — set-difference drift check; full mirror in Phase 2 | (project / docs) |
| TD-18 | **Open (mitigated, v0.19.0)** | Foundry MCP lacks native `model_deployment_list` — skillpack routes through Azure MCP `mcp_azure_mcp_foundry` for the enumeration call | foundry-deploy / model-selection |
| TD-19 | **Open (alias active, v0.19.0)** | Package renamed `foundry-agent-harness` → `foundry-agent-skillpack` — `aliases:` keeps old name resolving for one release; consumers must update `apm.yml` before v0.20.0 | (project) |
| TD-26 | **Open (preventive)** | Resource Graph hybrid for `discover-target.sh` — one ARG query for accounts + projects + ACRs (eliminates api-version drift class) + parallel `account deployment list` fan-out; verified PoC 4× faster than today | foundry-deploy / discover-target |
| TD-27 | **Open (preventive)** | No central registry of api-versions — inline `api-version=` strings in `az rest` calls silently drift; proposes `.apm/scripts/_api-versions.sh` constants + shared error-surfacing helper | (project / scripts) |
| TD-28 | **Open (bake-off v0.24, decision v0.25)** | Cross-OS script runtime — skillpack is bash-only; Windows needs WSL2 (Git Bash unsupported); dual bash + PowerShell-7 siblings under formal evaluation with parity-test harness in v0.24, ship decision (migrate vs stay-and-document) in v0.25 | (project / scripts) |
| TD-29 | **Open (adopt + integrate, v0.24 firm)** | [Microsoft Agent Governance Toolkit](https://github.com/microsoft/agent-governance-toolkit) (AGT) as a declarable runtime-governance layer — new `runtime_governance: agt` key in `agent-capabilities.yaml`, container `requirements.txt` injection, template `govern(...)` wraps, OTel cross-link to AGT decisions, `/audit-drift` reconciles policy file. AGT is the runtime layer; we are the deploy+lifecycle layer. See [Related work](/concepts/related-work/) | foundry-guardrails / foundry-deploy / agent-capabilities.yaml |

## Closed

| ID | Closed in | Title |
| --- | --- | --- |
| TD-2 | v0.20.0 | Teams publish orchestration — `/publish-teams` + `/configure-rbac post_publish=true` + `publish` schema section |
| TD-10 | v0.20.0 | Network detection deep walkers (NSG / Azure Firewall / SEP) behind `--deep` + BYO-VNet Bicep scaffold + troubleshooter runbook |
| TD-11 | v0.11.0 | `agent-status.json` durable state |
| TD-12 | v0.17.0 | `/audit-drift` prompt |
| TD-23 | v0.22.0 | Inbound firewall coverage for Teams / M365 Copilot → private Foundry agent — `foundry-teams-workiq/inbound-firewall.md` + APIM v2 Bicep + render-apim-policy.sh + probe-inbound-chain.sh + additive `publish.inbound_chain` schema block |
| TD-24 | v0.23.0 | api-version drift in `az rest` calls — 4 versions bumped to current GA (discover-target / check-identities / check-service-endpoint-policy / deep-walk-firewall / two-identities.md); explicit stderr capture replaces silent `\|\| echo '[]'` swallow in discover-target |
| TD-25 | v0.23.0 | `discover-target.sh` enumerated sub-resources only for account [0] — multi-account RGs silently lost projects + deployments; per-account loop emits `ACCOUNT_<n>_PROJECT_NAMES=` / `ACCOUNT_<n>_DEPLOYMENT_NAMES=` aggregate keys |
| TD-30 | v0.24.0 | Foundry RBAC role rename (`Azure AI {User,Owner,Account Owner,Project Manager}` → `Foundry {…}`) + `Azure AI Developer` misuse — `grant-rbac.sh` now uses role-definition GUIDs; `preflight-role.sh` is alias-aware; incorrect `Azure AI Developer` grants/preflights replaced with `Foundry User` / `Foundry Project Manager` per the hosted-agent permissions reference |
| TD-31 | v0.25.0 | Source-code (zip) deploy preview path was missing entirely — folds in G-1 through G-6: new `foundry-deploy/code-deploy.md` reference (zip layout, multipart REST, SDK Python `project.beta.agents.create_version_from_code` + `allow_preview=True`, SDK .NET `CreateAgentVersionFromCode`, `remote_build` vs `bundled` packaging, `code:download`, 250MB limit); `Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview` header + `api-version=2025-11-15-preview` for the code path; `version-lifecycle.md` content-addressable versioning + `x-ms-code-zip-sha256` drift detection; `agent-status-schema.md` v1.3 additive (`deploy.deploy_mode` / `deploy.zip_sha256` / `deploy.runtime` / `deploy.dependency_resolution`); `capabilities-manifest.md` `deploy_mode: container\|code` + `code:` block + Gate Matrix row; F-21–F-28 in `foundry-failure-modes` (`400 CPU/Memory tier`, `400 still being provisioned`, `424 session_not_ready` + `:logstream`, `409 Agent has active sessions` + `&force=true`, version stuck `creating` >10 min → `bundled`, `ModuleNotFoundError` → `--platform manylinux2014_x86_64 --only-binary=:all:`, `409 AgentNotCodeBased`, `401 Unauthorized` → `--resource https://ai.azure.com`); `/prepare-deploy` Step 1 forks on `deploy_mode` with new Track H-Code (H6-H11); `/plan-agent` Track B asks deploy_mode then forks Step 3 vs Step 3-Code |
| TD-32 | v0.26.0 | Pre-development Foundry project topology discovery was missing entirely — new general skillpack capability (see [Concepts → Project assessment](./concepts/project-assessment.md)). `/assess-project` prompt + `discover-project-topology.sh` (single ARM walk, KEY=VALUE stdout, eight grouped prefixes, Foundry-grade gate, exit codes 0/2/3) + `discover-project-topology.py` (verdict formatter emitting `project-topology.md` + `project-topology.json` + `agent-capabilities.draft.yaml` stub); `foundry-deploy/project-topology.md` reference with api-version pins (`accounts/projects`, `accounts/projects/connections`, `accounts/projects/capabilityHosts`, `accounts/networkInjections` on `2026-03-01` GA; `accounts/projects/agents` on `v1` via `https://ai.azure.com` audience per F-28); explicit Foundry Toolkit boundary matrix; `/plan-agent` Step 0a new Step 0 cached-topology fast path; `/prepare-deploy` Step 2.5 new cross-check block (warns on three mismatch patterns, additive `preflight.topology_crosscheck`); `/troubleshoot` Step 3 new Scenario 4 hook (re-checks topology when symptom matches gap pattern); six recurring scenarios documented (portal-provisioned silent gap, missing knowledge connection, joining 6-month-old project, continuous-eval traces missing, pre-deploy CI gate, pre-sales briefing) |
| TD-33 | v0.26.0 | `/assess-project` UX collapsed from three tool round-trips into one — new `foundry-deploy/scripts/assess-project.sh` wrapper chains preflight (non-blocking best-effort) + discover + format in a single bash invocation; propagates exit codes (esp. exit 4 ambiguous-account/project picklist); emits machine-readable pointers on stdout (`ASSESSMENT_REPORT_MD=…` / `ASSESSMENT_REPORT_JSON=…` / `ASSESSMENT_STUB_YAML=…`); `/assess-project` prompt Steps 0+1+2 collapsed into Step 1 (single wrapper call); `preflight-roles.sh` new `assess-project` alias case (Reader on RG) |
| TD-34 | v0.26.0 | Real remediation for ⚠ `Capability hosts` verdict (initial verdict-softening reflex was rejected as sloppy — capability hosts are GA at api-version `2026-03-01`; `ENABLE_CAPABILITY_HOST=false` is the azd-extension scaffold default only). End-to-end fix: hidden defect — `discover-project-topology.sh` § 4 now probes BOTH account-level AND project-level capability hosts (was only project-level, missed bare account hosts like `agents-3iq-eastus2/default`) with new `CAPHOST_{ACCOUNT,PROJECT}_*` signals + per-host detail (NAME / KIND / PROV_STATE / THREAD_CONNECTIONS / VECTOR_CONNECTIONS / STORAGE_CONNECTIONS / AISERVICES_CONNECTIONS); hidden defect — every connection now emits `CONNECTION_<n>_RESOURCE_ID=` (capability host runtime requires `metadata.ResourceId` populated, else silently falls back to default storage); rewritten `verdict_capability_hosts` (four cases: neither / account-only / project-only / both BYO full-vs-partial); new reference doc `foundry-deploy/capability-host-bootstrap.md` (REST shape at both scopes, naming convention, two-scope ordering rule, required connections with `metadata.ResourceId`, idempotency contract — no UPDATE, only DELETE + CREATE — RBAC matrix, verification GETs, common failure modes, **bring-your-own existing Azure resource (inline connection create)** section with per-category PUT body shapes captured live from a working project); new mutator `foundry-deploy/scripts/add-capability-host.sh` (dry-run by default, `--no-dry-run` to mutate, `--scope account\|project\|both`, `--{thread,vector,storage,aiservices}-conn`, **`--{thread,vector,storage}-resource-id <arm-id>` for BYO inline create from EXISTING Azure resources** with provider-segment validation per role + Step 7a post-PUT GET verification, `--auto-pick`, `--force-recreate`, polls `provisioningState` to `Succeeded`, exit codes 0/1/2/3/4/5; latent bug fix — wrong category constant `AzureCosmosDb` (real API uses `CosmosDb`); project-hint matcher leaf-name fallback in `discover-project-topology.sh`); new prompt `/add-capability-host` (7 steps: preflight → cached topology pickup → connection selection picklist OR two-option BYO prompt when category has zero connections — portal-create vs paste ARM ID → dry-run ALWAYS first → explicit `yes` consent → apply → re-verify; new inputs `thread_resource_id` / `vector_resource_id` / `storage_resource_id`); `preflight-roles.sh` new `add-capability-host` alias case (Contributor on Foundry account scope — `Cognitive Services Contributor` is **not** sufficient); `/assess-project` Step 5 new (offers handoff to `/add-capability-host` when ⚠); `instructions/foundry-conventions.md` + `prepare-deploy.prompt.md` env-var clarification (`ENABLE_CAPABILITY_HOST=false` is azd scaffold default, not platform-wide) with cross-link to `capability-host-bootstrap.md`; **RBAC is load-bearing — `--grant-rbac` flag (same release):** live test against eastus2 reached `provisioningState=Failed` in ~3min even with all 3 BYO connections wired and verified — root cause: project SystemAssigned MI lacked data-plane RBAC on backing Cosmos/Search/Storage; recovery destructive AND blocked once an agent is linked. New `--grant-rbac` flag grants the 6 required roles to project MI before the capHost PUT (Cosmos DB Operator + Cosmos DB Built-in Data Contributor [data plane, separate `az cosmosdb sql role assignment create` CLI surface]; Search Service Contributor + Search Index Data Contributor; Storage Account Contributor + Storage Blob Data Owner), idempotent (`RoleAssignmentExists` → success) with 30s AAD propagation sleep; new exit code 6 for grant failure; new KV outputs `GRANT_RBAC_STATUS` + `GRANTS_COUNT`. Prompt grew Step 2.5 "Confirm RBAC posture" + `grant_rbac` input + new forbidden shortcut ("never PUT capHost without verifying the 6 grants are in place"); `capability-host-bootstrap.md` got new "Required project-MI data-plane RBAC (load-bearing)" section with canonical CLI block. Lesson: `az role assignment list --assignee <objId>` resolves to appId form — use `--assignee-object-id` to query/grant; the Cosmos data-plane role does NOT appear in regular `az role assignment list` (only in `az cosmosdb sql role assignment list`) |

## Pattern

Each TD entry on disk follows this shape:

```markdown
## TD-N — <title>

**What:** <the gap, in one sentence>.

**Why deferred:** <the trade-off>.

**Close-out:** <what would actually close this>.
```

When a TD closes, the **What** stays for history; **Why deferred** is replaced with **Status:** showing what was shipped and where; **Close-out** moves to follow-ons (open as separate TDs when prioritized).

## Why we track these explicitly

Three reasons:

1. **Honest scope.** The skillpack ships preview-adjacent integrations against a moving target. TDs are how we tell consumers "this works for X, not for Y, here's why."
2. **Triggered close-outs.** Many TDs (TD-4, TD-8, TD-9) close when an upstream surface stabilizes. The daily docs-scan workflow (planned) is the trigger. Listing them keeps them surfaceable.
3. **Push-back ammunition.** When someone asks "why doesn't audit-drift auto-fix?" the answer is in the TD list — TD-12 was closed deliberately *without* auto-fix; the rationale is recorded.

## Read next

- [Roadmap](/roadmap/) — sequenced view of what's next.
- [Contributing](/contributing/) — how to propose closing a TD.
