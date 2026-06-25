<!--
  MAINTAINER / CI-ONLY ARTIFACT — DO NOT MOVE UNDER .apm/
  This file is the canonical "watch surface": every external dependency the skillpack
  tracks. The twice-weekly upstream watcher (W2) reads the machine-readable registry
  (maintenance/versions.yaml) for SDK + api-version rows; this doc is the human-readable
  superset that also covers doc topics and runtime tooling.
  End users never receive this file — `apm install` ships only foundry-agent-skillpack/.apm/**.
-->

# Foundry Skillpack — Watch-Surface Inventory (W0-T1)

**Purpose.** Enumerate *everything external* the skillpack depends on, so the watcher knows what to
poll and the fixer knows what breaks when upstream moves. Three classes: **SDK packages** (PyPI),
**ARM api-versions** (`az provider show`), **doc topics** (Microsoft Learn), plus **runtime tooling**.

**Baseline date:** 2026-06-24 — anchored at skillpack package **v0.27.0**, tag `baseline-v0.27.0`.
**Last manual review (W0-T3):** 2026-06-24 — see [`reviews/2026-06-24-baseline-review.md`](reviews/2026-06-24-baseline-review.md) (11 open major findings → watcher's first batch).

Legend — `deploy_path`: `all` | `container` (Dockerfile path) | `code` (zip/source path) | `caller`
(runs on laptop/CI, not in the agent image) | `optional` (only if a capability is declared).

---

## 1. SDK packages (poll: PyPI JSON API `https://pypi.org/pypi/<name>/json`)

| Package | Current pin | deploy_path | Where used (repo) | Risk / notes |
|---|---|---|---|---|
| `agent-framework` | `>=1.2.2` | container | `templates/requirements.txt.template`, `sdk-surface.md`, `runtime-dependencies.md`, guardrails middleware import | Core hosting SDK. Surface changed between alphas — watch minor bumps. |
| `agent-framework-foundry-hosting` | `==1.0.0a260429` | container | same templates + `sdk-surface.md` | **Alpha, exact pin.** API changed `a260415`→`a260429`. Highest-churn item; any new alpha is a *major* finding. |
| `azure-identity` | `>=1.19.0,<1.26.0a0` | all | every wrapper + templates | Ceiling avoids `1.26.0bX` betas. Watch when `1.26.0` GAs to lift ceiling. |
| `azure-ai-projects` | `>=2.0.0,<3` (code path: `>=2.2.0,<3`) | caller | `_common.py`, `/setup-evals`, `/audit-drift`, `runtime-dependencies.md`, `code-deploy.md` | Control-plane SDK. Code/zip deploy needs `>=2.2.0` + `allow_preview=True`. Two floors — keep both rows. |
| `azure-ai-agentserver-responses` | `==1.0.0b5` | container | LangGraph BYO template, `runtime-dependencies.md` | Beta exact pin (LangGraph path). |
| `azure-ai-agentserver-core` | `==2.0.0b3` | container | LangGraph BYO template, `runtime-dependencies.md` | Beta exact pin (LangGraph path). |
| `langgraph` | `==1.1.8` | container | LangGraph BYO template | Pinned with prebuilt/core — bump in lockstep. |
| `langgraph-prebuilt` | `==1.0.10` | container | LangGraph BYO template | Lockstep with `langgraph`. |
| `langchain-core` | `==1.3.0` | container | LangGraph BYO template | Lockstep with `langgraph`. |
| `langchain-azure-ai[opentelemetry]` | `>=1.2.3` | container | LangGraph BYO template | OTel extra. |
| `azure-monitor-opentelemetry` | `>=1.7` | container (recommended) | `runtime-dependencies.md`, templates | Telemetry; not auto-included by `agent-framework`. |
| `azure-ai-contentsafety` | `>=1.0.0` | optional (guardrails L2) | `runtime-dependencies.md`, guardrails | Only if `content_safety` layer declared. |
| `azure-ai-evaluation` | `==1.16.6` | caller | evals scripts / catalog | Exact pin — watch for evaluator-catalog drift. |
| `azure-search-documents` | `>=11.5` | optional (knowledge) | `runtime-dependencies.md` | Only if direct `SearchClient` used. |
| `azure-cosmos` | `>=4.7` | optional (persistence, TD-14 planned) | `runtime-dependencies.md` | Not yet implemented. |
| `redis` | `>=5.0` | optional (persistence, TD-14 planned) | `runtime-dependencies.md` | Not yet implemented. |
| `deltalake` | `>=0.18` | optional (knowledge `fabric_direct_delta`) | `runtime-dependencies.md` | Direct OneLake Delta read. |
| `httpx` | `>=0.27` | optional (Purview DLP L1.5) | `runtime-dependencies.md`, `purview_dlp_middleware.py` | Only if `purview_dlp` layer declared. |
| `opentelemetry-api` | `>=1.27` | optional (Purview DLP L1.5) | `runtime-dependencies.md` | Spans for DLP middleware. |
| `pyyaml` | (unpinned) | caller | every wrapper reading `agent-capabilities.yaml` | Stable; low priority. |

> **Built-in evaluator IDs** (`_common.py BUILT_IN_EVALUATORS`, dated 2026-05-14) are a *secondary*
> SDK-coupled surface: when `azure-ai-projects`/`azure-ai-evaluation` ship new evaluators, update the
> set **and** `evaluator-catalog.md`. Watcher should diff this list against the docs evaluator catalog.

## 2. ARM api-versions (poll: `az provider show -n <ns> --query resourceTypes`)

| api-version | Provider / resource type | Where used (repo) | Verify command |
|---|---|---|---|
| `2026-03-01` | `Microsoft.CognitiveServices/accounts` (+ `/projects`, `/deployments`) | `discover-target.sh`, `check-identities.sh`, identity docs | `az provider show -n Microsoft.CognitiveServices --query "resourceTypes[?resourceType=='accounts'].apiVersions"` |
| `2025-11-15-preview` | Foundry agents data-plane (`POST /agents`, code-deploy) | `code-deploy.md`, `rest-api.md`, `add-capability-host.sh`, capability-host docs | Data-plane (not ARM) — verify against Learn code-deploy doc + a known-good probe. |
| `2025-11-01-preview` | `Microsoft.CognitiveServices/accounts/projects` (preview surfaces) | identity / capability-host scripts | `az provider show` as above (preview list). |
| `2025-09-01` | `Microsoft.Network/azureFirewalls` ruleCollectionGroups | `deep-walk-firewall.sh` | `az provider show -n Microsoft.Network --query "resourceTypes[?resourceType=='azureFirewalls'].apiVersions"` |
| `2025-07-01` | `Microsoft.Network` service-endpoint policies | `check-service-endpoint-policy.sh` | `az provider show -n Microsoft.Network ...` |
| `2025-05-01` | `Microsoft.Network/virtualNetworks` | network walkers | `az provider show -n Microsoft.Network ...` |
| `2024-07-01` | misc (legacy GA still valid) | assorted | confirm still-GA on touch |

## 3. Preview feature flags / headers (poll: Learn docs; no ARM source)

| Flag | Value in repo | Where used | Notes |
|---|---|---|---|
| `Foundry-Features` header | `CodeAgents=V1Preview,HostedAgents=V1Preview` | code-deploy + REST docs/scripts | Harmless on GET; required on code-deploy POST. Watch for GA (header drop). |
| Hosted-agent deploy mode | `container` vs `code` (`azd ai agent init --deploy-mode`) | `foundry-deploy` skill | Two parallel paths; both must stay covered. |

## 4. Canonical Microsoft Learn doc topics (poll: Learn MCP / fetch + diff)

Each row: a doc whose *content changing* forces a skillpack edit. `owner` = skill that must change.

| Topic | URL | Owning skill(s) |
|---|---|---|
| Hosted agents (concepts, sandbox sizes) | `…/foundry/agents/concepts/hosted-agents` | foundry-deploy |
| Deploy hosted agent from source code (preview) | `…/foundry/agents/how-to/deploy-hosted-agent-code` | foundry-deploy (code path) |
| Agent object model / configure-agent | `…/foundry/agents/how-to/configure-agent` | foundry-deploy, foundry-patterns |
| Capability hosts | `…/ai-foundry/agents/concepts/capability-hosts` | foundry-deploy (`add-capability-host`) |
| Hosted-agent permissions | `…/foundry/agents/concepts/hosted-agent-permissions` | foundry-identity, foundry-roles |
| Agent applications (publish identity flip) | `…/foundry/agents/how-to/agent-applications` | foundry-teams-workiq |
| Publish to M365 Copilot / Teams | `…/foundry/agents/how-to/publish-copilot` | foundry-teams-workiq |
| Foundry RBAC built-in roles | `…/foundry/concepts/rbac-foundry#built-in-roles` | foundry-roles, foundry-identity |
| Private link / outbound isolation | `…/foundry/how-to/configure-private-link` | foundry-prod-readiness |
| Managed VNet | `…/foundry/how-to/managed-virtual-network` | foundry-prod-readiness |
| Virtual networks (agents) | `…/foundry/agents/how-to/virtual-networks` | foundry-prod-readiness |
| Run AI Red Teaming in the cloud | `…/foundry/how-to/develop/run-ai-red-teaming-cloud` | foundry-evals (red-team SDK) **[P0]** |
| Evaluation region support / rate limits / VNet | `…/ai-foundry/concepts/evaluation-regions-limits-virtual-network` | foundry-evals (TD-9 region list — authoritative source) **[P0]** |
| Custom evaluators | `…/foundry/concepts/evaluation-evaluators/custom-evaluators` | foundry-evals **[P0]** |
| What is Foundry IQ | `…/foundry/agents/concepts/what-is-foundry-iq` | foundry-knowledge |
| Foundry IQ connect | `…/foundry/agents/how-to/foundry-iq-connect` | foundry-knowledge |
| AI Search tool | `…/foundry/agents/how-to/tools/ai-search` | foundry-knowledge |
| File-search tool | `…/foundry/agents/how-to/tools/file-search` | foundry-knowledge |
| Governance tool | `…/foundry/agents/how-to/tools/governance` | foundry-guardrails |
| AI gateway (agents) | `…/foundry/agents/how-to/ai-gateway` | foundry-deploy, foundry-teams-workiq |
| Manage hosted sessions | `…/foundry/agents/how-to/manage-hosted-sessions` | foundry-deploy (persistence) |
| Purview for AI | `…/purview/ai-microsoft-purview` | foundry-purview, foundry-guardrails |
| APIM GenAI gateway / MCP / v2 tiers / validate-jwt / managed-cert suspension | `…/api-management/*` (genai-gateway-capabilities, mcp-server-overview, secure-mcp-servers, v2-service-tiers-overview, validate-jwt-policy, integrate-vnet-outbound, breaking-changes/managed-certificates-suspension-august-2025) | foundry-teams-workiq |
| Bot Framework connector auth | `…/bot-service/rest-api/bot-framework-rest-connector-authentication` | foundry-teams-workiq |
| AI Search agentic retrieval / blob indexer RBAC | `…/search/*` (agentic-retrieval-how-to-create-knowledge-base, search-blob-indexer-role-based-access, search-how-to-index-azure-blob-storage, search-security-enable-roles) | foundry-knowledge |
| M365 URLs & IP ranges (Teams service tags) | `…/microsoft-365/enterprise/urls-and-ip-address-ranges` | foundry-teams-workiq (inbound firewall) |

## 5. Runtime tooling (poll: CLI `--version` / release notes)

| Tool | Floor | Where pinned | Notes |
|---|---|---|---|
| `az` (Azure CLI) | `>=2.80` | `scripts/install-prereqs.sh`, README | All `az rest` / discovery scripts. |
| `azd` (Azure Dev CLI) | `>=1.24` | install-prereqs, TESTING_SCENARIOS | + `azd ai agent` extension for hosted-agent deploy. |
| `azd ai agent` extension | (tracks azd) | install-prereqs | Hosted-agent init/deploy gestures. |
| `python` | `>=3.12` | install-prereqs | Wrapper scripts. |
| `apm` (CLI) | `>=0.12` (targets plural) | apm.yml comments | Install mechanism. |
| `jq` | any | install-prereqs | Shell JSON parsing. |

## 6. Provider registrations the skillpack assumes

`Microsoft.CognitiveServices`, `Microsoft.BotService` (publish path) — see
`foundry-roles/scripts/ensure-provider-registration.sh`. Add `Microsoft.Search`, `Microsoft.Network`
when those scenarios are exercised in E2E.

---

## How the watcher consumes this

- **Machine-readable subset** for SDK + api-version rows → `maintenance/versions.yaml` (W1-T1); the
  generator (W1-T2) renders the shipped pin files from it; the watcher (W2) diffs `versions.yaml`
  against PyPI + `az provider show`.
- **Doc topics** (§4) → the watcher fetches each URL, hashes/diffs the relevant section, and routes a
  finding to the `owning skill` for the fixer (W2-T2/W2-T3).
- **Classification** of any delta follows the major/minor/breaking rules in `plan.md`.
