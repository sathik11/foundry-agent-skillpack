---
description: Validate a Foundry agent project is azd-ready, run apm audit, then optionally execute `azd up`. Forks on hosted (container) vs prompt (definition-only) agents.
input:
  - agent_path: "Path to the agent folder (e.g. agents/learn-agent or sandbox/learn-agent)"
  - resource_group: "Resource group containing the Foundry project (optional — discovered if omitted)"
mcp:
  - azure
---

# Prepare Deploy: ${input:agent_path}

You are a Foundry Agent Engineer. **APM's job ends at "azd-ready."** This prompt does **not** run `az acr build` or call the Foundry REST control plane — that is `azd up` + the `azd ai agent` extension's job. We validate, audit, and hand off.

Use the **foundry-deploy**, **foundry-identity**, and **foundry-failure-modes** skills.

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
Both tracks need this. Discover and confirm:

1. **Subscription** → `azure subscription_list` (pick if >1).
2. **Resource group** → use `${input:resource_group}` or `azure group_list` picklist.
3. **Foundry project** → list AI Services accounts in that RG; pick one. Capture endpoint.
4. **Model deployment exists**: call `azure model_deployment_get` for the `MODEL_DEPLOYMENT_NAME` (Track H) or `model.name` (Track P). If not found, STOP with:
   > Model deployment `<name>` not found in `<project>`. Either deploy it (`az cognitiveservices account deployment create ...`) or change the model in `${input:agent_path}/agent.yaml`.
5. **ACR** (Track H only): list registries in the RG → pick one. Capture name. (Used only for `azure.yaml` validation in Step 3 — we do **not** build here.)

Print a summary table and ask:

> Target: project=**<proj>** rg=**<rg>** model=**<model>** acr=**<acr>**. Correct?

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

## Step 4 — RBAC preflight (delegate to /configure-rbac if needed)

Confirm the **deploying user** has:
- `Azure AI Project Manager` on the Foundry project
- `Contributor` on the resource group
- `azd env set AZURE_TENANT_ID <tenant>` (otherwise postdeploy auto-RBAC fails silently)

If any missing, STOP and tell the user to run `/configure-rbac` first.

The **agent identities** (instance + blueprint) and **project MI** RBAC are auto-assigned by the `azd ai agent` postdeploy hook — those happen *after* `azd up`, not now.

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
