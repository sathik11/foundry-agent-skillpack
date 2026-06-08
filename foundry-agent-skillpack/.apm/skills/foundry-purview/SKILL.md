---
name: foundry-purview
description: Purview governance for Foundry agents — toggle, audit operations, DLP, and sensitivity labels (Layer 4)
---

# Foundry Purview Governance

## Scope — Be Honest

Purview is primarily designed for M365 Copilot/Copilot Studio agents. Foundry hosted agent integration is limited to an opt-in toggle.

| Capability | Foundry Hosted | M365 Copilot |
|---|---|---|
| Runtime signal emission | ✅ After toggle | ✅ Built-in |
| DSPM inventory | ✅ After toggle | ✅ Automatic |
| Audit (`AIInvokeAgent`, `AIExecuteTool`) | ✅ After toggle | ✅ Automatic |
| **DLP enforcement (block / warn / audit)** | ⚠ **Not native — closed by [foundry-guardrails/purview-dlp.md](../foundry-guardrails/purview-dlp.md) middleware** | ✅ Built-in |
| Admin lifecycle audit | ❌ Not available today | ✅ Copilot Studio only |

## The Toggle

Location: Azure Portal → Foundry account → **Operate → Compliance → Security → Microsoft Purview**

Without it: DSPM dashboards empty for Foundry agents.
With it: audit trail + inventory. NOT sufficient for full DLP.

## Prerequisites

- License: M365 E7 OR Microsoft Agent 365
- Role to flip toggle: `Cognitive Services Security Integration Administrator` or `Foundry Account Owner`
- Role for DSPM policies: `Purview Data Security AI Admin`

## Minimum Setup

1. Confirm licensing
2. Flip the toggle
3. Verify: Purview portal → DSPM → Discover → Apps and Agents
4. Query audit: Purview Audit → search `AIInvokeAgent`
5. Optional: DSPM → Recommendations → create DLP policy (simulation mode by default)

## Audit Operations

| Operation | Available for Foundry |
|---|---|
| `AIInvokeAgent` | ✅ |
| `AIExecuteTool` | ✅ |
| `AIInferenceCall` | ✅ |
| `AgentAdminActivity` | ❌ (Copilot Studio only) |

Retention: 180 days default, 365 with M365 E5.
Sentinel: agent events do NOT flow through M365 connector — use Office 365 Management Activity API.

## Preflight (Phase A, called by `/prepare-deploy`)

Run when `capabilities.purview.enabled: true`.

1. **Tenant licensing**
   ```bash
   az rest --method get --uri "https://graph.microsoft.com/v1.0/subscribedSkus" \
     --query "value[?contains(skuPartNumber,'M365_E5') || contains(skuPartNumber,'AGENT365')].skuPartNumber" -o tsv
   ```
   Empty → STOP. Audit + DSPM require M365 E7 or Agent 365.

2. **Toggle is ON** at the Foundry account:
   - Discover via `mcp_foundry_mcp_foundryextensions` (capability check in account properties), OR
   - Print the portal path the user must verify: *Foundry account → Operate → Compliance → Security → Microsoft Purview → Enabled*.
   - If the toggle is off and the user lacks `Cognitive Services Security Integration Administrator`, STOP and tell them which role to obtain.

3. **DSPM inventory** (`dspm_inventory: true`): no automatic check possible — inventory is populated lazily after first invocation. Note that verification will retry with backoff in Phase C.

4. **DLP** (`dlp.enabled: true`):
   - Print this verbatim: *"Foundry-native DLP for hosted agents is preview-limited. Without the Purview SDK middleware (TD-4), this gate enforces audit only — not label-aware blocking."*
   - Require explicit `--ack-purview-dlp-preview` flag or interactive y/N confirmation.
   - For each policy in `dlp.policies`, optionally check existence via Purview compliance API (this requires Compliance Admin token — print-only fallback).

## Post-deploy (Phase B, called by `/configure-rbac`)

No per-agent grants — the toggle is account-scoped. If `audit_required: true` and the toggle was just flipped, print: *"Audit pipeline takes up to 30 minutes to populate. Re-run /verify-agent after 30 min if first verification fails."*

## Verify (Phase C, called by `/verify-agent`)

1. **Audit query** (Purview Audit / Office 365 Management Activity API):
   ```
   Search-UnifiedAuditLog -Operations AIInvokeAgent,AIExecuteTool \
     -StartDate (Get-Date).AddHours(-1) -EndDate (Get-Date) \
     | Where-Object { $_.AuditData -match "<agent_name>" }
   ```
   Empty after a confirmed invocation older than 30 min → toggle is off, agent is not in DSPM scope, or licensing is missing.

2. **DSPM inventory** (Purview portal → DSPM → Discover → Apps and Agents): print the URL; this surface is not API-queryable today (TD-3 sibling).

3. **DLP block events** (only meaningful if Purview SDK middleware is wired): query `AIPolicyBlocked` operations.
