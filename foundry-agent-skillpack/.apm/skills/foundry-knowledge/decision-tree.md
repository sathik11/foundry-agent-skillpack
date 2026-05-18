# Decision Tree — Which Knowledge Source Should This Agent Use?

> Validity date: 2026-05-14. The tree assumes refreshed-preview Foundry hosted agents and current Azure AI Search agentic retrieval features. Re-check against [What is Foundry IQ?](https://learn.microsoft.com/azure/foundry/agents/concepts/what-is-foundry-iq) when re-running.

There is no 80% case. The tree is meant to surface the *failure modes of choosing wrong* — not to push you toward one option.

```
START → Q1: Does the agent need to span multiple data sources
            (e.g. SharePoint + Blob + an existing AI Search index)?
            ──────────────────────────────────────────────────────
                                YES                NO
                                 │                  │
                                 ▼                  ▼
                          foundry_iq          Q2: Is the data already in
                          (one KB,                a search index OR purely
                          many sources,           file-based?
                          MCP tool)               ──────────────────
                                                  Search   Files
                                                  index    only
                                                   │         │
                                                   ▼         ▼
                                          ai_search_direct  Q3: Are files small
                                          (single index,    & uploaded directly
                                          AI Search Tool)   (≤ 512MB total)?
                                                            ──────────────
                                                            YES      NO
                                                             │        │
                                                             ▼        ▼
                                                  file_search_*  blob_via_indexer
                                                  (basic/standard) (canonical RAG)
```

## When to pick each

### `foundry_iq`
**Pick when:** multi-source coverage; need permission-aware retrieval (SharePoint with ACLs, ADLS with RBAC); want managed query planning + iterative search.
**Avoid when:** single-source agent with simple needs (overhead of KB + connection + MCP tool isn't justified).
**Trade-offs:** highest setup cost (KB + sources + connection + agent-side MCP tool). Higher per-query cost (agentic retrieval LLM planning). Best ergonomics at scale.

### `ai_search_direct`
**Pick when:** one curated index already exists; you need precise control over query syntax (semantic ranker, vector profiles, scoring profiles); cost-sensitive.
**Avoid when:** users will ask cross-source questions; or when you'd otherwise need to spin up multiple of these and orchestrate yourself.
**Trade-offs:** no automatic query planning — your agent's prompt/code does the rewriting. Lowest per-query cost. **Key-based auth is a trap with private VNet.**

### `file_search_basic`
**Pick when:** quick prototype; uploaded files only; don't want to manage Search/Storage; non-prod or sandbox tenant.
**Avoid when:** files contain sensitive data subject to data-residency policy (Microsoft-managed storage); or you need durable infra you control.
**Trade-offs:** zero infra work; bound by 512MB total + MSFT-managed storage location.

### `file_search_standard`
**Pick when:** prod; uploaded files only; want files in your own Storage + indexed in your own Search service; same code path as Basic.
**Avoid when:** you need cross-source coverage (use Foundry IQ instead).
**Trade-offs:** you own Search + Storage costs. Same chunking defaults as Basic (800 tok / 400 overlap, text-embedding-3-large 256d, 20 chunks max).

### `blob_via_indexer`
**Pick when:** raw documents in Blob Storage that you want continuously indexed; need ACL ingestion (`rbacScope`) for permission-aware retrieval; need scheduled refresh.
**Avoid when:** files are uploaded by users mid-conversation (use file-search Standard); or you only want one snapshot (use direct upload).
**Trade-offs:** indexer scheduling + cost; ACL ingestion is preview; ADLS Gen2 also supports ACLs (per-file, not per-container).

### `fabric_data_agent` (cross-link)
**Pick when:** existing Fabric Data Agent over a Lakehouse; NL2SQL is acceptable.
**Avoid when:** **agent must run in a network-isolated Foundry account** — Fabric workspace-level private link is unsupported; this is a hard block.
**Trade-offs:** non-deterministic NL2SQL; ~15–20s cold latency. See [foundry-fabric](../foundry-fabric/SKILL.md) Path A.

### `fabric_direct_delta` (cross-link)
**Pick when:** deterministic queries against a Lakehouse Delta table; per-agent SP can be granted Fabric workspace Member.
**Avoid when:** same network-isolation constraint as `fabric_data_agent`; or when payload sizes exceed middleware limits.
**Trade-offs:** ~80s cold start, 5s warm. See [foundry-fabric](../foundry-fabric/SKILL.md) Path B.

### `sharepoint_via_iq`
**Pick when:** SharePoint Online content needs query-time ACL enforcement; users have varying access.
**Avoid when:** all users have the same SharePoint access (use a regular Foundry IQ source); or when per-user OBO is required (this preview applies the header agent-wide; for per-user use the Azure OpenAI Responses API).
**Trade-offs:** preview surface; OBO header is per-connection, not per-request, in Foundry Agent Service today.

## Anti-patterns to avoid

- ❌ **Hard-coding a Search service URL in `main.py` instead of using a Foundry connection.** Bypasses identity model; nothing the skillpack can verify.
- ❌ **Choosing `fabric_*` for a network-isolated agent.** Will silently fail at runtime; pre-flight catches this and STOPs.
- ❌ **Mixing `foundry_iq` and `ai_search_direct` over the same index.** Redundant cost; pick one.
- ❌ **Using API keys for AI Search "to get started"** then planning to migrate to RBAC later. The migration is friction; start RBAC.
- ❌ **Splitting one logical corpus across multiple `ai_search_direct` sources** to avoid setting up a knowledge base. Foundry IQ exists for exactly this.

## What the skillpack verifies vs. what stays your responsibility

| Concern | Skillpack verifies | Your job |
|---|---|---|
| Source resource exists in your sub | ✅ | — |
| Caller has Reader on the resource | ✅ (preflight) | — |
| Per-agent SP has correct data-plane role | ✅ (Phase B) | — |
| Network class supports this kind | ✅ | — |
| Index/KB schema matches what the agent expects | ❌ | You |
| Citations field present in the index for `url` / `sourceUrl` etc. | ❌ | You |
| Embeddings model deployment + capacity | ❌ | You |
| Indexer schedule + change tracking | ❌ | You |
