# File Search Tool — Basic & Standard agent setup

Built-in tool for agents that need to search uploaded files. Same code path; different storage backing.

> Source of truth: [File search tool for agents](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/file-search). Validity 2026-05-14.

## Two flavors — pick by where files live

| Flavor | Files in | Vector store in | When |
|---|---|---|---|
| **`file_search_basic`** | Microsoft-managed Storage | Microsoft-managed Search | Quick start; sandbox; non-residency-sensitive |
| **`file_search_standard`** | Your connected Storage account | Your connected AI Search service | Prod; data residency; want infra you own |

The agent code is **identical** for both. The difference is who owns the storage + search.

## Schema declaration

```yaml
knowledge:
  sources:
    # Basic
    - name: drafts
      kind: file_search_basic

    # Standard
    - name: contracts
      kind: file_search_standard
      search_resource_id:  /subscriptions/.../Microsoft.Search/searchServices/agent-search
      storage_resource_id: /subscriptions/.../Microsoft.Storage/storageAccounts/agentdocs
```

## Built-in pipeline (both flavors)

The service handles ingestion end-to-end:
1. Parse + chunk documents.
2. Generate + store embeddings.
3. At query time: rewrite → decompose → hybrid search → rerank.

## Default chunking + retrieval (both flavors, not configurable today)

| Setting | Value |
|---|---|
| Chunk size | 800 tokens |
| Chunk overlap | 400 tokens |
| Embedding model | `text-embedding-3-large` (256 dimensions) |
| Max chunks in context | 20 |
| File size limit | 512MB total per agent |

If those don't suit your use case (larger files, custom chunking, custom embeddings), use `blob_via_indexer` or `ai_search_direct` instead.

## When to choose this over `blob_via_indexer`

- ✅ Files are uploaded by users mid-conversation
- ✅ You want zero infrastructure setup
- ✅ Defaults are fine
- ❌ You need scheduled re-indexing of a continuously-changing source → use `blob_via_indexer`
- ❌ You need ACL ingestion (`rbacScope`) → use `blob_via_indexer`
- ❌ You need a non-default chunker / embedder → use `blob_via_indexer` or `ai_search_direct`

## Required RBAC

| Identity | Role | Scope | When |
|---|---|---|---|
| **Caller** (`basic`) | `Azure AI User` on project | one-time | — |
| **Caller** (`standard`) | `Owner` / `UAA` | Search + Storage | one-time, to grant Phase B |
| **Project MI** (`standard`) | `Search Index Data Contributor` | Search service | runtime |
| **Project MI** (`standard`) | `Storage Blob Data Contributor` | Storage account | runtime |

`basic` requires no infra grants — Microsoft owns the resources.

## Setup flow

### Basic
1. Enable the tool in the agent definition; no infra steps.

### Standard
1. Create the AI Search + Blob Storage resources (any tier supporting the agent's region).
2. Connect them in the Foundry project (Connections → Add → AI Search / Storage).
3. Enable the tool in the agent definition; reference the connections.

## Network compatibility

Both flavors ✅ supported in network-isolated agents. For Standard, ensure private endpoints + DNS links on the connected AI Search and Storage if those services have `publicNetworkAccess: Disabled`.

## Phase A — preflight

For `file_search_standard`:
1. Search + Storage resources exist.
2. Both connected to the Foundry project (Connections list).
3. Caller has Owner/UAA on each (for Phase B).
4. Network: `privatelink.search.windows.net` and `privatelink.blob.core.windows.net` zones linked to agent VNet if private.

For `file_search_basic`:
1. None — Microsoft-managed.

## Phase B — post-deploy grants (Standard only)

```bash
# Project MI -> Search
az role assignment create \
  --assignee-object-id <PROJECT_MI_OID> --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Contributor" \
  --scope <SEARCH_SERVICE_RESOURCE_ID>

# Project MI -> Storage
az role assignment create \
  --assignee-object-id <PROJECT_MI_OID> --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope <STORAGE_ACCOUNT_RESOURCE_ID>
```

## Phase C — verify

1. **Upload a test file** + query it. Check the response cites the file by name.
2. **OTel** — confirm `execute_tool` span with `gen_ai.tool.name == "file_search"`.
3. **Vector store + file** — confirm in the agent's Files panel that the file shows status `processed`.

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Upload fails (Standard) | Project MI lacks Storage Blob Data Contributor | Phase B grant |
| Search fails (Standard) | Project MI lacks Search Index Data Contributor | Phase B grant |
| File limit exceeded | Cumulative > 512MB | Switch to `blob_via_indexer` |
| Wrong / no results | Default chunker dropped relevant content | Reduce file size; or move to `blob_via_indexer` with custom chunker |
| Citation missing in stream | Stream processing logic | Capture file annotations in stream events |
