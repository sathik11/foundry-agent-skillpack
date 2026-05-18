# Direct Azure AI Search Index

A single AI Search index attached to the agent via the AI Search Tool — no Foundry IQ orchestration layer.

> Source of truth: [AI Search tool for agents](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/ai-search), [Enable RBAC in Azure AI Search](https://learn.microsoft.com/azure/search/search-security-enable-roles). Validity 2026-05-14.

## When to pick this over `foundry_iq`

See [decision-tree.md](decision-tree.md). Short version: pick when one curated index already exists, you want precise control over query syntax (semantic ranker, vector profiles), and you don't need cross-source orchestration.

## Schema declaration

```yaml
knowledge:
  sources:
    - name: kb-direct
      kind: ai_search_direct
      resource_id: /subscriptions/.../Microsoft.Search/searchServices/kb-prod
      index_name: docs-v2
      auth: managed_identity         # managed_identity | api_key (deprecated)
      semantic_config: default       # optional, recommended for relevance
      query_rewrite: false           # optional, semantic-ranker premium feature
```

## Required RBAC

| Identity | Role | Scope | When |
|---|---|---|---|
| **Caller** (one-time) | `Owner` or `User Access Administrator` | Search service | To grant the next two |
| **Caller** (one-time) | `Search Service Contributor` | Search service | To create / verify indexes |
| **Project MI** (runtime, read) | `Search Index Data Reader` | Search service or specific index | Required |
| **Project MI** (runtime, write) | `Search Index Data Contributor` | Search service or index | Only if agent ingests/updates |

## Setup flow

1. **Enable RBAC on the search service** if not already (`Settings → Keys → Role-based access control`). Required before any RBAC-based connection works.
2. **Create the project connection** via Foundry portal or `azure-ai-projects` SDK. Connection points at the search endpoint, auth = managed identity.
3. **Add the AI Search tool** to the agent. For hosted agents:
   ```yaml
   tools:
     - type: ai_search
       index_name: docs-v2
       project_connection_id: kb-direct-prod
   ```

## Network compatibility

✅ Supported. Recommended pattern with private VNet:
- Switch to managed-identity auth (key auth is **broken** with private VNet).
- Add a private endpoint on the search service.
- Link the `privatelink.search.windows.net` private DNS zone to the agent's VNet.

## Phase A — preflight

1. **Search service exists** + RBAC enabled (`disableLocalAuth` should be considered).
2. **Index exists** in the service with `index_name`. Case-sensitive — common typo.
3. **Semantic ranker available** if `semantic_config` is declared (S1+ tier).
4. **Caller RBAC** — `Search Service Contributor` to verify; `Owner` / `UAA` if Phase B grants are needed.
5. **Network class compatibility** — public ✅; managed VNet / BYO VNet ✅ with PE + DNS link; key-auth on private VNet **HARD BLOCK**.

## Phase B — post-deploy grants

```bash
az role assignment create \
  --assignee-object-id <PROJECT_MI_OID> --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Reader" \
  --scope <SEARCH_SERVICE_RESOURCE_ID>
```

5–15 min propagation.

## Phase C — verify

1. **Smoke retrieve** — invoke the agent with a query that hits the index.
2. **OTel** — KQL:
   ```kql
   dependencies
   | where cloud_RoleName == "<agent_name>"
   | where name startswith "execute_tool"
   | where customDimensions["gen_ai.tool.name"] has "search"
   | project timestamp, name, success, duration
   | order by timestamp desc | take 5
   ```
3. **Citation rendering** — confirm response includes a `url_citation` annotation (or equivalent for the SDK in use).

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| 401 / 403 | Missing `Search Index Data Reader` on Project MI | Phase B grant + propagation |
| `index not found` | Case-sensitive name mismatch | Verify exact index name |
| `index not found` | Connection points to wrong search service | Verify `resource_id` in connection |
| `Unable to connect to Azure AI Search Resource. ... DNS server returned answer with no data` | Key auth + private VNet | Switch to managed identity |
| Empty results | Index has no documents, OR query doesn't match | Test query in Search Explorer |
| Slow performance | Index not optimized; no semantic ranker | Enable semantic ranker; review schema |
| No citations in streaming | Stream processing logic doesn't capture annotations | Re-check sample code for `url_citation` capture |

## Vs `foundry_iq` — when to migrate

If you find yourself adding a second `ai_search_direct` source to the same agent, consider migrating to `foundry_iq`:
- One KB → many sources (less per-agent wiring).
- Managed query planning (your prompt no longer routes between sources).
- Permission-aware retrieval out of the box.
