# Blob via AI Search Indexer

The canonical RAG pattern: raw documents in Azure Blob Storage continuously indexed into AI Search by an indexer. Used either standalone (then queried via `ai_search_direct`) or as a knowledge source under Foundry IQ.

> Source of truth: [Index data from Azure Blob Storage](https://learn.microsoft.com/azure/search/search-how-to-index-azure-blob-storage), [Use a blob indexer or knowledge source to ingest RBAC scopes metadata](https://learn.microsoft.com/azure/search/search-blob-indexer-role-based-access). Validity 2026-05-14.

## When to pick this

- Raw documents that change continuously (need scheduled refresh).
- Need ACL ingestion (`rbacScope`) for permission-aware retrieval (preview).
- Custom chunking, custom embedding, custom field mappings.
- Anti-pattern: choosing this for files uploaded mid-conversation — use [file-search-tool.md](file-search-tool.md) instead.

## Schema declaration

```yaml
knowledge:
  sources:
    - name: raw-pdfs
      kind: blob_via_indexer
      storage_resource_id: /subscriptions/.../Microsoft.Storage/storageAccounts/raw
      container: pdfs
      search_resource_id: /subscriptions/.../Microsoft.Search/searchServices/kb-prod
      index_name: pdfs-v1
      indexer_name: pdfs-indexer-v1
      data_source_name: blob-raw-pdfs
      schedule: "PT1H"            # ISO 8601 duration; null = on-demand only
      ingest_acls: true           # rbacScope ingestion (preview)
      change_tracking: true       # required for delete tracking
```

## Pipeline shape

```
Blob Storage container
        │
        ▼
   AI Search Indexer  ──── reads metadata + content; cracks docs
        │                  (PDF, Office, JSON, CSV, EML, EPUB, GZ, HTML, KML, MD)
        ▼
   AI Search Index    ──── searchable; permission metadata if ingest_acls=true
        │
        ▼
   Agent (via ai_search_direct or foundry_iq)
```

## Required RBAC

For ingestion (one-time + scheduled):

| Identity | Role | Scope |
|---|---|---|
| **Caller** | `Owner` / `UAA` | Storage + Search (Phase B grants) |
| **Caller** | `Search Service Contributor` | Search service |
| **AI Search MI** | `Storage Blob Data Reader` | Storage account |
| **AI Search MI** | `Storage Blob Delegator` | Storage account (only for ADLS Gen2) |

For query-time (runtime):

| Identity | Role | Scope |
|---|---|---|
| **Project MI** | `Search Index Data Reader` | Search service or specific index |
| **End user** (when `ingest_acls`) | identity passed via `x-ms-query-source-authorization` | per-request |

> AI Search must have a system-assigned MI enabled on the service (`identity.type: SystemAssigned`).

## Setup flow

1. **Enable system-assigned MI on the search service** (one-time).
2. **Grant the search MI** Storage Blob Data Reader (+ Delegator for ADLS Gen2).
3. **Create the data source** pointing at the container.
4. **Create the index** with the desired schema (include a citation-friendly field like `url`, `sourceUrl`, `filePath`, `path`, or `folderPath`).
5. **Create the indexer** referencing data source + index, with schedule + change tracking.
6. **(Optional) Configure `ingestionPermissionOptions: rbacScope`** on the data source for ACL ingestion.
7. **Wire the agent** to query the resulting index — declare `ai_search_direct` (single index) OR add it to a `foundry_iq` knowledge base.

## ACL / RBAC ingestion (preview)

Two paths today:

- **Container-level RBAC scope ingestion** (Blob, ADLS Gen2): `ingestionPermissionOptions: rbacScope` — captures who has `Storage Blob Data Reader` on the container; matches at query time.
- **Per-file ACLs** (ADLS Gen2 only): captures POSIX-style ACLs on directories/files.

Both require:
- Caller passes `x-ms-query-source-authorization` with the **end user's** identity at query time.
- The agent context needs to surface the end user's token (preview limit in Foundry Agent Service: header is per-connection, not per-request — see [foundry-iq.md](foundry-iq.md) note).

## Network compatibility

✅ Supported in network-isolated agents.
- Storage account can be PE'd (public access Disabled is fine for ingestion if Search service has `Allow trusted Microsoft services` enabled, OR uses PE + private DNS link).
- Search service can be PE'd; agent VNet must have `privatelink.search.windows.net` zone linked.
- DNS misresolution is the #1 silent failure here — see [foundry-prod-readiness/networking.md](../foundry-prod-readiness/networking.md).

## Phase A — preflight

1. Storage account + container exist + reachable.
2. Search service exists with RBAC enabled + system-assigned MI on.
3. Caller has `Owner`/`UAA` on Search and Storage (for Phase B).
4. Citation field declared in the index schema (warn if missing — citations won't render).
5. Network: PE/DNS checks per [foundry-prod-readiness/scripts/network/](../foundry-prod-readiness/scripts/network/).

## Phase B — post-deploy grants

```bash
# Search MI -> Storage (ingestion)
SEARCH_MI=$(az search service show --name <search> -g <rg> --query identity.principalId -o tsv)
az role assignment create \
  --assignee-object-id "$SEARCH_MI" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope <STORAGE_ACCOUNT_RESOURCE_ID>

# Project MI -> Search (query)
az role assignment create \
  --assignee-object-id <PROJECT_MI_OID> --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Reader" \
  --scope <SEARCH_SERVICE_RESOURCE_ID>
```

## Phase C — verify

1. **Indexer last-run status** — REST: `GET {search}/indexers/{name}/status?api-version=2024-07-01`. Look for `lastResult.status == "success"`.
2. **Document count** — `GET {search}/indexes/{name}/docs/$count?api-version=2024-07-01`. Should match expected blob count (modulo skipped files).
3. **Smoke query** — agent invocation with a topic only this index covers; verify response is grounded + cites a blob URL.

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Indexer fails: `Authorization` | Search MI lacks Storage Blob Data Reader | Phase B grant |
| Indexer succeeds but doc count = 0 | Wrong container / blob filter | Check `query` parameter on data source |
| Indexer skips files | Unsupported content type / corrupt | Check `lastResult.errors` |
| Deleted blobs still in index | Change tracking + delete tracking not enabled | Enable both before first run (can't backfill) |
| ACL'd query returns content user shouldn't see | `ingest_acls: false`, OR header not passed | Re-index with `rbacScope`; pass `x-ms-query-source-authorization` |
| Indexer schedule didn't fire | Search SKU below the schedule frequency limit | Upgrade SKU or increase schedule interval |
