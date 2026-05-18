---
description: Read-only declared-vs-observed reconciler for a deployed Foundry hosted agent. Walks every block in agent-capabilities.yaml + the live world; emits a markdown delta report. NEVER mutates Azure / Foundry / Purview state. Stamps agent-status.json with the audit summary.
input:
  - agent_path: "Path to the agent folder (e.g. agents/<name>)"
  - agent_name: "Deployed agent name (must match agent.yaml `name`)"
  - subscription_id: "Subscription containing the Foundry project (optional — discovered)"
  - resource_group: "Resource group containing the Foundry project (optional — discovered)"
  - foundry_account: "Foundry AI Services account name (optional — discovered)"
  - project_name: "Foundry project name (optional — discovered)"
  - report_path: "Where to write the markdown report (optional — default .audit-reports/<agent_name>-<YYYY-MM-DD>.md)"
  - include_reverse_drift: "true|false — scan for live state not declared in manifest (optional, default true)"
mcp:
  - azure
  - foundry
---

# Audit Drift: ${input:agent_name}

You are running a **read-only** reconciliation between `agent-capabilities.yaml` and the live world. Use **foundry-roles** for caller-side preflight, **foundry-deploy/agent-status-schema.md** for the state file, and every per-skill verify script that already exists.

> **Hard rule.** This prompt **does not mutate state**. No `az role assignment create`. No `az rest --method post|put|delete`. No file edits to `agent-capabilities.yaml`. No `mcp_*_create_*` / `_update_*` / `_delete_*` calls. The only writes are: (a) the markdown report file, (b) the `verify` block in `agent-status.json`. If a sub-script you call would mutate (e.g., `ensure_continuous_eval.py` without `--dry-run`), you MUST pass `--dry-run` or refuse to call it.

## Step 0 — Caller preflight (Reader floor)

`/audit-drift` only needs **`Reader`** on the resources it inspects. If `Reader` is missing on a particular resource, that section of the report degrades to `⚠ unknown — caller lacks Reader` and we continue. We never stop because of a Reader gap.

```bash
.agents/skills/foundry-roles/scripts/preflight-role.sh \
  Reader "<project_arm_scope>" \
  --action audit-drift --persona DevOps \
  --why "Read-only audit of declared-vs-observed state for ${input:agent_name}"
```

If exit 1: emit the runbook. If exit 2: continue best-effort.

## Step 1 — Read inputs

1. Load `${input:agent_path}/agent-capabilities.yaml`. If missing, STOP — the audit needs declared state to compare against.
2. Load `${input:agent_path}/agent-status.json`. If missing, WARN — we'll have no RBAC/eval/identity history to cross-reference, but capability + RBAC checks against live state still work.
3. Discover any missing inputs (subscription / RG / foundry account / project) using the same pattern as `/prepare-deploy` Step 0.
4. Compute the current capability hash:
   ```bash
   HASH=$(python .agents/skills/foundry-deploy/scripts/agent_status.py hash --agent-path ${input:agent_path})
   ```

Record start timestamp `AUDIT_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)` for the report header.

## Step 2 — Capability hash check

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py drift \
    --agent-path ${input:agent_path}
```

| Exit | Meaning | Report row |
|---|---|---|
| 0 | No drift, OR no baseline yet (first audit on this agent) | `✅ no manifest edits since last RBAC` |
| 1 | Drift detected | `❌ manifest hash changed since last RBAC` + show baseline + current |
| 2 | Capabilities or status file missing | `⚠ no baseline to compare against` |

> **Important.** This is the *first* signal. If the hash changed, every other check below is potentially stale (the live state was correct for the *prior* manifest version). Continue, but stamp the report header with `⚠ MANIFEST EDITED SINCE LAST RBAC — RESULTS MAY BE STALE`.

## Step 3 — Identities (cross-reference `agent-status.json`)

Re-discover the identities and compare with what's stamped in `agent-status.json`:

```bash
.agents/skills/foundry-identity/scripts/check-identities.sh \
  <sub> <rg> <foundry_account> <project> ${input:agent_name}
```

Compare `PROJECT_MI` and `AGENT_PRINCIPAL` against `identities.project_mi_principal_id` and `identities.agent_principal_id`. Mismatch = something redeployed the agent or rotated identities outside the skillpack — flag as `⚠ identity changed since last /configure-rbac`.

## Step 4 — Walk capability blocks

For each block declared in `agent-capabilities.yaml`, run the matching read-only check. **Use `--dry-run` on every wrapper that supports it.**

### 4.1 — `toolbox.mcp_servers[]`

For each entry:
- HTTP HEAD on `url` (skip if `${VAR}` placeholder leaked through — that's its own ❌).
- If `project_connection_id` is set: `mcp_foundry_mcp_project_connection_get` to confirm exists.
- KQL last 24h to confirm at least one `execute_tool` span with matching `tool.server_label`:
  ```kql
  dependencies
  | where cloud_RoleName == "${input:agent_name}"
  | where name == "execute_tool"
  | where customDimensions["tool.server_label"] == "<server_label>"
  | summarize last_seen=max(timestamp), call_count=count()
  ```
- **Reverse drift (if `${input:include_reverse_drift}`):** list all `execute_tool` spans in the last 24h grouped by `tool.server_label`; flag any label that's NOT in the manifest.

Report per server:
- `✅` URL reachable + connection exists + spans flowing
- `⚠ no spans in last 24h` (could be no traffic, or middleware swallowing)
- `⚠ reverse drift: live span for "<label>" not in manifest`
- `❌ url placeholder unresolved` / `❌ connection deleted`

### 4.2 — `knowledge.sources[]`

For each source, run [verify-source-rbac.sh](../skills/foundry-knowledge/scripts/verify-source-rbac.sh) and [verify-source-network.sh](../skills/foundry-knowledge/scripts/verify-source-network.sh). Both are read-only by design.

```bash
.agents/skills/foundry-knowledge/scripts/verify-source-rbac.sh \
  <kind> <resource_id> <CALLER_OID> <AGENT_PRINCIPAL>

.agents/skills/foundry-knowledge/scripts/verify-source-network.sh \
  <kind> <resource_id> <network_class> [<vnet_id>]
```

For each source in addition:
- If `kind == foundry_iq`: confirm the project connection still exists AND its `target` URL still references the declared `knowledge_base_name`. **Schema drift detector.**
- If `kind == ai_search_direct`: confirm the agent's tool config still references the declared `index_name`. (Read via Foundry agent definition; compare to `index_name` in the manifest.)
- If `kind in {file_search_*, blob_via_indexer}`: confirm Search service + Storage account still exist; confirm last indexer run status (via `GET {search}/indexers/{name}/status`) was within the last `schedule` interval.
- If `kind in {fabric_data_agent, fabric_direct_delta}` AND `network.class != public`: HARD ❌ — Fabric paths are not supported in network-isolated agents (would have been caught at preflight; flag if it slipped through).

#### Per-kind control-plane content checks (Reader floor; cheap; no data-plane queries)

In addition to the schema/RBAC/network checks above, run **one** control-plane content check per kind to detect "source is configured correctly but empty / unhealthy." These are cheap GETs (single REST call each), use `Reader` only (same as the rest of audit-drift), and do **NOT** trigger live agent invocations or model calls — that stays with `/verify-agent`.

| Kind | Check | Verdict |
|---|---|---|
| `foundry_iq` | `GET {search}/knowledgebases/{name}?api-version=2025-11-01-preview` — list connected sources | ✅ KB exists + N sources / ⚠ KB exists + 0 sources |
| `ai_search_direct` | `GET {search}/indexes/{name}/docs/$count?api-version=2024-07-01` | ✅ N docs / ⚠ 0 docs |
| `file_search_basic` | List vector stores via `mcp_foundry_mcp_*` (or project API); count files in the named store | ✅ N files / ⚠ vector store empty |
| `file_search_standard` | Same as basic + `az storage blob list --num-results 1 --container <name>` (existence probe) | ✅ N files + container non-empty / ⚠ files indexed but Storage container empty |
| `blob_via_indexer` | **already covered above** by indexer last-run-status check; in addition: `GET {search}/indexes/{name}/docs/$count` | ✅ indexer success + N docs / ⚠ indexer success but 0 docs |
| `fabric_data_agent` | Skip — Fabric workspace API requires a Fabric-aud token (TD-1). Print-only: "manual verification — open Fabric workspace `<name>` and confirm the data agent shows recent activity." | ⏳ verify manually |
| `fabric_direct_delta` | Skip — actual Delta read is data-plane. Print-only: "manual verification — run a SELECT against the lakehouse SQL endpoint." | ⏳ verify manually |
| `sharepoint_via_iq` | Skip — Graph + Purview check needs Compliance Admin. Print-only: "manual verification — Purview portal → DSPM → Discover → confirm SharePoint source shows recent activity." | ⏳ verify manually |

**Failure-mode interpretations:**
- `⚠ N=0` is a **real signal** for `/audit-drift` — the source is configured but has no content. Either the indexing pipeline failed silently, or the source was emptied. Flag for human review; do not auto-remediate.
- `⏳ verify manually` is **not a failure** — it just means the caller's RBAC isn't sufficient to programmatically check this kind. Print the manual step and continue.
- `❌ source unreachable` is **distinct** from configuration drift — the configuration matches the manifest, but the live resource doesn't respond. Examples: search service throttled, Storage account in maintenance, Foundry IQ KB deleted out-of-band.

**What this is NOT:**
- ❌ Not a smoke retrieve. We do not POST a query to the source. We do not invoke the agent. Those are `/verify-agent` Phase C concerns and should NOT run on every audit.
- ❌ Not a data-quality assertion. "0 docs" is a flag, not a hard fail. Some agents legitimately operate against intentionally-empty bootstrap indexes for first-week-of-launch scenarios.
- ❌ Not a freshness check beyond what's already in the indexer status. Stale-but-non-empty indexes are out of scope here; treat as a data-pipeline observability concern.

Report per source:
- `✅` exists + RBAC matches + network compatible + content present + (where applicable) indexer healthy
- `⚠ schema drift: manifest says <X>, live points at <Y>`
- `⚠ source empty: 0 docs / 0 files / 0 connected sources`
- `⏳ content check requires data-plane RBAC (caller lacks); verify manually`
- `❌ resource deleted` / `❌ RBAC missing for per-agent SP` / `❌ source unreachable`

### 4.3 — `guardrails`

For each declared layer:
- **Layer 1 (`middleware`):** confirm `guardrails.py` is vendored in the agent folder. KQL: ≥ 1 `guardrail.middleware` span in last 24h.
- **Layer 1.5 (`purview_dlp`):** confirm `purview_dlp_middleware.py` is vendored. KQL: ≥ 1 `guardrail.purview_dlp.*` span in last 24h. If `enforcement_mode == block`: confirm `AGREE_PURVIEW_DLP_PREVIEW=1` is on the agent version's env vars.
- **Layer 2 (`content_safety`):** confirm CS connection exists; per-agent SP has `Cognitive Services User` on the CS resource; KQL ≥ 1 `guardrail.content_safety` span in last 24h.

Report per layer:
- `✅` wired + spans present
- `⚠ no spans in last 24h` (could be no traffic, or layer not actually wired)
- `❌ vendored file missing` / `❌ RBAC missing` / `❌ block-mode env var missing`

### 4.4 — `purview`

- Confirm Purview toggle ON via Foundry account properties (Foundry portal → Compliance, OR `az rest` against the account).
- Cross-reference: `purview.audit_required: true` in manifest implies ≥ 1 `AIInvokeAgent` event in the Purview Audit log in the last 24h. **Querying Purview Audit programmatically requires Compliance Admin** — if the caller can't, fall back to printing the manual portal URL and tagging the row `⏳ verify manually`.

Report:
- `✅ toggle ON` + audit verified
- `⏳ toggle ON` + audit not queryable by caller (manual verify needed)
- `❌ toggle OFF` (or unknown — print exact portal path)

### 4.5 — `evals`

For each declared eval kind, list live rules and compare to manifest. **All checks read-only.**

```python
# Reads only — never call .create / .update / .delete
client = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())
continuous_rules = list(client.evaluation_rules.list())  # or equivalent
schedules        = list(client.schedules.list())
red_teams        = list(client.red_teams.list())
```

For each declared eval block, find the matching live rule by name (`continuous-eval-${input:agent_name}` etc.) and compare:
- `enabled`, `sampling_percent`, `max_hourly_runs`, evaluator IDs.
- For scheduled: cron, dataset reference, evaluators.
- For red-team: risk_categories, attack_strategies, num_objectives.

**Reverse drift:** any rule named like `*-${input:agent_name}` that isn't declared in the manifest → flag.

Report per kind:
- `✅` matches manifest field-for-field
- `⚠ field drift: manifest says <X>, live <Y>` (per field)
- `⚠ reverse drift: live rule "<name>" not declared in manifest`
- `❌ declared but no live rule` / `❌ rule disabled`

### 4.6 — `network`

Run all four detection scripts; compare verdict to manifest declaration.

```bash
.agents/skills/foundry-prod-readiness/scripts/network/check-foundry-network-mode.sh <sub> <rg> <foundry_account> [<acr>]
# ... per declared knowledge.sources[].resource_id:
.agents/skills/foundry-prod-readiness/scripts/network/check-source-network.sh <rid>
.agents/skills/foundry-prod-readiness/scripts/network/check-private-endpoint.sh <rid>
# ... if network.class != public:
.agents/skills/foundry-prod-readiness/scripts/network/check-private-dns.sh <vnet_id> <service>
```

Report per check:
- `✅` matches manifest
- `⚠ class drift: manifest says <X>, live is <Y>` (immutable post-deploy — usually means manifest is stale)
- `⚠ PE state: <approved|pending|rejected>`
- `❌ hard block: source publicNetworkAccess=Disabled and no PE`

### 4.7 — Per-agent SP RBAC (cross-reference `agent-status.json`)

Read `rbac.capability_grants.*` from `agent-status.json`. For each entry, run `az role assignment list` against the recorded `scope` filtered by the recorded `role` and `granted_to`. If missing → `❌ REVOKED`. If present → `✅`.

**Reverse drift:** list ALL role assignments on the per-agent SP across all subscriptions the caller can see; flag any that aren't in `rbac.capability_grants` and aren't part of the Phase 2 base set.

```bash
az role assignment list --assignee <AGENT_PRINCIPAL> --all -o json
```

Report:
- One row per declared grant
- One row per reverse-drift grant

## Step 5 — Compose the markdown report

Layout:

```markdown
## Drift Report — ${input:agent_name} (audit at <AUDIT_TS>)

CAPABILITY HASH:
  declared:           <current_hash>
  baseline_at_rbac:   <hash from agent-status.json>
  current:            <current_hash>
  → <no manifest edits since last RBAC | MANIFEST EDITED — re-run /configure-rbac before relying on the rest>

IDENTITIES:
  Project MI:         <oid> <✅ matches | ⚠ changed since stamp>
  Per-agent SP:       <oid> <✅ matches | ⚠ changed since stamp>

TOOLBOX MCP SERVERS:
  ...

KNOWLEDGE SOURCES:
  ...

GUARDRAILS:
  ...

PURVIEW:
  ...

EVAL RULES:
  ...

NETWORK:
  ...

RBAC (per-agent SP <oid>):
  ...

REVERSE DRIFT (live state not in manifest):
  - <each item with → recommendation>

SUMMARY: N ✅, M ⚠, K ❌
RECOMMENDATIONS:
  1. <ordered, deduplicated list of next-steps from the report>
```

Write to `${input:report_path}` (default `.audit-reports/${input:agent_name}-$(date +%Y-%m-%d).md`). Create the directory if needed.

## Step 6 — Stamp `agent-status.json`

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
    --agent-path ${input:agent_path} \
    --section verify \
    --json '{
      "last_audit_at": "<AUDIT_TS>",
      "audit_summary": {"pass": <N>, "warn": <M>, "fail": <K>},
      "audit_report_path": "<report_path>"
    }'
```

> Note: the `verify.last_audit_at` field is *additive* — it does NOT replace `verify.last_run_at` (which is set by `/verify-agent`). Audit and verify are independent operations on the same `verify` section.

## Step 7 — Print summary to user

Echo the SUMMARY + RECOMMENDATIONS section of the report (not the full report — they can read the file). Then:

- If `K > 0`: print `🚨 ${K} hard failures. Fix immediately.`
- Elif `M > 0`: print `⚠ ${M} warnings. Review at next maintenance window.`
- Else: print `✅ All clear.`

End with: `Report saved to <report_path>. Re-run /audit-drift after remediation.`

## Operational notes

- **Schedule.** `/audit-drift` is designed to run on a schedule (weekly is reasonable). Wire into your CI as a non-blocking job that comments on a tracking issue when the report changes.
- **PR gating.** Don't gate PRs on `/audit-drift` results — it queries live state, which can change without code edits. Gate on `/verify-agent` instead.
- **Cost.** ~10–30 az/Foundry/Purview API calls per audit. Negligible. Per-resource Reader RBAC is the only requirement.
- **What this prompt deliberately does NOT do:**
  - Auto-fix anything. Drift remediation is `/configure-rbac` + `/verify-agent`.
  - Data-plane smoke retrieves (no live agent invocation, no model call, no actual SQL/MCP query). `/audit-drift` does cheap **control-plane content checks** per source (see Step 4.2 — "Per-kind control-plane content checks"); the data-plane smoke retrieve stays in `/verify-agent` Phase C.
  - Network deep-dive (NSG/Firewall walking). The four detection scripts are the floor.
  - Mutate `agent-capabilities.yaml`. Reverse drift is REPORTED, not silently absorbed.
