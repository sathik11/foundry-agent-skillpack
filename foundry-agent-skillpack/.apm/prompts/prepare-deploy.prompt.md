---
description: Validate a Foundry agent project is azd-ready, run apm audit, then optionally execute `azd up`. Forks on hosted (container) vs prompt (definition-only) agents.
input:
  - agent_path: "Path to the agent folder (e.g. agents/learn-agent or sandbox/learn-agent)"
  - resource_group: "Resource group containing the Foundry project (optional — discovered if omitted)"
  - deep_network: "Opt-in flag: when 'true', the per-source network checks invoke NSG / Azure Firewall / SEP walkers (TD-10 Layer 1). Default 'false' (fast path; 60-120s slower per source when on). Has no effect when network.class == public."
mcp:
  - azure
---

# Prepare Deploy: ${input:agent_path}

You are a Foundry Agent Engineer. **APM's job ends at "azd-ready."** This prompt does **not** run `az acr build` or call the Foundry REST control plane — that is `azd up` + the `azd ai agent` extension's job. We validate, audit, and hand off.

Use the **foundry-deploy**, **foundry-identity**, and **foundry-failure-modes** skills.

> **Anti-synthesis guard.** This prompt collects facts only via the listed MCP tools and the helpers under `.agents/skills/*/scripts/`. Do NOT shell out to `az`, `curl`, `python -c`, or any other ad-hoc command to enumerate Azure resources. If a needed value is missing from `agent-capabilities.yaml` and no MCP tool can supply it, STOP and ask the user.

---

## Step 0 — Caller-role + target preflight (FAIL-FAST)

Do this **before** loading any project files — it is cheap and prevents wasting the user's time on work they can't ship.

1. **Read target from manifest.** Load `${input:agent_path}/agent-capabilities.yaml`. If it has a populated `target:` block (written by `/plan-agent` Step 0a), use those values — do NOT re-prompt. If `target` is missing or has any empty field, run the same elicitation flow as `/plan-agent` Step 0a (sub picklist → RG picklist → account+project picklist) and stamp the result back into the manifest. The `${input:resource_group}` argument is an explicit override that wins over the manifest — if used, ask the user once to confirm before overwriting.
2. **Caller role check.** Run:
   ```bash
   .agents/skills/foundry-roles/scripts/preflight-role.sh prepare-deploy \
       <target.subscription> <target.resource_group> <target.foundry_account>
   ```
   If exit non-zero, print the runbook (`runbook-emit.sh prepare-deploy ...`) and STOP. Required minimums: `Contributor` on the account RG (for `azd up`) and `Azure AI Developer` on the project (for env-var management). The Foundry MCP gates and post-deploy RBAC steps need additional roles — those are checked at Step 2.4 (model-deploy, conditional) and `/configure-rbac` (Phase 2).
3. **azd + `azure.ai.agents` extension preflight.** Verify `azd` is on PATH and the agent extension is at least `0.1.27-preview`. Earlier versions (e.g. `0.1.25-preview`) use the **deprecated Azure Container Apps backend** and will fail later at Step 6's `azd up` against the current hosted-agents control plane.
   ```bash
   # azd CLI must be installed.
   azd version >/dev/null 2>&1 || { echo "ERROR: azd CLI not on PATH — install: https://aka.ms/install-azd"; exit 1; }

   # azure.ai.agents extension must be installed.
   ext_line=$(azd ext list 2>/dev/null | grep -E '^[[:space:]]*azure\.ai\.agents\b') \
     || { echo "ERROR: azd ai agent extension not installed — run: azd ext install azure.ai.agents"; exit 1; }

   # Minimum version 0.1.27 (the first build on the refreshed hosted-agents backend).
   ext_ver=$(echo "$ext_line" | awk '{print $2}')
   required="0.1.27"
   [ "$(printf '%s\n%s\n' "$required" "$ext_ver" | sort -V | head -1)" = "$required" ] \
     || { echo "ERROR: azd ai agent $ext_ver is below required ${required}-preview — run: azd ext upgrade azure.ai.agents"; exit 1; }
   ```
   On failure, print the recovery command shown in the error and STOP — do not fall through to Step 1.

✅ **Checkpoint.** `target.*` is populated, the caller has the Phase 1 role minimums, and `azd` + `azure.ai.agents` ≥ `0.1.27-preview` are installed.

---

## Step 1 — Detect agent kind

Inspect `${input:agent_path}`:

| If you see... | Kind | Go to |
|---|---|---|
| `agent.yaml` with `kind: hosted` (or `Dockerfile` + `main.py`) | **Hosted (container)** | Track H |
| `agent-definition.yaml` (or `agent.yaml` with `kind: prompt`), no Dockerfile | **Prompt (definition-only)** | Track P |
| Both / neither / ambiguous | STOP | Ask user which they intended; offer to re-run `/plan-agent` |

State the detected kind back to the user before continuing.

---

## Track H — Hosted agent preflight

Validate every item below. Report a checklist (✅/❌). On any ❌, print the fix and STOP.

### H1. `agent.yaml` (ContainerAgent schema)

- [ ] Top-level `kind: hosted` (NOT nested under `template:`)
- [ ] `protocols[].version` is semver `1.0.0` (NOT `"v1"`)
- [ ] `resources` is a flat object `{cpu, memory}` (NOT a list)
- [ ] `environment_variables` includes `MODEL_DEPLOYMENT_NAME`, `ENABLE_INSTRUMENTATION=true`, `ENABLE_SENSITIVE_DATA=true`
- [ ] No reserved-prefix vars set (`FOUNDRY_*`, `AGENT_*`, `APPLICATIONINSIGHTS_*`) — those are platform-injected
- [ ] Schema reference comment present (`# yaml-language-server: $schema=...ContainerAgent.yaml`)

### H2. `Dockerfile`

- [ ] Base `python:3.12-slim`
- [ ] `EXPOSE 8088`
- [ ] `CMD` runs `python main.py` (or `.venv/bin/python container.py` if uv-based)
- [ ] No hard-coded credentials in `ENV`

### H3. `requirements.txt` / `pyproject.toml`

- [ ] `agent-framework>=1.2.2` (or `>=1.1.0` if pyproject pinning)
- [ ] `agent-framework-foundry-hosting==1.0.0a260429` (or matching alpha)
- [ ] `azure-identity>=1.19.0,<1.26.0a0` (avoid 1.26.0b2 beta)
- [ ] If using uv: `[tool.uv] prerelease = "if-necessary-or-explicit"` (NOT `"allow"`)

### H4. `main.py` / entrypoint

- [ ] Uses `FoundryChatClient` + `Agent` + `ResponsesHostServer(agent).run()`
- [ ] `default_options={"store": False}` set
- [ ] `DefaultAzureCredential()` (NOT `AzureKeyCredential`)
- [ ] Reads `FOUNDRY_PROJECT_ENDPOINT` / `MODEL_DEPLOYMENT_NAME` from env (auto-injected)
- [ ] Tools (if any): `@tool(approval_mode="never_require")`, return `str`, never raise
- [ ] No `from_agent_framework`, no top-level `asyncio.run(...)` of the server

### H5. Self-contained build context

- [ ] No imports from sibling agent folders or shared parents
- [ ] Reference data baked into `./data/` (if used)

---

## Track P — Prompt agent preflight

### P1. `agent-definition.yaml` (or `agent.yaml` with `kind: prompt`)

- [ ] `kind: prompt` (or top-level prompt-agent schema)
- [ ] `model.name` matches a deployment in the target Foundry project (validated in Step 2)
- [ ] `instructions` non-empty
- [ ] `tools[]`: each entry is one of `web_search_preview`, `code_interpreter`, `file_search`, `memory_search`, or `type: mcp` with a valid `server_url` (must be a real `https://...` URI, NOT an unresolved `${VAR}`)
- [ ] No `Dockerfile`, no `main.py` (those would be ignored — flag if present so user understands)

---

## Step 2 — Foundry resource validation (Azure MCP)
Both tracks need this. **Read values from `agent-capabilities.yaml` `target:` first** — only re-prompt if a field is missing or the user explicitly asked to change something.

1. **Subscription / resource group / Foundry account / project** — already established in Step 0. If for any reason a value is still missing here, run the same picklist flow (`mcp_azure_mcp_subscription_list` → `mcp_azure_mcp_group_list` → `mcp_azure_mcp_foundry` accounts.list → projects.list). **Wait for the user's explicit selection at every picklist — never auto-pick the first row, even if it's the only one.**
2. **Capture the project endpoint** for use in subsequent steps.
3. **ACR** (Track H only): list registries in the RG via `mcp_azure_mcp_acr` (or `mcp_azure_mcp_group_resource_list`). Show as picklist; **wait for selection**. Capture name. (Used only for `azure.yaml` validation in Step 3 — we do **not** build here.)

### Step 2.4 — Model deployment validation + 3-way fork (REWRITTEN)

Follow [`foundry-deploy/model-selection.md`](../skills/foundry-deploy/model-selection.md) Step 4 (validate-or-fork). Summary:

1. Resolve the candidate name: `model.deployment_name` from `agent-capabilities.yaml` (Track H + Track P after `/plan-agent` Step 0b). Fall back to `MODEL_DEPLOYMENT_NAME` in `agent.yaml` env-vars (Track H legacy) or `model.name` in `agent-definition.yaml` (Track P legacy) — print a warning when falling back, since the manifest should be the source of truth post-`/plan-agent` v0.19.
2. Call `mcp_foundry_mcp_model_deployment_get` with `subscription`, `resource-group`, `account`, `deploymentName` from `target`.
   - **200 OK** → Cross-check `properties.model.name` against `model.catalog_name` (warn on mismatch, don't block). ✅ continue to Step 2.5.
   - **404** → Render the 3-way fork verbatim and **wait for input**:
     - **(a)** Pick a different existing deployment → jump to `model-selection.md` Step 1 (list existing). Re-stamp `model:` block. Re-enter Step 2.4 with new name.
     - **(b)** Deploy `<catalog_name>` now → follow `model-selection.md` Step 5 in full: `preflight-role.sh model-deploy ...` → `mcp_foundry_mcp_model_quota_list` → explicit `y/N` consent → `mcp_foundry_mcp_model_deploy` → poll until `Succeeded`. Re-stamp `model:` block. Re-enter Step 2.4 to reconfirm.
     - **(c)** Print runbook (`runbook-emit.sh model-deploy ...`) and STOP — user re-runs `/prepare-deploy` after the operator confirms creation.
3. **Forbidden shortcuts** (these cause real-world bugs and have been seen in the field):
   - Do NOT silently echo a model name from a recipe or fixture as if it existed in the user's account.
   - Do NOT `python -c "import requests..."` or `curl https://management.azure.com/...` to scrape deployments — use the MCP tools listed above.
   - Do NOT auto-pick fork (b) without the explicit `y/N` checkpoint.

Print a summary table and ask:

> Target: subscription=**<sub>** rg=**<rg>** account=**<acct>** project=**<proj>** model=**<deployment>** acr=**<acr>**. Correct?

## Step 2.5 — Read `agent-capabilities.yaml` and dispatch per-capability preflight

Load `${input:agent_path}/agent-capabilities.yaml`. If missing, treat the agent as having no declared capabilities (toolbox/fabric/teams/guardrails/purview gates skipped) and warn the user that the agent will deploy without any capability gates.

Validate `agent_kind` matches the kind detected in Step 1. If mismatch, STOP.

**Initialize agent-status.json** (idempotent — no-op if it already exists):

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py init \
  --agent-path ${input:agent_path} \
  --agent-name <name from agent.yaml> \
  --agent-kind <hosted|prompt>
```

For each declared block, dispatch to the matching skill's **Preflight (Phase A)** section:

| If manifest declares… | Run | Skill |
|---|---|---|
| `toolbox.enabled` or `toolbox.mcp_servers[]` | URL/connection validation | **foundry-deploy** § "External MCP Server as a Tool" + `capabilities-manifest.md` |
| `knowledge.sources[]` | Per-source brownfield scan (optional) + caller RBAC + network-class compatibility | **foundry-knowledge** § "Phase A" + `scripts/scan_knowledge_refs.py` + `scripts/verify-source-rbac.sh` + `scripts/verify-source-network.sh` |
| `fabric.enabled` | Workspace + items + role record | **foundry-fabric** § "Preflight" |
| `workiq_teams.enabled` | License + bot app + WorkIQ connection | **foundry-teams-workiq** § "Prerequisites — Preflight gate" |
| `guardrails.enabled` | Middleware wiring + CS connection | **foundry-guardrails** § "Preflight" |
| `purview.enabled` | License + toggle + DLP preview ack | **foundry-purview** § "Preflight" |
| `network.class != public` | Run all four network detection scripts | **foundry-prod-readiness/networking.md** |

**`deep_network` flag handling.** When `${input:deep_network} == "true"` AND `network.class != public`, also pass `--deep <agent_subnet_id> [<firewall_id>] <canonical_fqdns...>` to [`check-source-network.sh`](../skills/foundry-prod-readiness/scripts/network/check-source-network.sh) for every declared `knowledge.sources[]`. Pull `<agent_subnet_id>` from `network.byo_vnet.subnet_id` (or report SKIPPED for managed-VNet; we cannot inspect Microsoft's subnet). Pull `<firewall_id>` from `network.byo_vnet.firewall_id` if present (optional). Cascade these canonical FQDNs as the FQDN allowlist:

- `login.microsoftonline.com`
- `*.identity.azure.net`
- `<target.foundry_account>.services.ai.azure.com`
- For each `knowledge.sources[]`: the per-source FQDN (e.g. `<search>.search.windows.net`, `<storage>.blob.core.windows.net`)

Stamp the deep verdicts into `agent-status.json` under `network.sources.<id>.deep_*` (additive — keep the fast-path verdict). If `DEEP_NSG_VERDICT=deny` or `DEEP_FIREWALL_MISSING_FQDNS` is non-empty or `DEEP_SEP_FOUNDRY_AFFECTED=true`, STOP with a pointer to [`network-troubleshooter.md`](../skills/foundry-prod-readiness/network-troubleshooter.md) — these are blockers, not warnings.

Report one combined checklist:
```
Capability gates:
  toolbox      ✅ (3 mcp servers, all URLs valid)
  knowledge    ✅ (2 sources: hr-policies foundry_iq, kb-direct ai_search_direct; both reachable, RBAC plan recorded)
  fabric       ✅ (workspace 'sales-analytics' exists, role=Member recorded for post-deploy)
  guardrails   ✅ (middleware mode=entry, CS connection 'cs-prod' exists)
  purview      ⚠  (toggle status unknown — verify portal manually)
  workiq_teams ❌  Agent 365 license missing — STOP
  network      ✅ (managed_vnet, ACR public access Enabled, kb-prod reachable_via_pe)
```

If any ❌, STOP. If only ⚠, ask the user to confirm continuing.

**Stamp preflight + network into `agent-status.json`** (use the helper, never `jq`):

```bash
# Per-capability preflight verdicts (build the JSON from the checklist above)
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section preflight \
  --json '{"capabilities": {"toolbox": {"verdict":"pass","detail":"..."}, ...}, "checked_at":"<now>"}'

# Network detection results (from the four scripts; see network block schema in agent-status-schema.md)
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section network \
  --json '{"class":"public","region":"<region>","foundry":{...},"sources":{...}}'

# Baseline the capability hash so /verify-agent can detect drift later.
python .agents/skills/foundry-deploy/scripts/agent_status.py drift \
  --agent-path ${input:agent_path}
```

---

## Step 3 — `azure.yaml` (azd ai agent extension)

Look for `azure.yaml` at the **repo root** (not inside the agent folder).

### If missing

Tell the user:
> No `azure.yaml` at repo root. The `azd ai agent` extension generates it on `azd init`. Run:
> ```bash
> azd init --template minimal
> azd env set AZURE_TENANT_ID <tenant>
> ```
> Then re-run `/prepare-deploy`. Optionally I can scaffold a minimal `azure.yaml` for you now — confirm.

If user confirms, scaffold using the template in **foundry-deploy** / `reference/SKILL.md` § "azure.yaml". Fill in: project name, location, model name + version (look up version via `az cognitiveservices account list-models`), capacity 120 GlobalStandard, `infra: { provider: bicep, path: ./infra }`. **Do not author the Bicep yourself** — the `azd ai agent` extension creates `./infra/` on first `azd up`.

### If present

Validate:
- [ ] `services.<svc>.host: containerapp` (Track H) or appropriate host (Track P)
- [ ] `services.<svc>.project: ./agents/<name>` matches `${input:agent_path}`
- [ ] `services.<svc>.config.deployments[].model.name` matches what we validated in Step 2.4
- [ ] `infra.provider: bicep`, `infra.path: ./infra` exists
- [ ] **Bicep params** (in `./infra/main.parameters.json` or `./infra/main.bicep`):
  - `ENABLE_HOSTED_AGENTS = true`
  - `ENABLE_CAPABILITY_HOST = false` ⚠️ (must be false in refreshed preview)
  - `ENABLE_MONITORING = true`

---

## Step 4 — RBAC preflight (recap — see Step 0)

The caller-role minimums (`Contributor` on RG, `Azure AI Developer` on project, `AZURE_TENANT_ID` set) were already enforced in Step 0. If Step 2.4 took fork (b) it ALSO enforced `Cognitive Services Contributor` at that point. No additional preflight is required here.

The **agent identities** (instance + blueprint) and **project MI** RBAC are auto-assigned by the `azd ai agent` postdeploy hook — those happen *after* `azd up`, not now. The capability-specific grants (Fabric workspace role, CS access, knowledge sources) are applied by `/configure-rbac` post-deploy.

---

## Step 5 — `apm audit`

```bash
apm audit
```

If audit reports critical findings (hidden Unicode, prompt-injection, unauthorized sources), STOP and surface them. Do not proceed to `azd up` with a failing audit.

---

## Step 6 — Hand off to `azd up`

Print a final summary:

```
✅ Hosted agent project ${input:agent_path} is azd-ready.
   Track:        Hosted (container)         [or: Prompt (definition-only)]
   Project:      <project> in <rg>
   Model:        <model> (deployment exists)
   ACR:          <acr>                       [Track H only]
   azure.yaml:   ✅
   apm audit:    clean
   RBAC (you):   Project Manager + Contributor

Run `azd up` now? [y/N]
```

- If **y**: execute `azd up` in the repo root. Stream output. Watch for:
  - `provision` failures → surface Bicep error verbatim, suggest **foundry-failure-modes** lookup
  - `azd ai agent` extension errors → check `ENABLE_CAPABILITY_HOST=false`, model deployment, region availability
  - `postdeploy` RBAC errors → tell user to run `/configure-rbac` and then `azd deploy <service>`
  - On success: print Phase B reminder (below).
- If **N** or no: print the exact `azd up` command, and the Phase B reminder.

### Phase B reminder (always printed)

```
Post-deploy steps remaining:
  1. /configure-rbac agent_path=${input:agent_path}
     — applies capability-aware grants (Fabric workspace role, CS access, etc.)
  2. (if workiq_teams declared) Manual: Teams Admin Center upload + M365 Admin → Agents → register in Agent 365
  3. /verify-agent agent_name=<name>
     — per-capability smoke tests
  4. /setup-evals agent_name=<name>
     — continuous eval schedule (evaluators auto-selected from manifest)
```

> APM never runs `az acr build` or POSTs to `/agents/{name}/versions` directly. The `azd ai agent` extension owns image build, agent create, and version create — that is its single source of truth.
