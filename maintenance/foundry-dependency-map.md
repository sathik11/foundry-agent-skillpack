<!--
  MAINTAINER / CI-ONLY ARTIFACT — DO NOT MOVE UNDER .apm/
  Companion to watch-inventory.md. Shows HOW the watched items link in a real Foundry
  setup, so: (a) the E2E scenario order is derived from the build order, and (b) the fixer
  knows which downstream skills/scripts a given upstream change ripples into.
-->

# Foundry Setup — Dependency Map (W0-T2)

A real hosted-agent setup is built in a fixed order; each stage depends on the prior. The watcher's
findings (watch-inventory.md) attach to stages here, and the **E2E scenarios (W4) walk this order**.

## Build-order graph

```
[0] Prereqs / env-scan
     az ≥2.80 · azd ≥1.24 (+ azd ai agent ext) · python ≥3.12 · apm ≥0.12
     discover-target.sh · assess-project.sh         (api-versions: CognitiveServices 2026-03-01)
        │
        ▼
[1] Identity & RBAC
     project identity · managed identities · role grants
     check-identities.sh · grant-rbac.sh · preflight-role.sh
     DOCS: hosted-agent-permissions · rbac-foundry        PROVIDERS: CognitiveServices
        │
        ▼
[2] Capability host  ← (account scope first, then project scope; 409 otherwise)
     add-capability-host.sh        DATA-PLANE: api-version 2025-11-15-preview
     DOCS: capability-hosts                         (REST: connections + metadata.ResourceId)
        │
        ├────────────► [3a] Knowledge sources (optional, declared in agent-capabilities.yaml)
        │                 ai_search_direct · foundry_iq · file_search · blob_via_indexer · fabric_*
        │                 SDK: azure-search-documents (direct) · deltalake (fabric)
        │                 DOCS: foundry-iq · tools/ai-search · tools/file-search · search/*
        │
        ▼
[4] Deploy path  (mutually exclusive per agent version)
     ┌── container path ──────────────┐     ┌── code/zip path (preview) ───────────────┐
     │ Dockerfile + requirements.txt  │     │ POST /agents code_configuration           │
     │ agent-framework >=1.2.2         │     │ Foundry-Features: CodeAgents=V1Preview     │
     │ agent-framework-foundry-hosting │     │ api-version 2025-11-15-preview             │
     │   ==1.0.0a260429 (alpha)        │     │ azure-ai-projects >=2.2.0 + allow_preview  │
     │ — OR LangGraph BYO template:    │     └────────────────────────────────────────────┘
     │   azure-ai-agentserver-* betas  │
     └─────────────────────────────────┘
     azd up (agent layer) · safe-azd-init.sh · prepare-deploy.sh
     DOCS: hosted-agents · deploy-hosted-agent-code · configure-agent
        │
        ▼
[5] Guardrails (optional layers, declared)
     L0 AGT (TD-29) · L1 middleware (agent-framework) · L1.5 Purview DLP (httpx, opentelemetry-api)
     L2 Content Safety (azure-ai-contentsafety)
     DOCS: tools/governance · purview/ai-microsoft-purview
        │
        ▼
[6] Eval / red-team
     azure-ai-projects (caller) · azure-ai-evaluation ==1.16.6 · BUILT_IN_EVALUATORS set
     ensure_continuous_eval.py · ensure_scheduled_eval.py · ensure_redteam.py
     DOCS: custom-evaluators · run-ai-red-teaming-cloud (region list = TD-9)
        │
        ▼
[7] Observability
     azure-monitor-opentelemetry >=1.7 · App Insights (auto-injected conn string)
     DOCS: (App Insights / OTel)
        │
        ▼
[8] Publish (optional)  ← IDENTITY FLIP: project identity → application identity
     preflight-publish.sh · publish-teams · refan-rbac-post-publish.sh
     PROVIDERS: BotService    DOCS: agent-applications · publish-copilot · bot connector auth
     NETWORK: inbound firewall (APIM/AppGW) for private accounts — APIM v2, validate-jwt, M365 service tags
        │
        ▼
[9] Drift audit (read-only)
     /audit-drift reconciles declared agent-capabilities.yaml vs deployed reality
     SDK: azure-ai-projects (caller)
```

Cross-cutting (apply at several stages):
- **Networking** — managed VNet vs BYO-VNet, private endpoints, private DNS, ACR public-access caveat,
  firewall/NSG/SEP walkers. `api-versions`: Network 2025-05-01 / 2025-07-01 / 2025-09-01. Tenant-specific;
  kept *out* of recipes by design (TESTING_SCENARIOS.md).

## Ripple table (upstream change → what the fixer must touch)

| If this moves upstream… | …these stages/skills change |
|---|---|
| `agent-framework*` alpha/minor | [4] container template, `sdk-surface.md`, `runtime-dependencies.md`, guardrails [5] L1 import |
| `azure-ai-projects` floor/api | [4] code path, [6] eval wrappers, [9] drift, `_common.py`, `code-deploy.md` |
| CognitiveServices api-version | [0] discovery, [1] identity scripts, [2] capability host |
| `2025-11-15-preview` / Foundry-Features | [2] capability host, [4] code path REST |
| Capability-hosts doc | [2] `add-capability-host.sh` + reference doc |
| hosted-agent-permissions / rbac-foundry | [1] roles/identity skills |
| agent-applications / publish-copilot | [8] publish flow, identity-flip re-fan |
| run-ai-red-teaming-cloud region list | [6] `ensure_redteam.py` region constant (TD-9) |
| custom-evaluators / new built-ins | [6] `BUILT_IN_EVALUATORS` + `evaluator-catalog.md` |
| Foundry IQ / AI Search / file-search tools | [3a] knowledge skill + SDK pins |
| Purview for AI | [5] L1.5 DLP middleware + `foundry-purview` |
| APIM v2 / validate-jwt / managed-cert | [8] inbound firewall runbook + bicep |
| Private-link / managed-VNet / virtual-networks | networking cross-cut + `foundry-prod-readiness` |

## How E2E scenarios map onto this order

| Scenario (TESTING_SCENARIOS.md) | Stages exercised |
|---|---|
| 01 Greenfield quickstart | 0→1→2→4(container)→5(L1)→6(continuous) |
| 02 Brownfield onboarding | 0→ code-scan → manifest → 1(verify) → 9(drift baseline) |
| 03 Knowledge + Purview | 0→1→2→3a(foundry_iq)→5(L2+Purview)→6(pii) |
| 04 AI Search + scheduled eval | 0→1→2→3a(ai_search_direct, MI)→6(scheduled gate) |
| 05 APIM-fronted MCP + RBAC + drift | 0→1→2→4→ APIM gateway → 1(per-source RBAC) → 9 |
| 06 Multi-agent orchestration | 0→1→2→4→ sibling-call contracts |
| (code-deploy variant) | 0→1→2→4(**code path**) — exercises 2025-11-15-preview + azure-ai-projects>=2.2.0 |

> The standing baseline infra (`infra/`) provisions the slow stages once (0–2 prerequisites + APIM +
> AI Search + VNet/PE); each E2E run recreates only stage [4]'s agent layer via `azd up`/`azd down`.
