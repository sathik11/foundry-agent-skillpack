# External MCP Server as a Tool

Attach any MCP server (Microsoft Learn MCP, ACA-hosted MCP, GitHub MCP) as an agent tool.

## Hosted agent (Track A/B)

```python
mcp_tool = client.get_mcp_tool(
    name="ms-learn",
    url="https://learn.microsoft.com/api/mcp",
    approval_mode="never_require",
)
agent = Agent(client=client, tools=[my_tool, mcp_tool], ...)
```

### Authenticated MCP

```python
mcp_tool = client.get_mcp_tool(
    name="github",
    url="https://api.githubcopilot.com/mcp/",
    headers={"Authorization": f"Bearer {token}"},
    approval_mode="never_require",
)
```

### Project-connection-bound MCP (preferred for prod)

```python
mcp_tool = client.get_mcp_tool(
    name="fabric-toolbox",
    project_connection_id="<connection-resource-id>",
    approval_mode="never_require",
)
```

The connection's bound service principal handles auth — no header juggling.

## Prompt agent (Track C)

```yaml
# agent-definition.yaml
kind: prompt
tools:
  - type: mcp
    server_label: ms-learn
    server_url: https://learn.microsoft.com/api/mcp
    require_approval: never
```

## URL gotchas

- **Must be fully-resolved `http(s)://`.** Empty `${ENV_VAR}` → `invalid_payload` at runtime.
- **No trailing slash on `/mcp`.** Some servers 404 on `/mcp/`.
- **Private endpoints:** if MCP is on a VNet-isolated ACA, use `project_connection_id` (no DNS hassle).

## Verify (KQL)

```kql
dependencies
| where cloud_RoleName == "<agent_name>"
| where name == "execute_tool"
| extend label = tostring(customDimensions.["tool.server_label"])
| where label == "<your label>"
| summarize count() by success
```

Expect ≥1 success per server label after smoke test.

## See also

- [apim-as-mcp-frontdoor.md](apim-as-mcp-frontdoor.md) — front the MCP server with APIM AI Gateway (rate limits, OAuth credential manager, central audit, content-safety policy)
- [foundry-fabric/SKILL.md](../foundry-fabric/SKILL.md) — Toolbox MCP specifics
- [foundry-teams-workiq/SKILL.md](../foundry-teams-workiq/SKILL.md) — WorkIQ Teams MCP
- [foundry-knowledge/foundry-iq.md](../foundry-knowledge/foundry-iq.md) — Foundry IQ KB MCP tool
