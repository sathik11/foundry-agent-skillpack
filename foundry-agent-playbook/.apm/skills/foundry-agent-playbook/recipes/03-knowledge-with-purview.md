---
validity_date: 2026-06-08
audience: You have (or can create) a Foundry IQ knowledge base; tenant has Purview audit available
duration: ~60 minutes (mostly waiting for Purview audit population)
surfaces: [agent_framework_runtime, foundry_iq_knowledge, content_safety, purview_audit]
prerequisites:
  - Recipe 01 or 02 completed (you have a working agent)
  - Foundry IQ knowledge base in your AI Search service (or follow https://learn.microsoft.com/azure/foundry/agents/concepts/what-is-foundry-iq to create one)
  - Tenant licensed for M365 E5 OR Microsoft Agent 365 (Purview AI audit requirement)
  - Caller has `Cognitive Services Security Integration Administrator` OR `Foundry Account Owner` on the Foundry account (to flip the Purview toggle)
  - Content Safety resource + connection in the Foundry project
---

# Recipe 03 — Knowledge Agent with Purview Audit

> **Goal:** Wire a Foundry IQ knowledge base to your agent, add Content Safety guardrails (Layer 2), and prove Purview audit captures `AIInvokeAgent` events for the agent. End state: agent answers from the KB with citations, blocked content is refused at the gateway, audit shows up in Purview.

This is a 3-surface recipe: **agent runtime + Foundry IQ knowledge + (Content Safety AND Purview audit)**.

## Surface map

| Surface | Choice |
|---|---|
| Agent runtime | `agent-framework` (LangGraph BYO works too — substitute the runtime; the rest is identical) |
| Knowledge | Foundry IQ KB MCP tool (`knowledge.sources[].kind: foundry_iq`) |
| Outer loop 1 | Content Safety connection (`guardrails.layers: [content_safety]`) |
| Outer loop 2 | Purview audit toggle on the Foundry account |

## Step 1 — Add knowledge + guardrails + purview to your manifest

Edit `agents/<your-name>/agent-capabilities.yaml`:

```yaml
schema_version: 1
agent_kind: hosted

capabilities:
  knowledge:
    sources:
      - name: hr-policies
        kind: foundry_iq
        knowledge_base_name: hr-policy-kb        # the KB you created in AI Search
        search_resource_id: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Search/searchServices/<search>
        project_connection_name: kb-mcp-prod     # the RemoteTool connection (created in Step 3)
        acl_passthrough: false                   # preview limit: per-connection, not per-request

  guardrails:
    enabled: true
    layers: [middleware, content_safety]
    middleware_mode: entry
    content_safety:
      connection_name: cs-prod                   # name of your CS connection in Foundry project
      severity_threshold: 4                       # 0=Safe 2=Low 4=Medium 6=High

  purview:
    enabled: true
    audit_required: true                          # AIInvokeAgent / AIExecuteTool to audit
    dspm_inventory: true
    # dlp.enabled stays false — preview-limited

  network:
    class: public
```

✅ **Checkpoint.** `agent-capabilities.yaml` saved. Don't deploy yet — preflight first.

---

## Step 2 — Preflight (`/prepare-deploy`)

```
/prepare-deploy agent_path=agents/<your-name>
```

What you're looking for:

- **`knowledge.foundry_iq` gate:**
  - AI Search service exists + supports agentic retrieval (`semanticSearch != "disabled"`).
  - Knowledge base `hr-policy-kb` exists in the search service.
  - Caller has `Search Service Contributor` on the search service AND `Foundry Project Manager` on the Foundry project.
  - Project connection `kb-mcp-prod` exists OR can be created.
- **`guardrails.content_safety` gate:**
  - CS connection `cs-prod` exists in the project.
  - Vendored `guardrails.py` is present in the agent folder (template ships it; brownfield needs to copy from `foundry-guardrails/scripts/`).
- **`purview` gate:**
  - Tenant licensing check (M365 E5 / Agent 365 SKU present).
  - Toggle status — usually surfaces as ⚠ "verify portal manually" because there's no programmatic read for this in preview.

Each ❌ comes with the exact next step. Common failures:

- "Workspace not found" creating connection → use `az cognitiveservices account project connection create` (NOT `az ml`).
- "KB not found" → confirm the KB is in the *search service*, not the Foundry project.
- "CS connection not found" → create via Foundry portal → Connections → Add → Content Safety.

✅ **Checkpoint.** Preflight passes (or shows only ⚠ items you've manually verified).

---

## Step 3 — Create the Foundry IQ project connection (if not done)

If the preflight reported "project connection `kb-mcp-prod` does not exist," create it. The skillpack can guide you; the underlying call is:

```bash
TOKEN=$(az account get-access-token --scope https://management.azure.com/.default --query accessToken -o tsv)
PROJECT_ARM_ID=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<acct>/projects/<proj>
SEARCH_ENDPOINT=https://<search>.search.windows.net

az rest --method put \
  --uri "https://management.azure.com${PROJECT_ARM_ID}/connections/kb-mcp-prod?api-version=2025-10-01-preview" \
  --headers "Authorization=Bearer ${TOKEN}" "Content-Type=application/json" \
  --body @- <<EOF
{
  "properties": {
    "category": "RemoteTool",
    "target": "${SEARCH_ENDPOINT}/agents/${KB_NAME}/mcp",
    "authType": "ProjectManagedIdentity",
    "metadata": {}
  }
}
EOF
```

✅ **Checkpoint.** Connection appears in Foundry portal → your project → Connections.

---

## Step 4 — Toggle Purview integration (manual; needs admin role)

This is the step that often blocks dev-only callers. The toggle lives at:

> Azure Portal → Foundry account → **Operate → Compliance → Security → Microsoft Purview** → Enabled

Required role: `Cognitive Services Security Integration Administrator` OR `Foundry Account Owner`.

If you don't have the role, the skillpack emits a runbook for the assignee. Don't block the rest of the deploy — Phase B grants don't depend on this toggle.

✅ **Checkpoint.** Toggle is ON. (Verify via Foundry portal → Compliance → Security tab.)

---

## Step 5 — Deploy + RBAC

```bash
azd up
/configure-rbac agent_path=agents/<your-name> agent_name=<your-name>
```

Phase B grants for this recipe:

- **Project MI → `Search Index Data Reader`** on the search service (Foundry IQ KB read).
- **Per-agent SP → `Cognitive Services User`** on the CS resource (already wired via `grant-cs-access.sh` in capability dispatch).

Both stamped into `agent-status.json` `rbac.capability_grants`.

> Wait 5–15 minutes for propagation. Wait additionally **up to 30 minutes** for Purview audit to start populating after the toggle was flipped.

---

## Step 6 — Verify (`/verify-agent`) + smoke the three surfaces

```
/verify-agent agent_name=<your-name> test_query="What is our HR policy on remote work?" agent_path=agents/<your-name>
```

The verify report should show:

```
Capability verification:
  knowledge    ✅ (hr-policies: knowledge_base_retrieve span, citation present)
  guardrails   ✅ (5 guardrail.middleware spans; 1 guardrail.content_safety span on a known-blocked sample)
  purview      ⏳ (no audit yet — retry in 25 min)
```

The `purview` row will likely be ⏳ at first. After 30 minutes from the toggle flip, re-run to verify.

### Verifying Purview audit manually

Foundry agent events flow through the **Office 365 Management Activity API**, NOT the M365 Sentinel connector. To check:

1. **Purview portal → Audit → Search.**
2. Operations: `AIInvokeAgent`, `AIExecuteTool`, `AIInferenceCall`.
3. Date range: last hour.
4. Filter for the agent name in the `AuditData`.

You should see one entry per invocation, with the agent name in the JSON payload.

If empty after 30 min and toggle is confirmed ON:
- Confirm tenant licensing (`az rest` to subscribedSkus — see [foundry-purview/SKILL.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-purview/SKILL.md) Phase A snippet).
- Confirm DSPM inventory: Purview → DSPM → Discover → Apps and Agents.

### Verifying Content Safety blocking

Send a deliberately bad input:

```bash
curl -X POST "${EP}/agents/<your-name>/endpoint/protocols/openai/responses?api-version=v1" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Foundry-Features: HostedAgents=V1Preview" \
  -d '{"input": [{"role":"user","content":[{"type":"input_text","text":"<a bad prompt that violates CS categories>"}]}], "stream": false}'
```

Expect a refusal-style response. Confirm via KQL:

```kql
dependencies
| where cloud_RoleName == "<agent_name>"
| where name startswith "guardrail.content_safety"
| project timestamp, name, customDimensions
| order by timestamp desc | take 5
```

✅ **Checkpoint.** All three surfaces verified independently:
1. Knowledge — KB-grounded answer with citation.
2. Content Safety — blocked input refused.
3. Purview — audit entry visible.

---

## Recap — what you proved

| Surface | Evidence |
|---|---|
| Agent runtime | Same as Recipe 01 — agent reaches `active`, returns content |
| Knowledge — Foundry IQ | KB MCP tool span; response cites a doc URL |
| Outer loop 1 — Content Safety | `guardrail.content_safety` span; blocked input refused |
| Outer loop 2 — Purview audit | `AIInvokeAgent` / `AIExecuteTool` entries in Purview Audit search |

## Cleanup

```bash
azd down --purge
# Delete the project connection (KB stays in AI Search):
az rest --method delete --uri "https://management.azure.com${PROJECT_ARM_ID}/connections/kb-mcp-prod?api-version=2025-10-01-preview"
# To turn off Purview: re-toggle in the same portal location. Auditing of past events is retained per tenant retention policy.
```

## Where to go next

- Need a regression-set + publish gate before promoting versions → [04-ai-search-with-scheduled-eval.md](04-ai-search-with-scheduled-eval.md).
- Need to front the KB MCP through APIM (rate limits, central audit) → [05-apim-fronted-mcp.md](05-apim-fronted-mcp.md).
- Want red-team scans on top → see [foundry-evals/redteam.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-evals/redteam.md) (region-locked).
