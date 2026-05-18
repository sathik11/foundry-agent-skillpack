---
name: foundry-knowledge
description: Choose, declare, and verify knowledge sources for Foundry hosted agents — Foundry IQ, direct AI Search, file-search tool, blob-via-indexer; cross-links Fabric. Includes brownfield code scan, RBAC verifier, and network-class compatibility matrix.
---

# Foundry Knowledge — Router

| Topic | Read |
|---|---|
| Decision tree (which kind to pick) | [decision-tree.md](decision-tree.md) |
| Foundry IQ (multi-source knowledge base via MCP) | [foundry-iq.md](foundry-iq.md) |
| Direct Azure AI Search index (single index) | [ai-search.md](ai-search.md) |
| File search tool (Basic + Standard agent setup) | [file-search-tool.md](file-search-tool.md) |
| Blob via AI Search indexer (canonical RAW pattern) | [blob-via-search.md](blob-via-search.md) |
| Fabric Data Agent / direct Delta read | [foundry-fabric](../foundry-fabric/SKILL.md) |
| Network-class compatibility matrix | [network-compatibility.md](network-compatibility.md) |
| Brownfield code scan (regex; agent-framework + LangGraph) | [scripts/scan_knowledge_refs.py](scripts/scan_knowledge_refs.py) |
| RBAC verifier (caller + per-agent SP) | [scripts/verify-source-rbac.sh](scripts/verify-source-rbac.sh) |
| Network verifier (per declared source) | [scripts/verify-source-network.sh](scripts/verify-source-network.sh) |

## One-line truths

- **Foundry IQ is built on Azure AI Search agentic retrieval.** It is invoked as an MCP tool (`knowledge_base_retrieve`) via a `RemoteTool` project connection, not as a custom HTTP endpoint.
- **Most sources resolve to AI Search under the hood.** Foundry IQ orchestrates over an AI Search-backed knowledge base; file-search Standard uses customer AI Search; blob ingestion targets AI Search. The differentiator is *who manages the index*.
- **Fabric Data Agent + Fabric direct Delta are HARD-BLOCKED in network-isolated agents** — Fabric workspace-level private link is unsupported. Only public-class agents can use them.
- **Key-based auth on AI Search is broken with private VNet.** Switch to ProjectMI + RBAC before going private.
- **Permission-aware retrieval requires the `x-ms-query-source-authorization` header**, set per request — Foundry Agent Service in *this* preview applies it agent-wide, not per-user. For per-user OBO use the Azure OpenAI Responses API directly.
- **Brownfield scan is regex.** It detects signals from `agent-framework`, LangGraph, `azure-search-documents`, `azure-cosmos`, `BlobServiceClient`, Fabric URLs. **It always asks the user to confirm** — never silently classifies.

## Schema in `agent-capabilities.yaml`

Per-source declaration:

```yaml
knowledge:
  sources:
    - name: hr-policies
      kind: foundry_iq                  # see catalog above
      knowledge_base_name: hr-policy-kb
      search_resource_id: /subscriptions/.../Microsoft.Search/searchServices/kb-prod
      project_connection_name: kb-mcp-prod   # the RemoteTool connection
      acl_passthrough: true                  # use x-ms-query-source-authorization

    - name: kb-direct
      kind: ai_search_direct
      resource_id: /subscriptions/.../Microsoft.Search/searchServices/kb-prod
      index_name: docs-v2
      auth: managed_identity              # managed_identity | api_key (deprecated)

    - name: uploaded-files
      kind: file_search_standard
      search_resource_id: /subscriptions/.../Microsoft.Search/searchServices/agent-search
      storage_resource_id: /subscriptions/.../Microsoft.Storage/storageAccounts/agentdocs

    - name: raw-pdfs
      kind: blob_via_indexer
      storage_resource_id: /subscriptions/.../Microsoft.Storage/storageAccounts/raw
      container: pdfs
      search_resource_id: /subscriptions/.../Microsoft.Search/searchServices/kb-prod
      index_name: pdfs-v1
      ingest_acls: true                    # rbacScope ingestion (preview)
```

Each source declares the **roles it needs** (caller for setup, per-agent SP for runtime), and the **network class** it's compatible with. The verify scripts read the manifest and check both.

## How prompts dispatch on this manifest

| Prompt | What it reads | What it does |
|---|---|---|
| `/plan-agent` | (writes) — interviews user OR runs scan to seed `knowledge.sources[]` | Picks `kind` per source from the [decision-tree.md](decision-tree.md) |
| `/prepare-deploy` | All sources | Phase A per source: caller RBAC + source existence + network reachability + cross-checks (e.g. `foundry-iq` requires the search service to support agentic retrieval; Fabric kinds incompatible with `network.class != public`) |
| `/configure-rbac` | All sources | Phase B per source: ProjectMI / per-agent SP grants on Search service, Storage account, etc. |
| `/verify-agent` | All sources | Phase C per source: smoke retrieval; validate citations; OTel `gen_ai.tool.name` includes the expected MCP tool / connection name |
| `/setup-evals` | `knowledge.sources[]` | Adds `groundedness` evaluator if any source is declared (already wired — was previously dangling) |

## Cross-skill references

- Caller-side roles per action → [foundry-roles/role-matrix.md](../foundry-roles/role-matrix.md)
- RBAC matrix for the per-agent SP → [foundry-identity/rbac-matrix.md](../foundry-identity/rbac-matrix.md)
- Network detection scripts wrapped per source → [foundry-prod-readiness/scripts/network/](../foundry-prod-readiness/scripts/network/)
- Capability manifest schema → [foundry-deploy/capabilities-manifest.md](../foundry-deploy/capabilities-manifest.md)
- Evaluator catalog (groundedness selection) → [foundry-evals/evaluator-catalog.md](../foundry-evals/evaluator-catalog.md)
- Fabric-specific paths (separate skill) → [foundry-fabric](../foundry-fabric/SKILL.md)

## Maintenance note

The Foundry IQ + AI Search agentic retrieval surface is moving from preview → GA in waves; some sub-features (RBAC scope ingestion, SharePoint remote, OBO header passthrough) remain preview as of 2026-05-14. The daily docs-scan job tracked under TD-9-style follow-ups updates per-kind status here when those flip.
