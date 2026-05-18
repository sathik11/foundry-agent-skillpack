# Foundry IQ — Multi-source Knowledge Base via MCP

Foundry IQ is the managed knowledge layer. **One knowledge base, many sources, invoked as an MCP tool.**

> Source of truth: [What is Foundry IQ?](https://learn.microsoft.com/azure/foundry/agents/concepts/what-is-foundry-iq), [Connect a Foundry IQ knowledge base to Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/how-to/foundry-iq-connect). Validity 2026-05-14.

## The model

```
┌────────────────┐
│  Hosted agent  │  →  MCP tool (knowledge_base_retrieve)
└────────────────┘                 │
                                   ▼
                       ┌──────────────────────┐
                       │ Foundry IQ knowledge │
                       │       base           │
                       │  (in AI Search svc)  │
                       └──────────────────────┘
                          │      │     │     │
                          ▼      ▼     ▼     ▼
                       Blob   ADLS  SharePoint  Web
                              Gen2   (remote)
```

## What the agent sees

A single MCP tool: `knowledge_base_retrieve`. The platform handles query planning, source selection, parallel search, and result aggregation. Your agent code does **not** branch by source.

## Prerequisites

| Item | Value | Notes |
|---|---|---|
| AI Search service | Required, with agentic retrieval support | Free tier OK for POC |
| Knowledge base name | Created in AI Search | Use the AI Search portal or REST API |
| Project endpoint | `https://<acct>.services.ai.azure.com/api/projects/<proj>` | From Foundry portal |
| Project resource id | ARM id of the project | For connection creation |
| Project connection name | Your choice | The `RemoteTool` connection |
| Model deployment | e.g. `gpt-4.1-mini` | Used by the agent for reasoning over retrieved content |
| `azure-ai-projects` | `>=2.0.0` | Or REST `2025-11-01-preview` |

## Required RBAC

| Identity | Role | Scope |
|---|---|---|
| **Caller** (one-time setup) | `Azure AI User` | Foundry account |
| **Caller** (one-time setup) | `Azure AI Project Manager` | Foundry account (to create the connection) |
| **Project MI** (runtime) | `Search Index Data Reader` | AI Search service |
| **Project MI** (runtime, write) | `Search Index Data Contributor` | AI Search service (only if agent writes back) |
| **End user** (per-request, ACL'd sources) | `x-ms-query-source-authorization` token | passed at query time |

## Setup flow (programmatic, recommended)

1. **Create the knowledge base** in Azure AI Search ([How to create a knowledge base](https://learn.microsoft.com/azure/search/agentic-retrieval-how-to-create-knowledge-base)). One per logical corpus.
2. **Create the `RemoteTool` project connection** with `ProjectManagedIdentity` auth pointing at the KB's MCP endpoint.
3. **Add the MCP tool to the agent** — for hosted agents, declare it as a project-connection-bound MCP server in the manifest:
   ```yaml
   tools:
     - type: mcp
       server_label: hr_kb
       project_connection_id: kb-mcp-prod
       require_approval: never
   ```
4. **Tune the system prompt** to instruct when/how to call the KB and to require citations:
   ```
   Use the knowledge base tool to answer user questions.
   If the knowledge base doesn't contain the answer, respond with "I don't know".
   When you use information from the knowledge base, include citations.
   ```

## Permission-aware retrieval (ACLs, RBAC, sensitivity labels)

Foundry IQ honors:
- **ADLS Gen2 ACLs** (per-file)
- **Blob RBAC scopes** (preview, container-level — see [Use a blob indexer or knowledge source to ingest RBAC scopes](https://learn.microsoft.com/azure/search/search-blob-indexer-role-based-access))
- **SharePoint Online permissions** (remote source — content not indexed; permissions enforced at query time via Copilot Retrieval API)
- **Microsoft Purview sensitivity labels**

For ACL/RBAC enforcement at query time, pass the **end user's** identity in `x-ms-query-source-authorization`. **Important caveat in this preview:** Foundry Agent Service applies headers agent-wide, not per-user/per-request. For per-user OBO, use the Azure OpenAI Responses API directly until the per-request header lands.

## Network compatibility

✅ Supported in network-isolated Foundry agents (Foundry IQ is invoked via MCP, which routes through the agent's VNet subnet for private MCP, or Microsoft backbone for public MCP). The underlying AI Search service can be PE'd; ensure the right private DNS zone is linked to the agent's VNet (`privatelink.search.windows.net`).

See [network-compatibility.md](network-compatibility.md) for the full matrix.

## Phase A — preflight (called by `/prepare-deploy`)

Run when `knowledge.sources[].kind == foundry_iq`:

1. **AI Search service exists** + supports agentic retrieval (S1 SKU or higher; verify `properties.semanticSearch != "disabled"`).
2. **Knowledge base exists** in the search service (REST: `GET {search}/knowledgebases/{name}?api-version=2025-11-01-preview`).
3. **Project connection exists** (or — with user confirmation — create it via `RemoteTool` + `ProjectManagedIdentity`).
4. **Caller RBAC** (`Azure AI User` + `Azure AI Project Manager` on the Foundry account; `Search Service Contributor` on the search service to create KBs/sources).
5. **Network class compatibility** (always ✅ for `foundry_iq`).

If any ❌, STOP and emit runbook via [foundry-roles](../foundry-roles/scripts/runbook-emit.sh).

## Phase B — post-deploy grants (called by `/configure-rbac`)

The agent uses the **Project MI** to call the KB MCP endpoint, so the per-agent SP doesn't need direct AI Search access. The Project MI grant is one-time per project.

```bash
# Idempotent
az role assignment create \
  --assignee-object-id <PROJECT_MI_OID> --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Reader" \
  --scope <SEARCH_SERVICE_RESOURCE_ID>
```

If the agent **writes** to indexes (rare):

```bash
az role assignment create \
  --assignee-object-id <PROJECT_MI_OID> --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Contributor" \
  --scope <SEARCH_SERVICE_RESOURCE_ID>
```

## Phase C — verify (called by `/verify-agent`)

1. **Smoke retrieve** — invoke the agent with a question only the KB can answer; confirm the response contains a citation.
2. **OTel** — KQL:
   ```kql
   dependencies
   | where cloud_RoleName == "<agent_name>"
   | where name startswith "execute_tool"
   | where customDimensions["gen_ai.tool.name"] in ("knowledge_base_retrieve", "<server_label>")
   | take 5
   ```
3. **Citation field** — confirm response `text` includes a `url`, `sourceUrl`, `filePath`, `path`, or `folderPath` reference (case-sensitive). Citations only render in clients that look for these.

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| 403 from KB MCP | Project MI lacks `Search Index Data Reader` | Phase B grant + 5–15 min propagation |
| Empty results | KB has no synced sources, or filter dropped everything | Re-run KB indexing; check semantic ranker is enabled |
| No citations in response | Index field name not in {`url`, `sourceUrl`, `filePath`, `path`, `folderPath`} | Add a citation field to the index schema |
| ACL'd source returns content user shouldn't see | Header not passed; Foundry Agent Service preview limitation | Use Azure OpenAI Responses API for per-user OBO |
| `Workspace not found` when creating connection | Old `Microsoft.MachineLearningServices` API used | Use `az cognitiveservices account project connection create` |
| Slow first query (~10s+) | Agentic retrieval LLM planning + multi-source parallel search | Expected; subsequent queries on the same conversation are warmer |

## Cost notes

- AI Search S1 + agentic retrieval: see [Azure AI Search pricing](https://azure.microsoft.com/pricing/details/search/) — premium-tier indexes recommended for prod.
- Per-query LLM planning cost: depends on the model used by the KB (configured at KB creation).
- Storage: index size scales with vectorized chunk count.
