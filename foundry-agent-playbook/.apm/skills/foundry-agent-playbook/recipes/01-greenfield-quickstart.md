---
validity_date: 2026-05-15
audience: Greenfield (no existing agent code)
duration: ~30 minutes
surfaces: [agent_framework_runtime, public_mcp, middleware_guardrails, continuous_eval]
prerequisites:
  - Azure subscription with a Foundry project
  - azd ≥ 1.24 with `azure.ai.agents` extension
  - `Reader` on the project resource group (for `/plan-agent` Step 0a target picklists)
  - `Contributor` on the project resource group (for `/prepare-deploy` Step 0)
  - `Cognitive Services Contributor` on the Foundry account *only if* you let Step 0b deploy a model for you
---

# Recipe 01 — Greenfield Quickstart

> **Goal:** Stand up a working hosted agent (agent-framework template, Microsoft Learn MCP tool, middleware guardrails, continuous eval) in ~30 minutes. End state: agent answers questions, tool spans flow, continuous eval scores responses on the Monitor dashboard.

You write zero Python in this recipe — the package's templates do the scaffolding. The point is to walk every prompt in the lifecycle once so you know what each one does.

## Surface map

| Surface | Choice |
|---|---|
| Agent runtime | `agent-framework` (default; tightest Foundry integration) |
| Tool | Microsoft Learn MCP (`https://learn.microsoft.com/api/mcp`) — public, no auth |
| Outer loop | Middleware guardrails (Layer 1) + continuous eval |

Network: stay public for this recipe. Network class is documented separately in [foundry-prod-readiness/networking.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/networking.md).

---

## Step 1 — Plan the agent (`/plan-agent`)

```
/plan-agent agent_name=hello-foundry description="Quickstart agent that answers Microsoft Learn questions via the public Learn MCP server."
```

The prompt walks you through:

  - **Step 0a — Target + caller-role preflight.** Picklists for subscription → resource group → Foundry account → project. Then `preflight-role.sh plan-agent ...` confirms you have at least `Reader`. Stamps a `target:` block into `agent-capabilities.yaml`.
  - **Step 0b — Model selection.** Lists existing deployments in your account. If `gpt-4.1-mini` is already deployed, pick it. If not, the prompt offers to deploy it for you (`Cognitive Services Contributor` + quota check + explicit `y/N`) or to print a runbook for someone else.
  - **Track selection.** Pick **B (scaffold from template)**.
  - **Template choice.** Pick **agent-framework** (we'll cover LangGraph BYO in a later recipe).
  - **Capabilities.** Decline knowledge sources (we're using MCP only). Accept guardrails (`middleware`). Accept continuous eval.

✅ **Checkpoint.** You should now have:

```
agents/hello-foundry/
├── Dockerfile
├── agent.yaml
├── agent-capabilities.yaml
├── main.py
├── requirements.txt
├── guardrails.py             ← vendored Layer 1 middleware
└── tools.py                  ← @tool wrappers around the MCP call
```

Open `agents/hello-foundry/agent-capabilities.yaml`. It should look roughly like:

```yaml
schema_version: 1
agent_kind: hosted
target:
  subscription: 11111111-2222-3333-4444-555555555555
  resource_group: agents-eastus2
  foundry_account: agents-eastus2-acct
  foundry_project: hello-foundry-proj
  region: eastus2
model:
  catalog_name: gpt-4.1-mini
  deployment_name: gpt-4.1-mini
  sku_name: GlobalStandard
  capacity: 120
capabilities:
  toolbox:
    enabled: true
    mcp_servers:
  - server_label: microsoft_learn
        url: https://learn.microsoft.com/api/mcp
        require_approval: never
  guardrails:
    enabled: true
    layers: [middleware]
    middleware_mode: entry
  evals:
    role: orchestrator
    judge_model: gpt-4.1-mini
    continuous:
      enabled: true
      sample_rate: 0.5
```

---

## Step 2 — Preflight + deploy (`/prepare-deploy` → `azd up`)

```
/prepare-deploy agent_path=agents/hello-foundry
```

What happens:

  - **Step 0 — Caller-role + target preflight (NEW v0.19).** Reads `target:` from the manifest (no re-prompt) and runs `preflight-role.sh prepare-deploy ...` to confirm `Contributor` + `Azure AI Developer`. Fails fast if missing.
  - **Track H gates** (H1–H5) inspect `agent.yaml`, `Dockerfile`, `requirements.txt`, `main.py` — all should ✅.
  - **Step 2 — Resource validation.** Re-uses `target:` from Step 0; only re-prompts for ACR (Track H).
  - **Step 2.4 — Model deployment validation.** Calls `mcp_foundry_mcp_model_deployment_get` for `model.deployment_name`. 200 ✅. (If 404, you get the same 3-way fork from `/plan-agent` Step 0b: pick / deploy-with-consent / runbook.)
  - **Capability gates** dispatch per the manifest:
  - `toolbox` → ✅ (URL is real)
  - `guardrails` → ✅ (middleware wired in `main.py`, `guardrails.py` present)
  - `evals.continuous` → recorded for Phase B (no preflight action — needs deployed agent first)
  - **`agent-status.json` created** — the durable state file. Open it; you should see `preflight.capabilities.*` populated and `drift.capability_hash_at_preflight` set.

If anything ❌, the prompt prints the exact fix and stops. Apply it and re-run.

When it passes, the prompt offers `azd up`:

```
azd up
```

Watch for:
  - `provision` succeeds (Bicep + Foundry account + project)
  - `deploy` succeeds (image built remotely via ACR Tasks, agent version reaches `active`)

✅ **Checkpoint.** `azd ai agent show` returns:

```yaml
name: hello-foundry
status: active
instance_identity:
  principal_id: <guid>     # ← non-empty
endpoint: https://<acct>.services.ai.azure.com/api/projects/<proj>
```

---

## Step 3 — Apply RBAC (`/configure-rbac`)

```
/configure-rbac agent_path=agents/hello-foundry agent_name=hello-foundry
```

What happens:

  - **Step 1** discovers identities (`PROJECT_MI` + `AGENT_PRINCIPAL`); writes them into `agent-status.json` `identities` section.
  - **Step 2** applies Phase 1 (AcrPull) + Phase 2 (5 runtime roles); stamps `rbac.phases_completed`.
  - **Step 3** capability-aware grants — for this recipe, only `toolbox` is declared (no Phase B grants needed; public MCP doesn't require RBAC). `rbac.pending` should be empty.
  - **Step 4** re-baselines `drift.capability_hash_at_rbac`.

✅ **Checkpoint.** `agent-status.json` `rbac` section shows `phases_completed: ["phase1_image_pull", "phase2_runtime"]`.

> Wait 5–15 minutes for RBAC propagation before Step 4. Coffee break.

---

## Step 4 — Verify (`/verify-agent`)

```
/verify-agent agent_name=hello-foundry test_query="What is Microsoft Foundry?" agent_path=agents/hello-foundry
```

What happens:

  - **Step −1** drift check — capability hash matches RBAC baseline → ✅.
  - **Step 0** stamps `deploy` block with version, endpoint.
  - **Step 1** invokes the endpoint; you should get a response that cites Microsoft Learn.
  - **Step 3** KQL — at least 1 `execute_tool` span with `gen_ai.tool.name = "microsoft_learn"` in the last few minutes.
  - **Step 4** KQL — at least 1 `guardrail.middleware` span (entry-mode middleware fires on every input).
  - **Step 7** stamps `verify` block with `last_run_status: pass`.

✅ **Checkpoint.** Final report shows ✅ across Endpoint, Model, Tools, Guardrails, Traces, and `toolbox` + `guardrails` capability rows.

If `Tools: ❌` (no spans) — confirm `ENABLE_INSTRUMENTATION=true` is on the agent version's env vars.

---

## Step 5 — Wire continuous eval (`/setup-evals`)

```
/setup-evals agent_name=hello-foundry agent_path=agents/hello-foundry
```

What happens:

  - **Step 0** preflights `Azure AI User` on the project.
  - **Step 2** runs `ensure_continuous_eval.py --dry-run` first — review the plan:
  ```
  rule_name:       continuous-eval-hello-foundry
  evaluators:      relevance, task_adherence, indirect_attack, tool_call_accuracy
  sample_rate:     0.5
  judge_model:     gpt-4.1-mini
  ```
  - Confirm; the rule is created idempotently.

✅ **Checkpoint.** Send 2–3 more queries to the agent. Open Foundry portal → your project → `hello-foundry` → **Monitor** tab. Within ~5 minutes, the eval charts populate.

---

## Recap — what you proved

| Surface | Evidence |
|---|---|
| Agent runtime | `azd ai agent show` returns `status: active` |
| Tool (public MCP) | `execute_tool` spans with `gen_ai.tool.name = "microsoft_learn"` |
| Outer loop — guardrails | `guardrail.middleware` spans on every input |
| Outer loop — continuous eval | Eval rule exists + scores appear on Monitor tab |
| State continuity | `agent-status.json` populated across `preflight`, `deploy`, `identities`, `rbac`, `verify`, `drift` |

## Cleanup

```bash
azd down --purge
# Optional: also delete the eval rule
python .agents/skills/foundry-evals/scripts/ensure_continuous_eval.py \
    --project-endpoint <ep> --project-scope <scope> --agent-name hello-foundry --dry-run
# (re-running with --enabled false is the cleanup path; no separate delete script today)
```

## Where to go next

  - Want LangGraph instead? See [`fixtures/langgraph-chat-sample/`](../samples/langgraph-chat-sample/) — same lifecycle, different runtime.
  - Want a knowledge base? See [03-knowledge-with-purview.md](03-knowledge-with-purview.md).
  - Want regression-set evaluation? See [04-ai-search-with-scheduled-eval.md](04-ai-search-with-scheduled-eval.md).
  - Brownfield instead? See [02-brownfield-onboarding.md](02-brownfield-onboarding.md).
