# Agent Capabilities Manifest

`agent-capabilities.yaml` declares which Foundry integrations a single agent uses. It sits **next to** `agent.yaml` (or `agent-definition.yaml` for prompt agents) — it is **not** merged into either, because both have schemas owned by the `azd ai agent` extension and Foundry runtime respectively.

```
agents/<name>/
├── agent.yaml                  # ContainerAgent schema (azd ai agent reads)
├── agent-capabilities.yaml     # APM-only — capability gates
├── Dockerfile
├── main.py
└── ...
```

`/plan-agent` writes this file. `/prepare-deploy` reads it pre-`azd up` to dispatch preflight checks. `/configure-rbac` reads it post-`azd up` to apply capability-specific role assignments. `/verify-agent` reads it to run capability-specific smoke tests. `/setup-evals` reads it to choose evaluators.

## Schema

```yaml
# agent-capabilities.yaml
schema_version: 1
agent_kind: hosted              # hosted | prompt — must match agent.yaml

# ── Operator mode (written by /plan-agent Step 0a) ───────────────────────
# Controls whether grant scripts attempt actions directly (try-first) or
# immediately emit runbooks without trying (preflight-only).
# true  (default) — try the az/REST call; runbook only on 403.
# false — emit runbook without attempting (for SOC-monitored environments
#         where unauthorized attempts trigger security alerts).
# See foundry-roles/operator-mode.md for the full pattern.
operator_mode: true

# ── Deployment target (written by /plan-agent Step 0a) ────────────────────
# Source of truth for sub / RG / project across the lifecycle. /prepare-deploy
# Step 2 reads this BEFORE prompting the user; it only re-prompts if a field
# is missing or the user passes resource_group= as an explicit override.
target:
  subscription: 11111111-2222-3333-4444-555555555555
  resource_group: agents-eastus2
  foundry_account: agents-eastus2-acct      # Cognitive Services / AI Services account name
  foundry_project: my-project               # project under the account
  region: eastus2

# ── Model (written by /plan-agent Step 0b; consumed everywhere) ───────────
# Single source of truth for the model the agent uses. Overrides the
# MODEL_DEPLOYMENT_NAME env-var placeholder in agent.yaml templates.
# /prepare-deploy Step 2.4 validates `deployment_name` exists in `target.foundry_account`.
# See foundry-deploy/model-selection.md for the selection algorithm.
model:
  catalog_name: gpt-4.1-mini                # Foundry catalog model id (NEVER fabricated — picked from catalog or existing deployments)
  deployment_name: gpt-4.1-mini             # the actual deployment name in target.foundry_account
  version: "2025-04-14"                     # optional; pinned when /plan-agent Step 0b deploys a new one
  sku_name: GlobalStandard                  # GlobalStandard | Standard | DataZoneStandard | ProvisionedManaged
  capacity: 120                             # TPM in thousands (only meaningful when /plan-agent deployed it)

capabilities:

  # ── External MCP servers + Foundry Toolbox ──────────────────────────────
  toolbox:
    enabled: true
    # Foundry Toolbox / Fabric Data Agent connection (optional)
    connection_name: msft-learn-toolbox
    # Direct external MCP servers (any number)
    mcp_servers:
      - server_label: microsoft_learn
        url: https://learn.microsoft.com/api/mcp
        require_approval: never
      - server_label: company_internal
        project_connection_id: company-mcp-prod   # use connection_id if private
        require_approval: always

  # ── Knowledge sources (Foundry IQ, AI Search, file-search, blob-via-search) ──────────
  # See foundry-knowledge/SKILL.md and decision-tree.md for choosing kinds.
  knowledge:
    sources:
      - name: hr-policies
        kind: foundry_iq                 # foundry_iq | ai_search_direct | file_search_basic |
                                         # file_search_standard | blob_via_indexer |
                                         # fabric_data_agent | fabric_direct_delta | sharepoint_via_iq
        knowledge_base_name: hr-policy-kb
        search_resource_id:    /subscriptions/.../Microsoft.Search/searchServices/kb-prod
        project_connection_name: kb-mcp-prod
        acl_passthrough: false           # use x-ms-query-source-authorization header

      - name: kb-direct
        kind: ai_search_direct
        resource_id: /subscriptions/.../Microsoft.Search/searchServices/kb-prod
        index_name:  docs-v2
        auth: managed_identity           # managed_identity | api_key (deprecated; broken with private VNet)

      # Fabric paths cross-link to foundry-fabric — same kind taxonomy, full schema there.
      # WARNING: fabric_* HARD BLOCK if network.class != public.

  # ── Microsoft Fabric workspace integration ─────────────────────────────
  fabric:
    enabled: false
    workspace_id: 11111111-2222-3333-4444-555555555555
    workspace_name: sales-analytics
    items:
      - data-agent-orders
      - lakehouse-sales
    role: Member                        # Viewer | Member | Contributor | Admin
    access_path: toolbox                # toolbox | direct_delta | hybrid

  # ── Microsoft Teams + WorkIQ + Agent 365 ────────────────────────────────
  workiq_teams:
    enabled: false
    # Channel publishing (Teams → agent) — orchestrated by /publish-teams (TD-2)
    bot_app_id: 00000000-0000-0000-0000-000000000000
    register_in_agent365: true
    # Optional: pin the agent object model so /publish-teams skips detection.
    # Leave unset to let the prompt detect via mcp_foundry_mcp_agent_get.
    # agent_identity_model: new          # new | legacy
    # MCP tool path (agent → Teams)
    teams_mcp_connection_id: WorkIQTeams2

  # ── Guardrails (defense-in-depth) ──────────────────────────────────────
  guardrails:
    enabled: true
    # Layer 1 = vendored middleware; Layer 1.5 = Purview DLP enforcement;
    # Layer 2 = Content Safety; Layer 3 = continuous eval + cloud red-team
    layers: [middleware, content_safety]
    middleware_mode: entry              # entry | payload (see foundry-guardrails)
    content_safety:
      connection_name: cs-prod
      severity_threshold: 4             # 0=Safe 2=Low 4=Medium 6=High
    # purview_dlp — Layer 1.5; Foundry-hosted-only enforcement gap, see foundry-guardrails/purview-dlp.md
    purview_dlp:
      enabled: false                    # opt-in; PREVIEW — read purview-dlp.md § 'Honest preview limitations' first
      enforcement_mode: audit_only      # audit_only | warn | block (block requires AGREE_PURVIEW_DLP_PREVIEW=1 env var)
      policies: []                      # Purview-side policy IDs (e.g. dlp-pii-strict)
      classify_agent_response: true
      classify_tool_results: false      # +1 classification per tool call — latency cost
    redteam:
      gate_in_ci: true
      max_attack_success_rate: 0.05

  # ── Purview / DLP / DSPM ───────────────────────────────────────────────
  purview:
    enabled: true
    # Required: tenant must have M365 E7 OR Agent 365 licensing.
    audit_required: true                # AIInvokeAgent / AIExecuteTool to audit
    dspm_inventory: true                # Foundry account toggle must be ON
    dlp:
      enabled: false                    # Foundry-specific DLP is preview-limited
      policies: []
      # NOTE: Full DLP (SIT scanning, label enforcement) requires the Purview
      # SDK middleware. Foundry-native DLP is not GA. See foundry-purview.

  # ── Evaluation strategy (continuous + scheduled + cloud red-team) ─────────────────────────
  evals:
    role: orchestrator                  # orchestrator | ingestion | enrichment | narrative | prompt
    judge_model: gpt-5.4-mini-1
    interval_hours: 1                   # legacy field; new wrappers prefer the nested blocks below
    max_traces: 200                     # legacy field; superseded by continuous.max_hourly_runs

    continuous:
      enabled: true
      sample_rate: 0.20
      max_hourly_runs: 100
      judge_model: gpt-5.4-mini-1
      evaluators: []                    # explicit overrides; omit to derive from role + capabilities
      redact_score_properties: false

    scheduled:                          # PREVIEW — see foundry-evals/scheduled-eval.md
      enabled: false
      cron: "0 2 * * *"
      timezone: UTC
      dataset:
        kind: jsonl                     # jsonl | dataset_id
        path: ./eval/regression-set.jsonl
      evaluators: []
      pass_threshold:
        task_adherence: 4.0
        groundedness: 4.0

    redteam:                            # PREVIEW + REGION-LOCKED — see foundry-evals/redteam.md
      enabled: false
      schedule:
        cron: "0 3 * * 0"               # weekly Sunday 03:00 UTC; omit for one-shot only
        timezone: UTC
      risk_categories:                  # subset of: violence, sexual, hate_unfairness, self_harm, prohibited_actions
        - violence
        - hate_unfairness
        - prohibited_actions
      attack_strategies:                # subset of: base64, character_play, jailbreak, indirect_jailbreak, role_play
        - base64
        - jailbreak
        - indirect_jailbreak
      num_objectives: 10
      pass_threshold:
        max_attack_success_rate: 0.05

  # ── Network class (set ONCE — immutable post-deploy) ─────────────────────────────────
  network:
    class: public                       # public | managed_vnet | byo_vnet
    region: eastus2                     # used by foundry-evals to gate cloud red-team
    managed_vnet:                       # only when class == managed_vnet
      outbound_mode: allow_internet     # allow_internet | allow_only_approved
      managed_pe_targets:               # resources to provision managed PEs to
        - /subscriptions/.../Microsoft.Search/searchServices/kb-prod
        - /subscriptions/.../Microsoft.Storage/storageAccounts/raw
    byo_vnet:                           # only when class == byo_vnet
      vnet_id:   /subscriptions/.../Microsoft.Network/virtualNetworks/foundry-vnet
      subnet_id: /subscriptions/.../subnets/agent-subnet  # delegated to Microsoft.App/environments, /27+
      firewall_egress_fqdns_extra: []   # over and above the standard agents allowlist
```

All capability blocks are **optional**. Omit blocks the agent does not use; do not set `enabled: false` for blocks you simply do not need (omission is the default).

## How prompts dispatch on this manifest

| Prompt | What it reads | What it does |
|---|---|---|
| `/plan-agent` | (writes) — interviews user, emits the file | Step 0a elicits `target.*`; Step 0b runs [model selection](./model-selection.md); Step 4 asks per-capability questions; scaffolds wiring code only for declared capabilities |
| `/prepare-deploy` | `target.*`, `model.*`, all capability blocks | Step 0 caller-role preflight; Step 2 confirms `target` (only re-prompts if missing); Step 2.4 validates `model.deployment_name` and forks on 404; Phase A preflight per capability; blocks `azd up` if any required prereq is missing |
| `/configure-rbac` | `target.*`, `fabric`, `purview`, `workiq_teams`, `guardrails.content_safety`, `knowledge.sources[]` | Applies per-capability post-deploy grants once agent identity exists. With `post_publish=true` re-fans Phase 3 grants against the published application identity (see `/publish-teams` Step 6) |
| `/verify-agent` | All blocks | Per-capability smoke tests (KQL, Graph, Fabric API, AI Search retrieve) |
| `/setup-evals` | `evals` + `guardrails`, `toolbox`, `fabric`, `knowledge`, `model.deployment_name` (judge model fallback) | Picks evaluators based on declared capabilities (e.g. `tool_call_accuracy` only if `toolbox.enabled` or `fabric.access_path == toolbox`; `groundedness` if any `knowledge.sources[]`) |
| `/publish-teams` | `target.*`, `workiq_teams.*`, `network.class`, `evals.continuous_rule_id` (from status), `purview.enabled` | Preflight (BotService RP + secret scan + gates), patches `agent.yaml` authorization scheme, prints publish CLI, captures identity flip, dispatches `/configure-rbac --post-publish` for the RBAC re-fan, emits M365 admin approval runbook. Stamps `publish` section in `agent-status.json`. |

## Gate Matrix (preflight + post-deploy by capability)

| Capability | Phase A (pre-`azd up`) | Phase B (`/configure-rbac` post-deploy) | Phase C (`/verify-agent`) | Owning skill |
|---|---|---|---|---|
| `toolbox` | URL is real `https://`, no `${VAR}` placeholders; private connections exist | none (covered by Phase 2 RBAC) | `execute_tool` spans for each `server_label` | `foundry-deploy` |
| `fabric` | Workspace exists; record items + role; **HARD BLOCK if `network.class != public`** (Fabric Data Agent unsupported) | Print Fabric workspace role-assignment steps for instance principal (see Tech Debt) | Hit a Fabric tool, expect `200`, no `403` | `foundry-fabric` |
| `workiq_teams` | Agent 365 license, bot Entra app, WorkIQ connection | none auto on `/configure-rbac` first pass — `/publish-teams` (TD-2) handles publish, then dispatches `/configure-rbac post_publish=true` to re-fan grants to the application identity | Agent appears in Graph `admin/people/agents`, Teams app status `Allowed`, `publish.rbac_refanned_at` stamped in agent-status.json | `foundry-teams-workiq` |
| `guardrails` | Middleware wired in `main.py`; CS connection exists; vendored `guardrails.py` present | `Cognitive Services User` to per-agent identity on CS resource | `guardrail.*` spans present; sample blocked input is refused | `foundry-guardrails` |
| `purview` | Tenant licensing; toggle is ON at Foundry account; declared DLP policies exist (warn if `dlp.enabled` and Foundry preview limits apply) | none auto — toggle is account-scoped | Audit query for `AIInvokeAgent` shows agent within ~30 min | `foundry-purview` |
| `evals.continuous` | `Azure AI User` on project; judge model deployed; evaluators in catalog (or registered if custom) | none | Rule exists; Monitor tab shows runs after traffic | `foundry-evals` |
| `evals.scheduled` | Same as continuous + dataset reachable / file present | none | Schedule exists; first run completes per cron | `foundry-evals` |
| `evals.redteam` | Same as continuous + **project region in supported list** (East US 2 / France Central / Sweden Central / Switzerland West / North Central US) | none | Scan exists; ASR ≤ `pass_threshold.max_attack_success_rate` | `foundry-evals` |
| `network.class != public` | Run all four network detection scripts; ACR public-access ENABLED; chosen outbound mode honors data residency requirements | Approve managed PEs (`Azure AI Enterprise Network Connection Approver`); link private DNS zones | `nslookup` from inside VNet returns private IP; tool calls succeed | `foundry-prod-readiness` |
| `knowledge.sources[]` | Per source: existence + caller RBAC + per-agent-SP RBAC plan + network-class compatibility (HARD BLOCK on `fabric_*` if network.class != public) | Per source: ProjectMI / per-agent SP grants on Search / Storage; KB MCP connection creation if `foundry_iq` | Per source: smoke retrieve, citations present, `execute_tool` span for the bound MCP / connection | `foundry-knowledge` |

## Validation rules

- `agent_kind` must equal the kind detected in `agent.yaml` / `agent-definition.yaml`.
- `target.*` is REQUIRED once `/plan-agent` has run; `/prepare-deploy` STOPs if missing and re-runs the elicitation. Empty top-level `target:` is acceptable for hand-authored manifests — `/prepare-deploy` Step 2 will fill it interactively.
- `model.deployment_name` is REQUIRED for hosted (Track H) agents and prompt (Track P) agents. Never auto-fabricated — must come from the [model selection](./model-selection.md) algorithm. /prepare-deploy STOPs if absent.
- `model.catalog_name` SHOULD match a catalog id; skillpack warns (does not block) if it cannot resolve via `mcp_foundry_mcp_model_catalog_list`.
- `workiq_teams.enabled: true` requires `purview.audit_required: true` (otherwise Agent 365 inventory will not populate Purview).
- `fabric.access_path: direct_delta` requires `guardrails.middleware_mode: payload` if this agent is a sub-agent (large payloads).
- `toolbox.mcp_servers[].url` must NOT contain `${...}` after env-var expansion.
- `purview.dlp.enabled: true` MUST print the preview-only-limitations callout from `foundry-purview` and require explicit user acknowledgement.
- `fabric.enabled: true` is **incompatible** with `network.class` other than `public` (Fabric Data Agent doesn't support workspace-level private link). `/prepare-deploy` STOPs with a clear message.
- `evals.redteam.enabled: true` requires `network.region` in the supported red-team region list (currently East US 2 / France Central / Sweden Central / Switzerland West / North Central US). `ensure_redteam.py` hard-fails preflight otherwise.
- `network.class: managed_vnet` with `outbound_mode: allow_only_approved` requires every declared `toolbox.mcp_servers[].url` and `knowledge.sources[]` to be in the FQDN allowlist or behind a managed PE.
- `knowledge.sources[].kind in {fabric_data_agent, fabric_direct_delta}` requires `network.class: public`. `verify-source-network.sh` HARD BLOCKs otherwise; cannot be ack'd around.
- `knowledge.sources[].kind == ai_search_direct` with `auth: api_key` requires `network.class: public`. Switch to `auth: managed_identity` before going private.
- When any `knowledge.sources[]` is declared, `evals.continuous.evaluators` will auto-include `groundedness` unless the user explicitly excludes it.
- `guardrails.layers` includes `purview_dlp` requires `purview.enabled: true` (DLP enforcement is meaningless without the audit substrate). `/prepare-deploy` STOPs otherwise.
- `guardrails.purview_dlp.enforcement_mode: block` requires `AGREE_PURVIEW_DLP_PREVIEW=1` env var on the agent version. The middleware constructor refuses to start without it. See [foundry-guardrails/purview-dlp.md § Honest preview limitations](../foundry-guardrails/purview-dlp.md).

## Minimal example (the sandbox `learn-agent`)

```yaml
schema_version: 1
agent_kind: hosted
target:
  subscription: 11111111-2222-3333-4444-555555555555
  resource_group: agents-eastus2
  foundry_account: agents-eastus2-acct
  foundry_project: learn-project
  region: eastus2
model:
  catalog_name: gpt-4.1-mini
  deployment_name: gpt-4.1-mini
  sku_name: GlobalStandard
  capacity: 120
capabilities:
  toolbox:
    enabled: true
    mcp_servers:
      - server_label: microsoft_learn
        url: https://learn.microsoft.com/api/mcp
        require_approval: never
  guardrails:
    enabled: true
    layers: [middleware]
    middleware_mode: entry
  evals:
    role: orchestrator
    judge_model: gpt-5.4-mini-1
    interval_hours: 1
```
