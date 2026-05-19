---
validity_date: 2026-05-14
audience: You have an APIM instance and an MCP server you want centrally governed
duration: ~60 minutes (highly tenant-specific — most variability is APIM setup)
surfaces: [agent_framework_runtime, apim_fronted_mcp, per_source_rbac_verify, drift_baseline]
prerequisites:
  - Recipe 01 or 02 completed
  - Existing APIM instance (any tier; Standard V2 / Premium needed for VNet later)
  - An MCP server (your own; or a public one like Microsoft Learn MCP for testing)
  - APIM caller has `API Management Service Contributor` on the APIM instance
  - For OAuth credential manager: an Entra app registration for the upstream MCP server
---

# Recipe 05 — APIM-Fronted MCP + RBAC Verify + Drift Baseline

> **Goal:** Route your agent's MCP calls through APIM AI Gateway so you get central rate limits, OAuth token injection, and unified audit. Verify per-source RBAC. Establish a drift baseline so future capability edits are detectable.

3 surfaces: **agent runtime + APIM-fronted MCP + (per-source RBAC verification AND drift baseline via `agent-status.json`)**.

> **Honest framing.** This is the most tenant-specific recipe. APIM has many dials (tier, OAuth provider, credential-manager setup, network class). The recipe walks the *minimum useful path*; the [`apim-as-mcp-frontdoor.md`](../../../../foundry-agent-skillpack/.apm/skills/foundry-deploy/apim-as-mcp-frontdoor.md) sub-doc has the full surface.

## Surface map

| Surface | Choice |
|---|---|
| Agent runtime | `agent-framework` |
| Tool / Knowledge | MCP tool, but the URL points at APIM (not the upstream server) |
| Outer loop 1 | Per-source RBAC verification via [`verify-source-rbac.sh`](../../../../foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/verify-source-rbac.sh) |
| Outer loop 2 | Drift baseline + detection via [`agent_status.py drift`](../../../../foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/agent_status.py) |

## Step 1 — Stand up the APIM API for one MCP server

In APIM, create an API for the MCP server you want to front. Minimum:

```bash
APIM=<your-apim-name>
RG=<apim-rg>
UPSTREAM=https://contoso-mcp.example.com   # or https://learn.microsoft.com/api/mcp for testing

az apim api create \
  --resource-group "$RG" --service-name "$APIM" \
  --api-id mcp-contoso \
  --display-name "Contoso MCP" \
  --path "mcp/contoso" \
  --service-url "$UPSTREAM" \
  --protocols https
```

Add the minimum policies (`<inbound>` block) — JWT validation, OAuth token injection (if needed), rate limit, correlation header. Full XML in [apim-as-mcp-frontdoor.md § Apply the policies you actually need](../../../../foundry-agent-skillpack/.apm/skills/foundry-deploy/apim-as-mcp-frontdoor.md).

✅ **Checkpoint.** Test the APIM URL works:

```bash
curl -H "Ocp-Apim-Subscription-Key: $APIM_KEY" \
     "https://${APIM}.azure-api.net/mcp/contoso/some-test-endpoint"
```

Returns 200 (or whatever the upstream returns) — not 401 / 404.

---

## Step 2 — Update agent manifest

```yaml
schema_version: 1
agent_kind: hosted

capabilities:
  toolbox:
    enabled: true
    mcp_servers:
      - server_label: contoso_apim
        url: https://<apim>.azure-api.net/mcp/contoso     # APIM URL, NOT upstream
        require_approval: never
        # Note: in current Foundry hosted preview, headers are agent-wide (per-connection),
        # not per-request. The APIM subscription key is set on the agent version's env vars
        # and injected by the agent code into the headers map.

  network:
    class: public
```

Update `main.py` so the MCP tool reads `APIM_SUBSCRIPTION_KEY` from env and passes it as `Ocp-Apim-Subscription-Key`:

```python
mcp_tool = client.get_mcp_tool(
    name="contoso_apim",
    url=os.environ["CONTOSO_MCP_URL"],
    headers={"Ocp-Apim-Subscription-Key": os.environ["APIM_SUBSCRIPTION_KEY"]},
    approval_mode="never_require",
)
```

Add the env vars to `agent.yaml`:

```yaml
environment_variables:
  - name: AZURE_AI_MODEL_DEPLOYMENT_NAME
    value: ${AZURE_AI_MODEL_DEPLOYMENT_NAME}
  - name: CONTOSO_MCP_URL
    value: https://<apim>.azure-api.net/mcp/contoso
  - name: APIM_SUBSCRIPTION_KEY
    value: ${APIM_SUBSCRIPTION_KEY}     # set via `azd env set APIM_SUBSCRIPTION_KEY <key>` BEFORE azd up
```

> **Don't bake the key into the image.** Set it via `azd env set` (becomes a Bicep parameter on deploy) or via a Key Vault connection.

✅ **Checkpoint.** Manifest + `main.py` updated; `azd env set APIM_SUBSCRIPTION_KEY <value>` done.

---

## Step 3 — Deploy

```bash
azd up
```

The agent now calls `https://<apim>.azure-api.net/mcp/contoso/...` for MCP traffic. You won't see this from the agent's perspective — the tool URL is just an opaque endpoint to it.

✅ **Checkpoint.** `azd ai agent show` returns `status: active`.

---

## Step 4 — Verify per-source RBAC

For APIM-fronted sources, the per-agent SP doesn't need any APIM RBAC — APIM authenticates by subscription key (in this recipe). What we DO verify is that the **caller** has the rights to manage / inspect APIM:

```bash
APIM_RID=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim>
CALLER_OID=$(az ad signed-in-user show --query id -o tsv)
AGENT_OID=$(az rest --method get \
  --uri "https://management.azure.com${PROJECT_ARM_ID}/agents/<your-name>?api-version=2025-04-01-preview" \
  --query instance_identity.principal_id -o tsv)

# Use the verify-source-rbac.sh script; "ai_search_direct" kind is the closest match
# for "external resource the agent reads from over HTTPS." It will check caller +
# agent — for APIM, only caller-side roles matter (see "agent" output for context).
.agents/skills/foundry-knowledge/scripts/verify-source-rbac.sh \
  ai_search_direct "$APIM_RID" "$CALLER_OID" "$AGENT_OID"
```

Expected output (caller side):

```
[+] Caller has 'Search Service Contributor' on <apim>     ← will fail; that's not the right role for APIM
```

In practice you'll want to verify the actual APIM role:

```bash
az role assignment list \
  --assignee "$CALLER_OID" --scope "$APIM_RID" \
  --query "[?roleDefinitionName=='API Management Service Contributor'] | length(@)" -o tsv
# Should print: 1
```

> **Honest gap.** `verify-source-rbac.sh` doesn't have a first-class `apim` kind today. The script's per-kind matrix is biased toward Foundry-native sources. Adding APIM as a `kind` is a follow-on. For now the verification is a manual `az role assignment list`.

✅ **Checkpoint.** Caller has `API Management Service Contributor` on the APIM instance. Per-agent SP has no APIM grants (correct for subscription-key auth).

---

## Step 5 — Smoke test through the front-door

```
/verify-agent agent_name=<your-name> test_query="<a query that triggers an MCP tool call>" agent_path=agents/<your-name>
```

Look at the agent's OTel:

```kql
dependencies
| where cloud_RoleName == "<agent_name>"
| where name == "execute_tool"
| extend label = tostring(customDimensions["tool.server_label"])
| where label == "contoso_apim"
| project timestamp, target, success, duration
| order by timestamp desc | take 10
```

The `target` field should show `<apim>.azure-api.net/mcp/contoso/...` — confirming traffic goes through APIM. Cross-reference with APIM's own diagnostics:

```kql
ApiManagementGatewayLogs
| where ApiId == "mcp-contoso"
| project TimeGenerated, BackendResponseCode, ClientIP, CorrelationId
| order by TimeGenerated desc | take 10
```

Stitch via the `X-Correlation-Id` header set in your inbound policy.

✅ **Checkpoint.** Agent's `execute_tool` span timestamp matches an APIM `ApiManagementGatewayLogs` entry within seconds.

---

## Step 6 — Establish a drift baseline + verify drift detection

The drift baseline is set automatically by `/configure-rbac` Step 4. To prove drift detection works:

```bash
# Confirm baseline is set
python .agents/skills/foundry-deploy/scripts/agent_status.py read \
    --agent-path agents/<your-name> --field drift.capability_hash_at_rbac
# Should print a 12-char hash, e.g. a3f29c84b1d0
```

Now simulate drift:

```bash
# Edit agent-capabilities.yaml — change anything, e.g., the sample_rate
# (or add a comment, or a new mcp_server entry)

# Re-run drift detection
python .agents/skills/foundry-deploy/scripts/agent_status.py drift \
    --agent-path agents/<your-name>
# Expect: exit 1; "DRIFT detected" with old vs new hash
```

`/verify-agent`'s Step −1 also runs this check; it'll prompt you to re-run `/configure-rbac` before relying on the verify result.

✅ **Checkpoint.** Drift detection fires (exit 1) when `agent-capabilities.yaml` changes; clears (exit 0) after re-running `/configure-rbac`.

---

## Recap — what you proved

| Surface | Evidence |
|---|---|
| Agent runtime | Same as prior recipes |
| APIM-fronted MCP | Tool spans target `<apim>.azure-api.net`; APIM logs show matching requests with correlation IDs |
| Outer loop 1 — RBAC verify | Caller has APIM RBAC; per-agent SP correctly has none (subscription-key auth) |
| Outer loop 2 — Drift baseline | `agent-status.json` `drift.capability_hash_at_rbac` set; drift script detects edits |

## Operational notes — APIM in production

Things this recipe deliberately doesn't cover (each is a separate decision):

- **OAuth credential manager** for upstream MCP servers that need OAuth (not subscription key). See [apim-as-mcp-frontdoor.md § Secure outbound access](../../../../foundry-agent-skillpack/.apm/skills/foundry-deploy/apim-as-mcp-frontdoor.md).
- **Foundry-managed AI gateway routing** (preview) — auto-routes new MCP tools through APIM. Restricted: only new tools, no managed-OAuth, code-first MCP tools excluded.
- **APIM in your VNet** (Standard V2 / Premium) for `network.class: byo_vnet` agents. Subnet integration + DNS link required.
- **Content-safety policy at the gateway** (`llm-content-safety`) — adds latency on tool-call paths; designed for chat, use selectively.

## Cleanup

```bash
azd down --purge
az apim api delete --service-name "$APIM" -g "$RG" --api-id mcp-contoso --yes
# APIM credential-manager connections (if any): delete via portal or `az apim`.
```

## Where to go next

- Wire OAuth credential manager (replace subscription key with bearer token) → [apim-as-mcp-frontdoor.md § OAuth-2 outbound](../../../../foundry-agent-skillpack/.apm/skills/foundry-deploy/apim-as-mcp-frontdoor.md).
- Move the agent into a managed-VNet Foundry account → [foundry-prod-readiness/networking.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/networking.md) + add APIM PE.
- Layer continuous eval on top → see [01-greenfield-quickstart.md § Step 5](01-greenfield-quickstart.md).
