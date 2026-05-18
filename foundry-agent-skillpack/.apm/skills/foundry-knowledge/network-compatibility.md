# Network-Class Compatibility Matrix

Per knowledge-source `kind`, what network classes can the agent run in? Used by `/prepare-deploy` to fail-fast on incompatible declarations.

> Validity 2026-05-14. Cross-reference: [foundry-prod-readiness/networking.md](../foundry-prod-readiness/networking.md). When a `kind` flips status, update both.

## The matrix

| `kind` | `public` | `managed_vnet` (allow_internet) | `managed_vnet` (allow_only_approved) | `byo_vnet` |
|---|---|---|---|---|
| `foundry_iq` | ✅ | ✅ | ✅ (KB MCP via PE; AI Search PE) | ✅ |
| `ai_search_direct` | ✅ (key or MI) | ✅ (MI only) | ✅ (MI + PE) | ✅ (MI + PE) |
| `file_search_basic` | ✅ | ✅ | ⚠️ (MSFT-managed; verify FQDN allowlist) | ⚠️ (same) |
| `file_search_standard` | ✅ | ✅ | ✅ (MI + PE on Search + Storage) | ✅ |
| `blob_via_indexer` | ✅ | ✅ | ✅ (MI + PE on Search + Storage) | ✅ |
| `fabric_data_agent` | ✅ | ❌ | ❌ | ❌ |
| `fabric_direct_delta` | ✅ | ❌ | ❌ | ❌ |
| `sharepoint_via_iq` | ✅ | ✅ (public endpoint) | ⚠️ (verify SharePoint FQDN allowlisted) | ⚠️ (same) |

## Reading the matrix

- ✅ — Supported. Configuration may have prerequisites (PE, DNS link, RBAC). Linked sub-doc lists them.
- ⚠️ — Supported but uses public endpoint. Won't satisfy "all-private" compliance mandates. Verify your firewall allowlist.
- ❌ — **Hard block.** `/prepare-deploy` STOPs and asks you to either change the agent's `network.class` or remove the source.

## Why Fabric is a hard block today

Fabric workspace-level private link is unsupported for hosted agents. Both `fabric_data_agent` and `fabric_direct_delta` route through the Fabric workspace which must remain on a public endpoint. If your Foundry account is on managed or BYO VNet, the agent's egress can't satisfy this — runtime calls will hang or 503.

Mitigations (in order of preference):
1. Move Fabric content to AI Search via `blob_via_indexer` (e.g., export Lakehouse tables to Parquet in Blob, index there).
2. Run a separate public-class Foundry account just for the Fabric-touching agent; orchestrate from a VNet-isolated agent via A2A.
3. Wait for Fabric workspace-level private link → hosted agent support (no ETA).

## Preflight script

[scripts/verify-source-network.sh](scripts/verify-source-network.sh) reads each declared `knowledge.sources[]` and the `network.class`, runs the four detection scripts under `foundry-prod-readiness/scripts/network/`, and aggregates a verdict per source. It does NOT mutate state.

## Outbound mode caveats

When Foundry is on `managed_vnet` with `outbound_mode: allow_only_approved`:
- Foundry IQ KB MCP traffic is fine via managed PE on AI Search (no firewall change).
- Direct AI Search via PE: same.
- File search Basic / SharePoint: traverses public endpoints — FQDN allowlist additions required.
- Blob via indexer: ingestion is between Search service and Storage; both must be PE'd or service-tag-allowed. Query-time (Project MI → Search) is internal.

## What this matrix doesn't cover

- **Index-time RBAC scope ingestion** for ACLs — preview, may add network constraints.
- **Cross-tenant Foundry IQ sources** — out of scope; treat as ❌.
- **Custom MCP servers** behind APIM — covered in `foundry-deploy/external-mcp.md`, not here.

## Cross-skill references

- The four network detection scripts → [foundry-prod-readiness/scripts/network/](../foundry-prod-readiness/scripts/network/)
- ACR public-access caveat for *any* hosted agent → [foundry-prod-readiness/networking.md](../foundry-prod-readiness/networking.md)
- Fabric paths in detail → [foundry-fabric](../foundry-fabric/SKILL.md)
