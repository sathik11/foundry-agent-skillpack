# APIM as MCP Front-Door

Front a remote MCP server with **Azure API Management's AI Gateway** so the agent talks to APIM, not the MCP server directly. APIM owns auth, rate limits, throttling, content-safety policy, observability, and OAuth credential injection.

> Validity 2026-05-14. Ground in: [AI gateway in Azure API Management](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities), [Secure access to MCP servers in API Management](https://learn.microsoft.com/azure/api-management/secure-mcp-servers), [Govern MCP tools by using an AI gateway (preview)](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/governance), [Bring your own AI gateway to Azure AI Agent Service (preview)](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway).

## When this pattern is the right call

- Multiple agents need to share an MCP server with **central rate limiting, throttling, or quotas**.
- The MCP server uses **OAuth** and you don't want each agent to manage tokens — APIM credential manager injects them.
- You need **content-safety policy** (`llm-content-safety`) at the gateway, not in agent code.
- You want a **single audit log** for all MCP traffic across agents (gateway logs + Application Insights).
- The MCP server is **on-prem or in a non-Azure tenant** — APIM is the trust boundary.
- Compliance requires that agents only call **approved MCP endpoints** — APIM enforces an allowlist.

## When this pattern is NOT worth it

- Single agent, one MCP server, no auth complexity → use direct MCP (see [external-mcp.md](external-mcp.md)).
- The MCP server is already a Foundry connection (`project_connection_id`) → connection-bound auth handles the same problems with less infrastructure.
- You're in a sandbox / POC stage → APIM adds setup cost that isn't justified yet.

## Two routing modes

| Mode | What it is | Status (2026-05-14) |
|---|---|---|
| **Foundry-managed AI gateway routing** | Connect APIM to a Foundry resource; new MCP tools created in the Foundry portal route through APIM automatically | **Preview**. Only NEW MCP tools that DON'T use managed OAuth. Existing tools aren't migrated. |
| **Manual front-door** | Author the agent's MCP tool URL to point at APIM; APIM forwards to the real MCP server | GA in API Management; works with any agent / any MCP tool today |

The "Foundry-managed" mode is the cleanest UX but is preview-restricted. The "manual front-door" mode is what you ship to prod today.

## Manual front-door — minimal recipe

Goal: agent calls `https://<apim>.azure-api.net/mcp/<server>/...` instead of the MCP server directly. APIM forwards, applies policies, and injects OAuth tokens.

### 1. Create the APIM API

```bash
# One MCP server = one APIM API. Path = /mcp/<server>
az apim api create \
  --resource-group <rg> --service-name <apim> \
  --api-id mcp-contoso \
  --display-name "Contoso MCP" \
  --path "mcp/contoso" \
  --service-url "https://contoso-mcp.example.com" \
  --protocols https
```

> APIM **MCP server endpoint** APIs (a newer feature, see [MCP server overview](https://learn.microsoft.com/azure/api-management/mcp-server-overview)) provide first-class MCP routing with the right defaults. Prefer this when available.

### 2. Apply the policies you actually need

Avoid policy sprawl. Start with the minimum:

```xml
<inbound>
  <base />

  <!-- 1. Validate the agent's caller (Foundry per-agent SP or ProjectMI) -->
  <validate-jwt header-name="Authorization" failed-validation-httpcode="401">
    <openid-config url="https://login.microsoftonline.com/<tenant>/v2.0/.well-known/openid-configuration" />
    <required-claims>
      <claim name="aud">
        <value>api://<your-apim-app-id></value>
      </claim>
    </required-claims>
  </validate-jwt>

  <!-- 2. Inject the upstream OAuth token via credential manager -->
  <get-authorization-context provider-id="contoso-oauth"
                             authorization-id="contoso-prod"
                             context-variable="auth-context"
                             identity-type="managed"
                             ignore-error="false" />
  <set-header name="Authorization" exists-action="override">
    <value>@("Bearer " + ((Authorization)context.Variables.GetValueOrDefault("auth-context"))?.AccessToken)</value>
  </set-header>

  <!-- 3. Rate limit per agent identity -->
  <rate-limit-by-key calls="60" renewal-period="60"
                     counter-key="@(context.Subscription?.Id ?? context.Request.IpAddress)" />

  <!-- 4. Correlation header for trace stitching with App Insights -->
  <set-header name="X-Correlation-Id" exists-action="override">
    <value>@(context.RequestId)</value>
  </set-header>
</inbound>

<outbound>
  <base />
  <!-- Strip upstream cookies before returning to agent -->
  <set-header name="Set-Cookie" exists-action="delete" />
</outbound>
```

**Anti-patterns:**
- ❌ Don't delete the `Authorization` header inbound (some MCP servers require it).
- ❌ Don't add `llm-content-safety` here unless you understand the latency cost on tool-call paths (it's designed for chat, not high-volume tool dispatch).
- ❌ Don't put per-tool rate limits in policy XML — manage as APIM products / subscriptions instead.

### 3. Wire the agent to APIM, not to the MCP server

Hosted agent (agent-framework):

```python
mcp_tool = client.get_mcp_tool(
    name="contoso",
    url="https://<apim>.azure-api.net/mcp/contoso",   # ← APIM, not contoso-mcp.example.com
    headers={
        "Ocp-Apim-Subscription-Key": os.environ["APIM_SUBSCRIPTION_KEY"],
        # Or use a per-agent JWT if you set up validate-jwt in policy
    },
    approval_mode="never_require",
)
```

Prompt agent (`agent-definition.yaml`):

```yaml
tools:
  - type: mcp
    server_label: contoso
    server_url: https://<apim>.azure-api.net/mcp/contoso
    require_approval: never
    headers:
      Ocp-Apim-Subscription-Key: ${APIM_SUBSCRIPTION_KEY}
```

> **Header gotcha**: in the current Foundry hosted preview, headers configured on an MCP tool apply **agent-wide, not per request**. Per-user OBO at query time isn't supported here yet — use the Azure OpenAI Responses API directly if you need that. (See [foundry-knowledge/foundry-iq.md](../foundry-knowledge/foundry-iq.md) for the same caveat.)

## Foundry-managed AI gateway routing (preview, optional shortcut)

If your Foundry resource is already connected to APIM and you want NEW MCP tools to auto-route:

1. Connect the AI gateway to your Foundry resource (Foundry portal → Configuration → AI gateway). One-time per Foundry resource.
2. **Re-create** the MCP tool in the portal (existing tools don't auto-migrate).
3. The tool now routes through APIM with the policies you configured on the gateway.

Limits to know:
- MCP tools that use **managed OAuth** are NOT eligible.
- Code-first MCP tools (declared in YAML/SDK, not the portal) are NOT eligible — use the manual front-door instead.
- AI gateway does NOT log tool traces — use APIM logging + your MCP server logs for tool-level detail.

## Required RBAC

| Action | Role | Scope |
|---|---|---|
| Create / modify APIM APIs and policies | `API Management Service Contributor` or `Owner` | APIM instance |
| Configure credential manager OAuth providers | `API Management Service Contributor` | APIM instance |
| Connect AI gateway to Foundry resource (preview) | `Cognitive Services Contributor` + `API Management Service Contributor` | Foundry account + APIM |
| Read APIM analytics for verification | `Reader` + `Application Insights Reader` | APIM + linked App Insights |

The agent's per-agent SP doesn't need APIM RBAC — it authenticates by APIM subscription key or JWT, not by Azure RBAC.

## Network considerations

| Foundry network class | APIM placement | Notes |
|---|---|---|
| `public` | Public APIM | Simplest. Agent hits public APIM endpoint; APIM forwards over public internet. |
| `managed_vnet` (allow_internet) | Public APIM | Agent egress is permitted; same as public class. |
| `managed_vnet` (allow_only_approved) | APIM with PE OR APIM in **Standard V2** with VNet integration | Add APIM FQDN to firewall allowlist OR managed PE. APIM Standard V2 supports VNet integration; older tiers don't. |
| `byo_vnet` | APIM in your VNet (Premium / V2) | Subnet-injected. Agent's delegated subnet must reach APIM's subnet (peering or same VNet). |

The on-prem MCP backend behind APIM is APIM's problem, not the agent's. APIM's hybrid connectivity (private endpoint to on-prem) is out of scope for this doc.

## Verify (KQL)

The agent sees `<apim>.azure-api.net` in OTel — not the real MCP server. Stitch with APIM's gateway logs to debug end-to-end:

```kql
// Agent-side: tool calls to the APIM front-door
dependencies
| where cloud_RoleName == "<agent_name>"
| where name == "execute_tool"
| where target has "azure-api.net"
| extend label = tostring(customDimensions["tool.server_label"])
| project timestamp, label, success, duration, target
| order by timestamp desc | take 20
```

Cross-reference with APIM diagnostic logs (App Insights `traces` table + `ApiManagementGatewayLogs`) using the `X-Correlation-Id` header set by your inbound policy.

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Agent gets 401 from APIM | `validate-jwt` audience doesn't match | Verify `aud` claim in agent's token vs policy |
| Agent gets 401 from MCP server (through APIM) | `get-authorization-context` returned no token | Re-authorize the credential manager connection; check identity-type matches the principal calling APIM |
| Agent gets 429 | `rate-limit-by-key` triggered | Inspect `Retry-After`; raise `calls` or change `counter-key` |
| Tool timeouts | APIM 240s default backend timeout < agent's tool budget | Set `<forward-request timeout="…">` higher |
| Spans show APIM, not the real MCP server | Working as designed | Stitch via correlation header (above) |
| Foundry-managed routing not active | Tool created BEFORE AI gateway was connected | Re-create the tool |

## Cost notes

- APIM Consumption tier: per-call pricing; fine for low-volume MCP tool dispatch.
- APIM Standard V2 / Premium: monthly fixed; justified when you have multiple AI / MCP APIs sharing the gateway.
- Credential manager itself is free; the OAuth provider has its own cost.

## See also

- [external-mcp.md](external-mcp.md) — direct MCP (no gateway) for the simple case
- [foundry-knowledge/foundry-iq.md](../foundry-knowledge/foundry-iq.md) — Foundry IQ KB MCP tool (same per-tool header caveat)
- [foundry-prod-readiness/networking.md](../foundry-prod-readiness/networking.md) — network class implications when APIM is in your VNet
- [foundry-roles/role-matrix.md](../foundry-roles/role-matrix.md) — caller-side roles for APIM ops
