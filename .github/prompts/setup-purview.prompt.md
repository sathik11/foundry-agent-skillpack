---
description: Enable Microsoft Purview governance toggle and verify audit trail for Foundry agents
input:
  - foundry_account: "Foundry account name"
mcp:
  - azure
---

# Setup Purview: ${input:foundry_account}

Use the **foundry-purview** skill. Be honest about Foundry-specific limitations.

## Prerequisites Check

1. **Licensing**: Confirm M365 E7 or Microsoft Agent 365 is active on the tenant.
   If not, Purview governance is not available — inform the user and stop.

2. **Role**: Confirm user has `Cognitive Services Security Integration Administrator`
   or `Foundry Account Owner` role.

## Step 1 — Flip the Toggle

Navigate to: Azure Portal → Foundry account `${input:foundry_account}` → **Operate → Compliance → Security → Microsoft Purview** → Enable.

Without this toggle, DSPM dashboards will show nothing for Foundry agents.

## Step 2 — Verify Inventory

Navigate to: https://purview.microsoft.com → **Solutions → DSPM → Discover → Apps and Agents**

Confirm Foundry agents appear in the inventory. If they don't:
- Wait 15-30 minutes for propagation
- Verify the toggle is actually enabled
- Check if Agent 365 inventory connector needs additional opt-in (open verification item)

## Step 3 — Verify Audit

Navigate to: Purview portal → **Audit** → Search by operation `AIInvokeAgent`

If events appear → audit is flowing ✅
If empty → agent needs to be invoked at least once after toggle was enabled

## Step 4 — Optional: Create DLP Policy in Purview portal

DSPM → **Recommendations** → "Fortify your data security" → Create policies.
Policies land in **simulation mode by default** — admins must explicitly enforce.

## Step 5 — Optional: Wire runtime DLP enforcement (Layer 1.5 middleware)

The Purview audit toggle gives you visibility but **no runtime enforcement**. To actually **block / warn / audit** prompts and responses based on detected SITs and sensitivity labels, wire the [foundry-guardrails/purview-dlp.md](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-guardrails/purview-dlp.md) middleware:

1. Add to `agent-capabilities.yaml`:
   ```yaml
   guardrails:
     enabled: true
     layers: [middleware, content_safety, purview_dlp]   # add purview_dlp
     purview_dlp:
       enabled: true
       enforcement_mode: audit_only                       # start here; opt into warn/block later
       policies: [dlp-pii-strict]                         # Purview-side policy IDs
   ```
2. Vendor `scripts/purview_dlp_middleware.py` from foundry-guardrails into the agent folder.
3. Wire `PurviewDLPMiddleware` in `main.py` after `GuardrailAgentMiddleware`.
4. Re-deploy.
5. Run `.agents/skills/foundry-guardrails/scripts/grant-purview-dlp-access.sh <agent_name>` post-deploy — likely emits a Tenant Admin runbook (the roles are tenant-scoped).

Read [foundry-guardrails/purview-dlp.md](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-guardrails/purview-dlp.md) § "Honest preview limitations" before enabling `enforcement_mode: block`.

## Step 6 — Disclose Limitations

Tell the user:
- Admin lifecycle audit (`AgentAdminActivity`) is **not available** for Foundry agents today.
- Native runtime DLP enforcement is **not available** — use the Layer 1.5 middleware (Step 5) instead.
- Sentinel integration requires Office 365 Management Activity API (not M365 connector).
