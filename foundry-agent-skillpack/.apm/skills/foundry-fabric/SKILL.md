---
name: foundry-fabric
description: Fabric Data Agent, Toolbox MCP, WorkIQ Teams/GitHub integration, and hybrid fallback patterns for Foundry agents
---

# Foundry Fabric & WorkIQ

> Cross-link: Fabric paths are also valid `knowledge.sources[].kind` values (`fabric_data_agent`, `fabric_direct_delta`). See [foundry-knowledge/decision-tree.md](../foundry-knowledge/decision-tree.md) for the full source taxonomy. Both fabric kinds are **HARD BLOCKED in network-isolated agents** — see [foundry-knowledge/network-compatibility.md](../foundry-knowledge/network-compatibility.md).

## Three Data Paths

| Path | Identity | Latency | Determinism |
|------|----------|---------|-------------|
| A — Toolbox → Fabric Data Agent (NL2SQL) | Project MI | ~15-20s | Non-deterministic |
| B — Direct Delta read (`deltalake` lib) | Per-agent identity | ~80s cold, ~5s warm | Fully deterministic |
| C — Local JSON (`data/` folder) | None | <1ms | Full |

## Path A — NL2SQL via Toolbox

- Copy MCP endpoint URL from agent Settings → MCP tab (don't hard-code)
- Wrap MCP calls in `@tool` functions with clean names (dots in MCP names → HTTP 400)
- Soft error detection: HTTP 200 with prose "unable to retrieve" — string-match required
- Row limit: 200 rows (not 25 as documented — 25 is the chat UI limit)
- **Non-deterministic**: same query → different results across runs. Never rely as sole path.

## Path B — Direct Delta Read

```python
dt = DeltaTable(table_uri, storage_options={"bearer_token": token, "use_fabric_endpoint": "true"})
```

RBAC: Per-agent identity needs Fabric workspace Member (NOT Azure Storage Blob Data Reader — OneLake has its own security model).

## Hybrid Fallback (Recommended)

```python
def get_feedback(query, filters):
    # 1. Try NL2SQL (fast when it works)
    # 2. Fall back to direct Delta (deterministic)
    # 3. Last resort: local JSON (dev only)
```

## WorkIQ Teams MCP (Prompt Agent)

```yaml
tools:
  - type: mcp
    server_label: WorkIQTeams
    project_connection_id: WorkIQTeams2
    require_approval: always
```

MCP scope: `McpServers.Teams.All` (separate from Graph delegated permissions like `ChannelMessage.Send`).

## WorkIQ GitHub MCP (Prompt Agent)

```yaml
tools:
  - type: mcp
    server_label: GitHubProjects
    server_url: https://api.githubcopilot.com/mcp/
    require_approval: always
```

## Preflight (Phase A, called by `/prepare-deploy`)

Run when `capabilities.fabric.enabled: true`. STOP on any ❌.

1. **Workspace exists** — `GET https://api.fabric.microsoft.com/v1/workspaces/{workspace_id}` (Fabric token). 404 = bad ID; 403 = caller lacks Fabric access (separate from agent identity — user must fix this themselves).
2. **Items exist** — for each name in `fabric.items`, `GET /v1/workspaces/{id}/items` and match by `displayName`. Missing items = STOP.
3. **Toolbox connection** (if `access_path: toolbox` or `hybrid`) — list Foundry connections; require one of `connection_type: FabricToolbox` (or whatever the project uses). Capture `connection_id`.
4. **Direct Delta path** (if `access_path: direct_delta` or `hybrid`) — confirm the lakehouse SQL endpoint URL is set in agent env vars; warn if missing.
5. **Record — do not execute —** the Fabric workspace role assignment. The per-agent identity does not exist yet (created by `azd up`).

## Post-deploy (Phase B, called by `/configure-rbac`)

Once `azd ai agent show` reports `instance_identity.principal_id`:

```
# Print these steps verbatim to the user (TD-1: API call is print-only).
Fabric portal → Workspaces → <workspace_name> → Manage access → Add people or groups
  → paste principal_id <PRINCIPAL_ID>
  → role: <role from manifest>
```

OR via Fabric REST (requires Fabric-aud token — see TECHNICAL_DEBT.md TD-1):
```bash
TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
curl -X POST "https://api.fabric.microsoft.com/v1/workspaces/<workspace_id>/roleAssignments" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"principal":{"id":"<PRINCIPAL_ID>","type":"ServicePrincipal"},"role":"<role>"}'
```

Propagation: 5–10 minutes.

## Verify (Phase C, called by `/verify-agent`)

```kql
// Fabric tool calls succeeded
dependencies
| where cloud_RoleName == "<agent_name>"
| where name startswith "execute_tool" and tostring(customDimensions.["gen_ai.tool.name"]) has "fabric"
| summarize successes=countif(success == true), failures=countif(success == false)
```

Failure modes:
- All 403 → workspace role assignment didn't propagate or wasn't applied to `instance_identity.principal_id` (using `blueprint.principal_id` is wrong — see foundry-identity).
- Empty result + agent invoked → agent never called the Fabric tool; check tool wiring in `main.py` or `agent-definition.yaml`.
