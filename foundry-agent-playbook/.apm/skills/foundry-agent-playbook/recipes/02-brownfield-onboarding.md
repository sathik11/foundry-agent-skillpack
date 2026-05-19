---
validity_date: 2026-05-15
audience: Brownfield (existing Python agent code on your laptop)
duration: ~45 minutes (highly variable — depends on what your code does)
surfaces: [code_scan, manifest_derivation, per_skill_gates, rbac_verify, drift_baseline]
prerequisites:
  - Existing Python agent code (agent-framework, LangGraph, or BYO)
  - Azure subscription + Foundry project
  - azd ≥ 1.24 with `azure.ai.agents` extension
  - `Reader` on the project resource group (for `/plan-agent` Step 0a target picklists)
  - `Contributor` on the project resource group (for `/prepare-deploy` Step 0)
  - `Reader` on every Azure resource your code already references
  - `Cognitive Services Contributor` on the Foundry account *only if* you let `/plan-agent` Step 0b deploy a model for you
---

# Recipe 02 — Brownfield Onboarding

> **Goal:** Take a working agent (Python code on your laptop) and host it on Foundry without breaking what already works. End state: agent runs on Foundry hosted with the same external dependencies it had locally, RBAC verified, drift baseline set.

This recipe is the inverse of greenfield. Greenfield: pick capabilities → scaffold code. Brownfield: **scan code → derive capabilities → reconcile**.

## Surface map

| Surface | What you bring | What the skillpack derives |
|---|---|---|
| Agent runtime | Your existing `main.py` (any framework) | Validates `agent.yaml` shape; fixes if needed |
| Tools / Knowledge | Your existing Azure SDK / MCP / API calls | A draft `knowledge.sources[]` + `toolbox` block — you confirm |
| Outer loop | Whatever you have (or nothing) | RBAC verification per source, drift baseline |

Network: out of scope for this recipe — see [foundry-prod-readiness/networking.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/networking.md).

---

## Step 1 — Stage your code into the skillpack layout

The skillpack expects one folder per agent under `agents/<name>/`. Move your code there if it isn't already:

```bash
mkdir -p agents/<your-name>
cp -r path/to/your-existing-code/* agents/<your-name>/
cd agents/<your-name>
ls
# Should at minimum have: main.py, requirements.txt
# Probably missing: agent.yaml, agent-capabilities.yaml, Dockerfile (those come next)
```

✅ **Checkpoint.** Your existing `main.py` is now under `agents/<your-name>/`. **Don't change it yet.**

---

## Step 2 — Scan for knowledge / tool signals

```bash
python .agents/skills/foundry-knowledge/scripts/scan_knowledge_refs.py \
    --agent-path agents/<your-name>
```

The scanner emits a draft `knowledge.sources[]` block to stdout. Each detected source has TODO placeholders for the user-provided fields (resource IDs, index names, etc.).

✅ **Checkpoint.** You see something like:

```yaml
knowledge:
  sources:
    # ── ai_search_direct (signal from 2 line(s)) ──
    #   main.py:1  (imports azure.search.documents)
    #   main.py:6  (instantiates SearchClient)
    - name: TODO-ai-search-direct
      kind: ai_search_direct
      resource_id: TODO
      index_name:  TODO
      auth: managed_identity

# ── Ambiguous signals (NOT auto-classified) — confirm with user ──
#   main.py:8  BlobServiceClient — could be source data, checkpoint, or sink. Confirm.
```

> **Important honesty.** The scan is regex-only and signals-not-truth. Read every TODO. Read every ambiguous signal. Anything you can't classify becomes either a `knowledge.sources[]` entry (if it's a knowledge source) or stays out of the manifest entirely (if it's app state like Cosmos for sessions).

---

## Step 3 — Author `agent-capabilities.yaml`

Take the scanner output, add your real values, and write the file at `agents/<your-name>/agent-capabilities.yaml`. Minimum shape:

> **Note (v0.19):** if you ran `/plan-agent` first, `target:` and `model:` are already populated by Steps 0a/0b. If you're authoring the manifest by hand, leave them out — `/prepare-deploy` Step 0 will run the same elicitation flow and stamp them in.

```yaml
schema_version: 1
agent_kind: hosted

capabilities:
  knowledge:
    sources:
      - name: kb-prod
        kind: ai_search_direct
        resource_id: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Search/searchServices/kb-prod
        index_name: docs-v2
        auth: managed_identity

  # If the scanner found no knowledge signals, omit the knowledge block entirely.

  network:
    class: public            # or managed_vnet / byo_vnet — pick once, immutable post-deploy
```

If your code references guardrails / Purview / Fabric, add the corresponding blocks (see [capabilities-manifest.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-deploy/capabilities-manifest.md) for the schema).

✅ **Checkpoint.** `agent-capabilities.yaml` exists, with no `TODO` strings remaining.

---

## Step 4 — Generate the missing skillpack files (`agent.yaml`, `Dockerfile`)

Most brownfield code lacks `agent.yaml` and a Foundry-shaped `Dockerfile`. Use the templates as a starting point:

```bash
cp .agents/skills/foundry-deploy/templates/agent.yaml.template agents/<your-name>/agent.yaml
cp .agents/skills/foundry-deploy/templates/Dockerfile.template agents/<your-name>/Dockerfile
```

Substitute `${AGENT_NAME}` and `${AZURE_AI_MODEL_DEPLOYMENT_NAME}` in `agent.yaml`. Adjust the `Dockerfile` `COPY` lines if your code has subdirectories the default template misses.

> **Specifically check:** the template uses `COPY *.py ./`. If your code has `src/` or `agents/` subfolders, change to `COPY . .` or list them explicitly. Missing files at runtime is the #1 brownfield deploy failure.

✅ **Checkpoint.** All five files exist: `main.py`, `requirements.txt`, `agent.yaml`, `agent-capabilities.yaml`, `Dockerfile`.

---

## Step 5 — Preflight (`/prepare-deploy`)

```
/prepare-deploy agent_path=agents/<your-name>
```

What happens:

- **Track H gates** inspect your existing code. Common brownfield ❌s:
  - H3: `azure-identity` unpinned → upper-bound `<1.26.0a0`.
  - H4: middleware not wired (if you declared `guardrails` in the manifest but didn't add it to `main.py`).
  - H4: tool functions don't return `str` or aren't decorated `@tool(approval_mode="never_require")`.
- **Capability gates** per the new manifest:
  - For each `knowledge.sources[]` entry: existence check + caller RBAC plan + network compatibility.
  - The skillpack runs [`verify-source-rbac.sh`](../../../../foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/verify-source-rbac.sh) and reports which Phase B grants are needed.
- **`agent-status.json` created** with `preflight` + `network` sections; baseline `drift.capability_hash_at_preflight`.

For each ❌, fix in the file the prompt names. Re-run until clean.

✅ **Checkpoint.** Final preflight checklist all ✅ or ⚠. STOP at this checkpoint and review every ⚠ — they often hide tenant-specific work (e.g., "AI Search index `docs-v2` doesn't exist yet — create it before deploy").

---

## Step 6 — Deploy

```bash
azd up
```

Same as greenfield from this point. Watch for:

- Brownfield-specific failures: `ImportError` from `from somewhere_outside_agent_folder` — your code must be self-contained inside `agents/<your-name>/`. Move shared code in or refactor.
- `ImageError` after deploy: `Dockerfile` missed a file. Verify with `docker run -it <local-image> ls -la`.

✅ **Checkpoint.** `azd ai agent show` returns `status: active`.

---

## Step 7 — RBAC (`/configure-rbac`)

```
/configure-rbac agent_path=agents/<your-name> agent_name=<your-name>
```

The brownfield case usually has more **Phase 3 grants** than greenfield because real code references real resources:

- AI Search → `Search Index Data Reader` on the search service.
- Storage → `Storage Blob Data Reader` on the account.
- Cosmos → `Cosmos DB Built-in Data Contributor` on the account.

Each grant gets stamped into `agent-status.json` `rbac.capability_grants`. Anything that requires a different persona to execute (Fabric workspace admin, Purview toggle) gets emitted as a runbook in `rbac.pending` instead of being applied.

✅ **Checkpoint.** Open `agent-status.json`. Verify:
- `rbac.phases_completed` includes `phase1_image_pull` + `phase2_runtime`.
- `rbac.capability_grants` has one entry per knowledge/guardrails source the skillpack could grant.
- `rbac.pending` is empty OR contains exactly the items requiring runbook handoff.
- `drift.capability_hash_at_rbac` is set.

> Wait 5–15 minutes for propagation.

---

## Step 8 — Verify + drift baseline (`/verify-agent`)

```
/verify-agent agent_name=<your-name> test_query="<a query that exercises your real workflow>" agent_path=agents/<your-name>
```

The drift check at Step −1 should pass (you just baselined in Step 7).

For each declared `knowledge.sources[]`, the verify step runs a smoke retrieve. Expect:

- A real response grounded in your data.
- An `execute_tool` span per source.
- Citations rendered (if your index has a citation field — see [foundry-knowledge/blob-via-search.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-knowledge/blob-via-search.md)).

✅ **Checkpoint.** Final report shows ✅ for the capabilities you declared. `agent-status.json` `verify.last_run_status: pass`.

---

## Recap — what you proved

| Surface | Evidence |
|---|---|
| Agent runtime | Your existing code runs on Foundry hosted, unmodified except for skillpack-required additions (`agent.yaml`, `Dockerfile`) |
| Knowledge / Tools | Each declared source has caller + per-agent SP RBAC verified |
| Outer loop — RBAC verify | `rbac.capability_grants` documents every grant; `rbac.pending` documents every runbook |
| Outer loop — drift baseline | `drift.capability_hash_at_rbac` set; future `agent-capabilities.yaml` edits are detectable |

## Step 9 — Schedule weekly drift audit

Now that the baseline is set, schedule `/audit-drift` to run weekly so you catch:
- **Forward drift** — someone revoked a role or deleted a connection out-of-band.
- **Reverse drift** — someone added an evaluator or extra MCP server in the portal that isn't in your manifest.

**Manual run** (any time):

```
/audit-drift agent_path=agents/<your-name> agent_name=<your-name>
```

The report is written to `.audit-reports/<your-name>-<YYYY-MM-DD>.md`. Read it; act on the `RECOMMENDATIONS` section. The audit is **read-only** — it never fixes anything; remediation is `/configure-rbac` + `/verify-agent`.

**CI run** (recommended): wire into your CI as a non-blocking weekly job that opens / updates a tracking issue when the report changes. Don't gate PRs on `/audit-drift` results — it queries live state and can change without code edits. Gate PRs on `/verify-agent` instead.

## Common brownfield gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `Module not found` post-deploy | Code imports from outside `agents/<name>/` | Vendor in or refactor; agent folder is the build context |
| 403 from AI Search after RBAC | Per-agent SP propagation not done | Wait 15 min; retry `/verify-agent` |
| Tool span shows API key auth | Code didn't switch to `DefaultAzureCredential` | Update `main.py`; re-deploy (env-var-only redeploy doesn't change code) |
| `agent-status.json` already exists from a prior run | Same agent path, fresh deploy | OK — `init` is idempotent; helper merges sections |
| Scan missed a source you know is there | Regex didn't match (aliased import, conditional, framework-specific) | Add the entry to `agent-capabilities.yaml` manually; the scan is signal-not-truth |

## Where to go next

- Add a Foundry IQ knowledge base on top of what you have → [03-knowledge-with-purview.md](03-knowledge-with-purview.md).
- Regression-set eval before publish → [04-ai-search-with-scheduled-eval.md](04-ai-search-with-scheduled-eval.md).
- Front your MCP servers with APIM → [05-apim-fronted-mcp.md](05-apim-fronted-mcp.md).
- Check network class compatibility for production rollout → [recipes/README.md § Network class testing](README.md).
