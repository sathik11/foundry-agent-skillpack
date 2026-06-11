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

1. **Read target + operator mode from manifest.** Load `${input:agent_path}/agent-capabilities.yaml`. Read `operator_mode` (default `true` if absent) and export it as `OPERATOR_MODE` for all downstream scripts. If the manifest has a populated `target:` block (written by `/plan-agent` Step 0a), use those values — do NOT re-prompt. If `target` is missing or has any empty field, run discovery:
   ```bash
   .agents/skills/foundry-deploy/scripts/discover-target.sh <subscription_id> <resource_group>
   ```
   This discovers account, project, ACR, and model in one call. Stamp results into the manifest. The `${input:resource_group}` argument is an explicit override that wins over the manifest — if used, ask the user once to confirm before overwriting.
2. **Batch caller role check.** Run:
   ```bash
   .agents/skills/foundry-roles/scripts/preflight-roles.sh prepare-deploy \
       <target.subscription> <target.resource_group> <target.foundry_account> <target.project>
   ```
   If exit non-zero, print the emitted runbook(s) and STOP. The `PREFLIGHT_MISSING` key lists exactly which roles are missing. Required minimums: `Contributor` on the RG (for `azd up`) and `Foundry Project Manager` on the project (for hosted-agent create + version env-var writes; previously `Azure AI Developer` was listed here, which Microsoft Learn explicitly calls insufficient for hosted agents — see TD-30).
3. **azd + `azure.ai.agents` extension preflight (one call).** Run the bundled preflight script. It checks `azd`, `azure.ai.agents` extension, `az` CLI, login state, AND (for `deploy_mode: code`) the `--deploy-mode code` flag support — emitting structured KV and a single `RECOVERY=...` line on failure. Floors are read from `.agents/skills/foundry-deploy/versions.yaml`. **Do not** shell out to `azd version` / `azd ext list` / `azd ai agent init --help` directly — the script handles all of that with one approval.

   ```bash
   DEPLOY_MODE=$(yq -r '.deploy_mode // "container"' ${input:agent_path}/agent-capabilities.yaml)
   .agents/skills/foundry-deploy/scripts/preflight-azd.sh --deploy-mode "$DEPLOY_MODE"
   ```

   Exit `0` = pass. Exit `2` = parse the emitted `FAIL_REASON=...` + `RECOVERY=...`, print the recovery command verbatim, and STOP. Do not fall through to Step 1.

✅ **Checkpoint.** `target.*` is populated, the caller has the Phase 1 role minimums, and `azd` + `azure.ai.agents` ≥ `0.1.27-preview` are installed.

---

## Step 1 — Detect agent kind + deploy mode

Inspect `${input:agent_path}`:

| If you see... | Kind | Deploy mode | Go to |
|---|---|---|---|
| `agent.yaml` with `kind: hosted` + `Dockerfile` + `agent-capabilities.yaml deploy_mode: container` (or absent) | **Hosted (container)** | container | Track H-Container |
| `agent.yaml` with `kind: hosted` + `agent-capabilities.yaml deploy_mode: code` + `main.py` (or `*.csproj`) + `requirements.txt` (or `*.csproj`) + **NO Dockerfile** | **Hosted (code-zip, preview)** | code | Track H-Code |
| `agent-definition.yaml` (or `agent.yaml` with `kind: prompt`), no Dockerfile, no code: block | **Prompt (definition-only)** | n/a | Track P |
| Both / neither / ambiguous (e.g. `deploy_mode: code` AND a Dockerfile present, or `deploy_mode: code` AND `code:` block missing required fields) | STOP | n/a | Ask user which they intended; offer to re-run `/plan-agent` |

State the detected kind **and** deploy mode back to the user before continuing. For code-deploy, also state the `code.runtime` + `code.dependency_resolution` values.

---

## Track H-Container — Hosted (Docker image) agent preflight

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

## Track H-Code — Hosted (source-code zip, preview) preflight

> Triggered when Step 1 sees `agent-capabilities.yaml deploy_mode: code`. Read [foundry-deploy/code-deploy.md](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-deploy/code-deploy.md) for the full preview surface. All gates below MUST be ✅ before continuing — on any ❌, print the fix and STOP.

### H6. `agent-capabilities.yaml` (`code:` block)

- [ ] `deploy_mode: code`
- [ ] `code.runtime` ∈ {`python_3_13`, `python_3_14`, `dotnet_10`} — earlier versions are NOT supported on preview
- [ ] `code.entry_point` present (Python: file path e.g. `main.py`; .NET: published assembly e.g. `MyAgent.dll`)
- [ ] `code.dependency_resolution` ∈ {`remote_build`, `bundled`}
- [ ] `code.protocol` ∈ {`responses`, `invocations`}
- [ ] NO sibling `Dockerfile` in `${input:agent_path}` (mutually exclusive with `deploy_mode: code`)

### H7. Zip layout

- [ ] Build the zip (or use the existing `agent-code.zip`) and verify its top level is **flat**: `unzip -l agent-code.zip | head -20` must NOT show a single common prefix folder. Most common bug: `agent-code.zip → my-agent/main.py` instead of `agent-code.zip → main.py`.
- [ ] `entry_point` file exists at the zip root (Python) or matches the published assembly name (.NET).
- [ ] Zip size ≤ 250 MB (multipart upload limit). `ls -lh agent-code.zip`.

### H8. Dependency strategy

If `dependency_resolution: remote_build`:
- [ ] `requirements.txt` (Python) or `*.csproj` (.NET) present at the zip root
- [ ] No `packages/` (Python) or `publish/` (.NET) directory shipped — that's the `bundled` shape

If `dependency_resolution: bundled`:
- [ ] **Python**: `packages/` directory present and contains **extracted modules** (e.g. `packages/azure/identity/__init__.py`), NOT raw `.whl` files. If `find packages -name '*.whl'` returns anything, STOP — rebuild with `pip install -r requirements.txt --target packages/ --platform manylinux2014_x86_64 --python-version <matches code.runtime> --implementation cp --only-binary=:all:`.
- [ ] **.NET**: zip contents look like `dotnet publish -c Release -r linux-x64 --self-contained false` output (i.e. `.dll` + `.runtimeconfig.json` at root).

### H9. Runtime matches `code.runtime`

- [ ] If `code.runtime == python_3_13`: any local `.python-version` or `pyproject.toml` Python requirement is compatible with 3.13. If `code.runtime == dotnet_10`: `*.csproj` `<TargetFramework>` is `net10.0`.

### H10. azd extension supports `--deploy-mode code`

Step 0's `0.1.27-preview` floor covers most callers. If `azd ai agent init --deploy-mode code --help` returns an "unknown flag" error, the local extension predates the code-deploy preview — STOP and run `azd ext upgrade azure.ai.agents`.

### H11. Caller-side SDK floor (only if you run code-deploy helpers locally)

The skillpack's default caller-side floor is `azure-ai-projects>=2.0.0,<3`. For machines that invoke `project.beta.agents.create_version_from_code` / `download_code` directly (i.e. running CI helpers for the code-deploy path), bump to `>=2.2.0,<3` and build the client with `allow_preview=True`. See [foundry-deploy/runtime-dependencies.md § Caller-side dependencies](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-deploy/runtime-dependencies.md#caller-side-dependencies).

✅ **Checkpoint.** Manifest `code:` block is valid, zip layout is flat at root with the right shape for the chosen `dependency_resolution`, runtime matches, and azd extension supports the flag.

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

1. **Subscription / resource group / Foundry account / project** — already established in Step 0 (via `discover-target.sh`). If for any reason a value is still missing, re-run discovery or use MCP picklists as fallback.
2. **Capture the project endpoint** for use in subsequent steps.
3. **ACR** (Track H only): if `ACR_NAME` was populated by `discover-target.sh`, use it. Otherwise list registries via `mcp_azure_mcp_acr` and show a picklist. (Used only for `azure.yaml` validation in Step 3 — we do **not** build here.)

### Step 2.4 — Model deployment validation

If `MODEL_DEPLOYMENT_NAME` was already populated by `discover-target.sh` or `/plan-agent` Step 0b (via `select-model.sh`), validate it exists:

Call `mcp_foundry_mcp_model_deployment_get` with the deployment name from the manifest.
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

**Cached topology cross-check (additive — opt-in).** If `./assessment/project-topology.json` exists in the current working directory (typically because the user ran `/assess-project` earlier), load it and cross-check declared capabilities against observed topology. For each warning case below, print a one-line warning but do NOT block:

- `agent-capabilities.yaml` declares `knowledge.sources[]` of type `ai_search` but the topology JSON has no `AzureAISearch` connection → ⚠ "declared AI Search source has no matching connection on project — `/configure-rbac` will likely emit a runbook".
- Topology JSON has `capabilityHosts[]` bound (memory / thread / vector) but `agent-capabilities.yaml` does NOT mention them → ⚠ "project has bound capability hosts that this agent does not declare; agents on the same project share thread / vector state — confirm this is intentional".
- Topology JSON `NETWORK_CLASS` mismatches `network.class` in the manifest → ⚠ "manifest claims `<x>` but observed topology is `<y>` — re-run `/assess-project` if the project changed".

Stamp the cross-check verdict (`matched` / `mismatch_warned` / `no_cached_topology`) into `agent-status.json` under `preflight.topology_crosscheck` (additive — see [agent-status-schema.md](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-deploy/agent-status-schema.md)). If no cached topology exists, skip silently — this is opt-in and `/assess-project` is not a hard prerequisite for `/prepare-deploy`.

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

**`deep_network` flag handling.** When `${input:deep_network} == "true"` AND `network.class != public`, also pass `--deep <agent_subnet_id> [<firewall_id>] <canonical_fqdns...>` to [`check-source-network.sh`](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/scripts/network/check-source-network.sh) for every declared `knowledge.sources[]`. Pull `<agent_subnet_id>` from `network.byo_vnet.subnet_id` (or report SKIPPED for managed-VNet; we cannot inspect Microsoft's subnet). Pull `<firewall_id>` from `network.byo_vnet.firewall_id` if present (optional). Cascade these canonical FQDNs as the FQDN allowlist:

- `login.microsoftonline.com`
- `*.identity.azure.net`
- `<target.foundry_account>.services.ai.azure.com`
- For each `knowledge.sources[]`: the per-source FQDN (e.g. `<search>.search.windows.net`, `<storage>.blob.core.windows.net`)

Stamp the deep verdicts into `agent-status.json` under `network.sources.<id>.deep_*` (additive — keep the fast-path verdict). If `DEEP_NSG_VERDICT=deny` or `DEEP_FIREWALL_MISSING_FQDNS` is non-empty or `DEEP_SEP_FOUNDRY_AFFECTED=true`, STOP with a pointer to [`network-troubleshooter.md`](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/network-troubleshooter.md) — these are blockers, not warnings.

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

**Stamp preflight + network into `agent-status.json`.** Build ONE composite JSON object for the `preflight` section and ONE for `network`, then issue two `update` calls (not N) — `agent_status.py` is the only writer. Use `--section preflight` / `--section network` with full payloads:

```bash
# One composite preflight stamp (capabilities + per-source verdicts + checked_at).
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section preflight \
  --json '{"capabilities":{"toolbox":{"verdict":"pass"},"knowledge":{"verdict":"pass"},"guardrails":{"verdict":"pass"}},"topology_crosscheck":"matched","checked_at":"<now>"}'

# One composite network stamp (matches schema in agent-status-schema.md).
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section network \
  --json '{"class":"public","region":"<region>","foundry":{...},"sources":{...}}'

# Baseline the capability hash so /verify-agent can detect drift later.
python .agents/skills/foundry-deploy/scripts/agent_status.py drift \
  --agent-path ${input:agent_path}
```

> **Why one call per section?** Each `agent_status.py update` invocation is one approval. Build the full JSON in your head from the checklist results, then issue one `update --section ...` per section. Do **not** loop calling `update --path foo.bar` for each field — that's the v0.26 anti-pattern this version replaces.

---

## Step 3 — Prepare for `azd up` (one approval)

This step **fans out** the v0.26 plumbing (sync azd env vars, run `azd ai agent init`, validate AZURE_LOCATION, validate `azure.yaml`/Dockerfile match) into a single call to `prepare-deploy.sh`. The wrapper:

1. Loads cached topology (if `./assessment/project-topology.json` exists)
2. Re-runs `preflight-azd.sh` to make sure tooling is still floor-compliant
3. **Syncs azd env vars from the manifest** — `AZURE_LOCATION`, `MODEL_DEPLOYMENT_NAME`, `USE_EXISTING_AI_PROJECT=true`, ACR (container mode only) — so `azd up` doesn't ask interactive questions
4. Calls `safe-azd-init.sh` with manifest-derived flags (`--deploy-mode`, `--runtime`, `--entry-point`, `--dep-resolution`, `--location`, `--model-deployment`, `--protocol`)
5. **Validates AZURE_LOCATION matches `target.location`** (FB-20: cross-region `azd up` → `InvalidResourceLocation`)
6. **Validates `azure.yaml` `services.<svc>.language` matches `deploy_mode`** (FB-21: extension silently scaffolds Dockerfile path even when `deploy_mode: code` is declared in the manifest)
7. Stamps everything into `agent-status.json` `preflight` section in one atomic write

```bash
.agents/skills/foundry-deploy/scripts/prepare-deploy.sh ${input:agent_path}
```

**Exit handling:**

- `0` → `PREPARE_DEPLOY=ok` on stdout. Continue to Step 4.
- `2` → `FAIL_STAGE=<name>` on stdout. Parse `RECOVERY=...`, print it verbatim, STOP. Common failures:
  - `FAIL_STAGE=safe-azd-init` + `SAFE_AZD_INIT=dockerfile-conflict` → user declared `deploy_mode: code` but a `Dockerfile` exists in the agent folder. Either delete the Dockerfile or switch to `deploy_mode: container` in `agent-capabilities.yaml`.
  - `FAIL_STAGE=safe-azd-init` + `SAFE_AZD_INIT=schema-mismatch` → `agent.yaml` is in `template:`-wrapper form (AgentManifest) but the extension expects flat ContainerAgent. Use `langgraph-byo` template or hand-author `agent.yaml` per **foundry-deploy** § "ContainerAgent schema".
  - `FAIL_STAGE=validate-azd-env-loc` → `azd` defaulted `AZURE_LOCATION` to the RG location, which differs from `target.location` (the Foundry account/project region). The wrapper already emits the exact `azd env set ...` recovery; run it then re-invoke `prepare-deploy.sh`.
  - `FAIL_STAGE=validate-azure-yaml` → the extension scaffolded `host: containerapp` (or `language: docker`) for a `deploy_mode: code` agent. Edit `azure.yaml` to the manifest-correct values per the printed `RECOVERY_1` / `RECOVERY_2`.
- `3` → wrapper is missing a sibling script; this is a packaging bug — STOP and surface to the user.

**Manual fallback (advanced).** If the user prefers to author `azure.yaml` by hand, see **foundry-deploy** § "azure.yaml" + `reference/SKILL.md`. The Bicep parameter floor still applies:
- `ENABLE_HOSTED_AGENTS = true`
- `ENABLE_CAPABILITY_HOST = false` ⚠️ (azd-extension scaffold default — capability hosts are bootstrapped post-deploy via `/add-capability-host`)
- `ENABLE_MONITORING = true`

---

## Step 4 — RBAC preflight (recap — see Step 0)

The caller-role minimums (`Contributor` on RG, `Foundry Project Manager` on project, `AZURE_TENANT_ID` set) were already enforced in Step 0. If Step 2.4 took fork (b) it ALSO enforced `Cognitive Services Contributor` at that point. No additional preflight is required here.

The **agent identities** (instance + blueprint) and **project MI** RBAC are auto-assigned by the `azd ai agent` postdeploy hook — those happen *after* `azd up`, not now. The capability-specific grants (Fabric workspace role, CS access, knowledge sources) are applied by `/configure-rbac` post-deploy.

---

## Step 5 — `apm audit`

```bash
apm audit
```

**Interpreting the output (FB-19).** `apm audit` is a one-shot prompt-injection / hidden-Unicode / unauthorized-source linter on your customization tree (`.github/prompts/`, `.agents/skills/`, etc.). It does **not** validate your agent code or `azure.yaml`. Expect:

- **`No findings`** → ok, continue.
- **`info` / `warn`** → surface to user, continue unless they ask to address now.
- **`critical`** → STOP. Critical findings (zero-width / RLO Unicode, base64-blobs that decode to prompts, sources not in the install set) signal an active supply-chain risk. Do not proceed to `azd up`. Run `apm audit --explain <finding-id>` for the per-finding remediation.

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

- If **y**: execute `azd up` in the repo root. Stream output. Classify failures **before** punting to **foundry-failure-modes**:
  - **`InvalidResourceLocation` / `LocationNotAvailableForResourceType`** → cross-region mismatch. `azd` env `AZURE_LOCATION` is for the resource group, but the manifest `target.location` is for the Foundry account/project. The wrapper's `validate-azd-env-loc` stage should have caught this — if it did not, re-run `.agents/skills/foundry-deploy/scripts/validate-azd-env-location.sh ${input:agent_path}` and follow the printed `RECOVERY`. See **foundry-failure-modes** § FM-XX (cross-region).
  - **`No such file or directory: Dockerfile`** (during `azd deploy` even though `deploy_mode: code` was declared) → `azure.yaml` `services.<svc>.language: docker` is wrong; the extension silently scaffolded the container path. Fix per `validate-azure-yaml.sh` `RECOVERY_*`. See **foundry-failure-modes** § FM-YY (deploy-mode mismatch).
  - **`provision` Bicep errors** → surface verbatim, then suggest **foundry-failure-modes** lookup
  - **`azd ai agent` extension errors** → check `ENABLE_CAPABILITY_HOST=false`, model deployment, region availability
  - **`postdeploy` RBAC errors** → tell user to run `/configure-rbac` and then `azd deploy <service>`
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
