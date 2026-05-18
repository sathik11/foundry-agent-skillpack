# Model selection — single source of truth

Used by `/plan-agent` Step 0b (fresh selection while writing the manifest) and `/prepare-deploy` Step 2.4 (validation pass after the manifest exists). Both prompts MUST follow this algorithm — never invent or echo example model names from other skills.

## Anti-synthesis guard (read first)

When the user has not yet picked a model, the agent MUST NOT:

- **Fabricate** a list of "common" models (e.g. "we usually use gpt-4o, gpt-4o-mini, …").
- **Echo** model names from sample agents in `langgraph-byo/`, `foundry-iq.md`, or any recipe.
- **Shell out** with `python -c`, `curl https://management.azure.com/...`, or any ad-hoc HTTP call to enumerate deployments. The skillpack has approved MCP tools for this — use them.
- **Guess** that a deployment exists. Always confirm via the per-name `mcp_foundry_mcp_model_deployment_get` (returns `404` if absent).

If the user passes an explicit `model=<name>` argument, skip directly to Step 4 (validate-or-fork).

## Algorithm

### Step 1 — List existing deployments in `target.foundry_account`

```text
mcp_azure_mcp_foundry  (action: deployments.list)
  subscription:    <target.subscription>
  resourceGroup:   <target.resource_group>
  account:         <target.foundry_account>
```

> **Why Azure MCP and not Foundry MCP?** Foundry MCP exposes per-name `model_deployment_get` (404 on miss) but no list-by-account. The Azure MCP `foundry` extension fills the gap today; we'll switch when Foundry MCP ships native list (tracked as TD-18).

Render the result as a numbered picklist with: `name`, `model.name (catalog id)`, `model.version`, `sku.name`, `sku.capacity`. Append two synthetic options:

```
N+1) Pick a different catalog model (deploy a new one)
N+2) Cancel — I'll provision the model out-of-band
```

**Wait for the user's selection.** Do not auto-pick the first row even if it's the only one.

### Step 2 — If user picked an existing deployment

Write to the manifest:

```yaml
model:
  catalog_name:    <model.name from picklist>
  deployment_name: <name from picklist>
  version:         <model.version>
  sku_name:        <sku.name>
  capacity:        <sku.capacity>
```

Done. Skip the rest.

### Step 3 — If user picked "deploy a new one"

Show the catalog picklist:

```text
mcp_foundry_mcp_model_catalog_list
  publisher:   OpenAI       # default; user can broaden
  task:        chat-completion
  free_text:   <optional, e.g. "mini" or "reasoning">
```

Render numbered options with: `name`, `version`, `publisher`, `summary` (truncated to 80 chars). Wait for selection.

### Step 4 — Validate-or-fork (also entry point for `/prepare-deploy` Step 2.4)

Given a candidate `model.deployment_name`:

```text
mcp_foundry_mcp_model_deployment_get
  subscription:   <target.subscription>
  resourceGroup:  <target.resource_group>
  account:        <target.foundry_account>
  deploymentName: <model.deployment_name>
```

- **200 OK** → Deployment exists. If running from `/prepare-deploy`, sanity-check `model.catalog_name` matches the response's `properties.model.name`; warn (don't block) on mismatch. ✅ continue.
- **404** → Three-way fork. Render this menu **verbatim** and wait for input:

```
Model deployment '<name>' not found in account '<account>'.

(a) Pick a different existing deployment   — re-run Step 1
(b) Deploy '<catalog_name>' now            — requires Cognitive Services Contributor on the account
(c) Print runbook for someone else to deploy — STOPs here, you re-run /prepare-deploy after they confirm

Choose [a/b/c]:
```

### Step 5 — Fork (b): deploy with consent

Preflight gates **in this order** — abort to fork (c) if any fails:

1. **Caller role.** Run `.agents/skills/foundry-roles/scripts/preflight-role.sh model-deploy <subscription> <resource-group> <account>`. If it exits non-zero, render the runbook (`runbook-emit.sh model-deploy …`) and ask the user to choose (a) or (c).
2. **Quota.** `mcp_foundry_mcp_model_quota_list subscription=… location=<target.region>` → confirm available TPM ≥ requested `capacity` (default 120 thousand). If short, suggest reducing `capacity` or picking a different region.
3. **Explicit consent.** Render the exact request and wait for `y/N` (default N — empty / unrecognized response = abort to fork (a)):

   ```
   About to create deployment in <subscription> / <resource-group> / <account>:
     name:        <deployment_name>
     model:       <catalog_name> @ <version>
     sku:         <sku_name>
     capacity:    <capacity> (TPM × 1000)
   This is a write operation. Proceed? [y/N]:
   ```

On `y`:

```text
mcp_foundry_mcp_model_deploy
  subscription:    <target.subscription>
  resourceGroup:   <target.resource_group>
  account:         <target.foundry_account>
  deploymentName:  <deployment_name>
  modelName:       <catalog_name>
  modelVersion:    <version>
  modelSource:     OpenAI
  skuName:         <sku_name>
  skuCapacity:     <capacity>
```

Poll `mcp_foundry_mcp_model_deployment_get` until `properties.provisioningState == 'Succeeded'` (typical: 30–90 s). Write to manifest as in Step 2. ✅ continue.

### Step 6 — Fork (c): print runbook

Emit the operator runbook (do not run it):

```bash
.agents/skills/foundry-roles/scripts/runbook-emit.sh model-deploy \
  --subscription <sub> --resource-group <rg> --account <account> \
  --deployment-name <name> --catalog-name <catalog> --sku <sku> --capacity <capacity>
```

STOP. The skillpack exits cleanly. The user re-invokes `/prepare-deploy` after the operator confirms creation.

## Why this lives here, not inline in each prompt

- Two prompts (`/plan-agent` Step 0b and `/prepare-deploy` Step 2.4) need exactly the same forks. Keeping them in one document means a fix lands in one place.
- The "anti-synthesis guard" was the root cause of a real bug — silent RG inference + Python/curl scraping of the MCP cache. Calling it out at the top of the algorithm makes it impossible to miss.
- Tool boundaries are bright: `mcp_azure_mcp_foundry` for list (until TD-18 closes), `mcp_foundry_mcp_*` for everything else. Nothing else.
