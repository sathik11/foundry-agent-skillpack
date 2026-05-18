---
title: The capability manifest
description: agent-capabilities.yaml — the one declarative file that drives every prompt in the lifecycle.
---

`agent-capabilities.yaml` sits next to your `agent.yaml` and declares what your agent **uses** — knowledge sources, tools, guardrails, evals, network class, Purview governance. Every lifecycle prompt reads it; per-block dispatch routes to the right skill, the right script, the right RBAC grant.

It is **not merged into `agent.yaml`** — that file's schema is owned by the `azd ai agent` extension. The capability manifest is the skillpack's own additive layer.

```
agents/<name>/
├── agent.yaml                  # ContainerAgent schema (azd ai agent reads)
├── agent-capabilities.yaml     # APM-only — capability gates (this skillpack reads)
├── agent-status.json           # Durable per-agent state (helper writes)
├── Dockerfile
└── main.py
```

## Schema (essentials)

```yaml
schema_version: 1
agent_kind: hosted              # hosted | prompt — must match agent.yaml

capabilities:
  toolbox:
    enabled: true
    mcp_servers:
      - server_label: microsoft_learn
        url: https://learn.microsoft.com/api/mcp
        require_approval: never

  knowledge:
    sources:
      - name: hr-policies
        kind: foundry_iq           # foundry_iq | ai_search_direct | file_search_* | blob_via_indexer | fabric_*
        knowledge_base_name: hr-policy-kb
        search_resource_id: /subscriptions/.../searchServices/kb-prod
        project_connection_name: kb-mcp-prod

  guardrails:
    enabled: true
    layers: [middleware, content_safety, purview_dlp]
    middleware_mode: entry
    content_safety:
      connection_name: cs-prod
      severity_threshold: 4
    purview_dlp:
      enabled: true
      enforcement_mode: audit_only      # audit_only | warn | block
      policies: [dlp-pii-strict]

  purview:
    enabled: true
    audit_required: true
    dspm_inventory: true

  evals:
    role: orchestrator
    judge_model: gpt-4.1-mini
    continuous:
      enabled: true
      sample_rate: 0.2
      evaluators: []          # empty = derive from role + capabilities
    scheduled:                # PREVIEW
      enabled: false
    redteam:                  # PREVIEW + REGION-LOCKED
      enabled: false

  network:
    class: public             # public | managed_vnet | byo_vnet — IMMUTABLE post-deploy
    region: eastus2
```

Full schema with all fields, validation rules, and gate matrix is shipped under the **foundry-deploy** skill — see [`capabilities-manifest.md`](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/capabilities-manifest.md) on GitHub.

## How prompts dispatch on it

| Prompt | What it reads | What it does |
| --- | --- | --- |
| `/plan-agent` | (writes) — interviews user | Asks per-capability questions, scaffolds wiring code only for declared capabilities |
| `/prepare-deploy` | All blocks | Phase A preflight per capability; blocks `azd up` if any required prereq is missing |
| `/configure-rbac` | `fabric`, `purview`, `workiq_teams`, `guardrails.content_safety`, `guardrails.purview_dlp`, `knowledge.sources[]` | Applies per-capability post-deploy grants once agent identity exists |
| `/verify-agent` | All blocks | Per-capability smoke tests (KQL, Graph, Fabric API, AI Search retrieve) |
| `/setup-evals` | `evals` + `guardrails`, `toolbox`, `fabric`, `knowledge` | Picks evaluators based on declared capabilities |
| `/audit-drift` | All blocks | Read-only declared-vs-observed reconciliation |

## Validation rules (selected)

- `agent_kind` must match the kind detected in `agent.yaml`.
- `fabric.enabled: true` requires `network.class: public` (Fabric workspace-level private link is unsupported for hosted agents today).
- `evals.redteam.enabled: true` requires `network.region` in the supported red-team list (East US 2 / France Central / Sweden Central / Switzerland West / North Central US).
- `guardrails.layers` includes `purview_dlp` requires `purview.enabled: true`.
- `guardrails.purview_dlp.enforcement_mode: block` requires `AGREE_PURVIEW_DLP_PREVIEW=1` env var on the agent version.
- `knowledge.sources[].kind == ai_search_direct` with `auth: api_key` requires `network.class: public` (key auth is broken with private VNet).

## Why not put this in `agent.yaml`

Three reasons:

1. **Schema ownership.** `agent.yaml` (ContainerAgent) is owned by the `azd ai agent` extension. Adding skillpack-specific fields would cause the extension to reject the file.
2. **Lifecycle separation.** `agent.yaml` describes the runtime shape; `agent-capabilities.yaml` describes the *cross-cutting concerns* the runtime needs RBAC / network / observability for.
3. **Optional adoption.** A hosted agent works without `agent-capabilities.yaml` (the skillpack just skips the gate dispatch). Two files keeps the line clear.

## Read next

- [Personas and roles](/concepts/personas-and-roles/) — how Phase B grants are applied.
- [`agent-status.json`](/concepts/agent-status/) — what the skillpack writes after each phase.
- [Lifecycle](/concepts/lifecycle/) — order of operations across the 8 prompts.
