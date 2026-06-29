<!--
  MAINTAINER / CI-ONLY ARTIFACT — DO NOT MOVE UNDER .apm/ AND DO NOT SHIP TO CONSUMERS.
  Audience: repo maintainers + the developer/tester agents that build and maintain this
  skillpack. NOT customer-facing. The customer-facing equivalent is the playbook recipes
  (foundry-agent-playbook/.apm/.../recipes/01-06) and the published docs site.

  This file documents, FOR EACH e2e scenario, the ordered sequence of USER commands that
  the driver executes — the actual "what would a human type, in what order" journey, NOT
  the test-result assertions. Companion to maintenance/AUTOMATION.md §2 (command-order
  graph) and §6 (scenario coverage table).
-->

# E2E Scenario Command Flows

This is the maintainer's map of **what command sequence each tester-track scenario drives** —
the ordered list of user actions (slash commands, scripts, `azd` calls) a human would run for
that journey. It is **not** the assertion list and **not** the pass/fail report; for those see
each scenario's `assertions:` block and the per-run `harness-report.json`.

> **Why this doc exists.** The command sequence *varies per scenario* (greenfield deploy ≠
> brownfield onboarding ≠ APIM front-door). A maintainer triaging a failing run needs to see the
> intended journey at a glance, without reverse-engineering it from the scenario's free-text
> `prompt:` field. This page is that single reference.

---

## Where the command flow is captured (today vs. going forward)

A scenario's command flow lives in **three** places, each at a different fidelity. This matters
because "where is the journey defined?" has historically been ambiguous.

| Layer | Location | Audience | Fidelity |
|---|---|---|---|
| **Customer recipe** | `foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/01-06` (mirrored to the docs site by `docs/scripts/mirror-recipes.mjs`) | Customer | Canonical, prose + checkpoints. The source of truth for *what the journey should be*. |
| **Scenario prompt** | `tests/e2e/scenarios/<NN>-*.yaml` → `prompt:` field | Driver (opencode) + maintainer | Exact, but embedded in a long natural-language instruction the driver follows. Has the precise script paths, args, and target facts. |
| **This doc** | `tests/e2e/SCENARIO-FLOWS.md` (you are here) | Maintainer / tester | Consolidated, skimmable command tables for every scenario in one place. |

**Today (as authored):** the executable command sequence is captured **inline in each
`scenarios/<NN>-*.yaml` `prompt:`** (that is what the driver actually replays), and the
customer-facing version is the matching **playbook recipe**. There is no separate machine-readable
"steps" list — the prompt *is* the steps.

**Going forward:** this `SCENARIO-FLOWS.md` is the consolidated human index. When a new scenario is
added, add a row to maintenance/AUTOMATION.md §6 **and** a command-flow section here, derived from
the scenario's `prompt:` and its source recipe. Keep the three layers in sync: recipe = intent,
scenario `prompt:` = executable replay, this doc = the maintainer's at-a-glance map.

> The driver does **not** parse this file. It reads the scenario `prompt:`. This doc is
> documentation only — it must be kept consistent with the prompt by hand (or by the
> foundry-skillpack-builder maintainer agent when it edits a scenario).

---

## The canonical lifecycle (the spine every flow is cut from)

Most scenarios are a *subset or reordering* of the full lifecycle in
[`maintenance/AUTOMATION.md` §2](../../maintenance/AUTOMATION.md). The full chain:

```
/assess-project → /plan-agent → /configure-rbac → /add-capability-host →
/prepare-deploy → azd up → /verify-agent → (/setup-purview ∥ /setup-evals) →
/publish-teams → /audit-drift          (/troubleshoot is cross-cutting)
```

Each scenario below is annotated with **which slice** of this spine it exercises and where it
deviates (e.g., brownfield starts with a *code scan* instead of `/plan-agent`; the dry-run
scenarios stop before `azd up`).

---

## Per-scenario command flows

Legend: **Tier** — `live` mutates Azure (billable); `dry-run` plans only; `read-only` inspects;
`offline` needs no Azure; `advisory` emits a brief. **Source** — the customer recipe the journey
mirrors.

### 01 — `01-greenfield.yaml` · Greenfield full deploy + verify · Tier: live · Source: recipe 01

Stand up a brand-new agent-framework agent with the public Microsoft Learn MCP tool, deploy it for
real, and verify.

| # | Command / action | Notes |
|---|---|---|
| 1 | Scaffold `agents/smoke-greenfield/` from `.agents/skills/foundry-deploy/templates/` | Dockerfile, agent.yaml, main.py, requirements.txt. Don't edit template sources. |
| 2 | Wire the Learn MCP tool into `main.py` | uncomment the example MCP block; `https://learn.microsoft.com/api/mcp` (no auth). |
| 3 | Author `agent-capabilities.yaml` | schema_version 1, hosted, container, target facts, model `gpt-4o-mini`, guardrails `middleware`, one MCP toolbox source. |
| 4 | `assess-project.sh <sub> <rg> <account> <project>` | writes `assessment/project-topology.json` (prepare-deploy needs it). |
| 5 | `prepare-deploy.sh agents/smoke-greenfield` | Track-H preflight; must report `azd up` is safe. |
| 6 | `safe-azd-init.sh` then `nohup azd up --no-prompt > /tmp/azd-up.log 2>&1 &` + poll the log | background deploy + tail-poll (avoids the 120s bash timeout + keeps the watchdog fed). |
| 7 | Send the verify query `"What is Azure AI Foundry?"` to the deployed agent | confirm a non-empty answer. |
| 8 | `agent_status.py` stamp `deploy.status` + `verify.verdict` | durable state file. |

Maps to recipe 01 Steps 1–4, collapsed (the scenario hands the agent the target facts so it
skips the `/plan-agent` elicitation). **Only live-green scenario to date** (greenfield-live-3).

### 02 — `02-setup-evals.yaml` · Continuous + scheduled eval planning · Tier: dry-run · Source: recipe 01/04

Plan (but don't create) the eval rules for an agent — proves the eval wrappers and role preflight
without mutating the Foundry project.

| # | Command / action | Notes |
|---|---|---|
| 1 | Scaffold an eval manifest + a small eval dataset | minimal `agent-capabilities.yaml` with an `evals` block. |
| 2 | `preflight-role.sh "Foundry User" <project-scope> --action setup-evals` | role check only. |
| 3 | `ensure_continuous_eval.py --dry-run` | prints the rule plan (evaluators, sample_rate, judge_model); creates nothing. |
| 4 | `ensure_scheduled_eval.py --dry-run` | prints the scheduled-eval plan. **No** `ensure_redteam.py` — westus has no cloud red-team. |

Maps to recipe 01 Step 5 / recipe 04, in `--dry-run` mode. Stops before any data-plane write.

### 03 — `03-configure-rbac.yaml` · RBAC grant plan (Phase 1 + 2) · Tier: dry-run · Source: command

Plan the identity/role grants for a deployed agent without applying them.

| # | Command / action | Notes |
|---|---|---|
| 1 | Scaffold a minimal deployed-agent layout | enough for the RBAC commands to resolve identities. |
| 2 | `check-identities.sh` | discovers `PROJECT_MI` + `AGENT_PRINCIPAL`. |
| 3 | `az acr list` (discover the ACR) | Phase-1 AcrPull target. |
| 4 | `grant-rbac.sh --dry-run` | prints Phase 1 (AcrPull) + Phase 2 (5 runtime roles incl. `Foundry User` GUID `53ca6127-db72-4b80-b1b0-d745d6d5456d`, `Azure AI User`, `Cognitive Services User`). Applies nothing. |

Maps to `/configure-rbac` Steps 1–2, plan-only. A **live** grant tier is tracked as TD-38.

### 04 — `04-traces-evals.yaml` · Deploy + REAL traffic + REAL continuous-eval · Tier: live · Source: recipe 01 (obs/eval variant)

The observability/eval availability smoke: deploy an **instrumented** agent, drive real queries to
produce trace spans, attach a **real** continuous-eval rule, then have the harness independently
query Azure to prove traces + evals are available.

| # | Command / action | Notes |
|---|---|---|
| 1 | Scaffold `agents/smoke-traces-evals/` from the template; keep `ENABLE_INSTRUMENTATION: "true"` | traces depend on instrumentation staying on. |
| 2 | Wire the Learn MCP tool (`approval_mode="never_require"`); instruct the agent to always use it | every Learn-answering query emits an `execute_tool` span. |
| 3 | Author `agent-capabilities.yaml` with an `evals.continuous` block (`sample_rate: 1.0`, redteam disabled) | sample every response so eval runs fire fast. |
| 4 | `assess-project.sh …` | writes `assessment/project-topology.json`. |
| 5 | `prepare-deploy.sh agents/smoke-traces-evals` | preflight. |
| 6 | `safe-azd-init.sh` then background `azd up` + poll | same background-deploy pattern as scenario 01. |
| 7 | Send **≥ 5** real queries that force a Learn MCP tool call | e.g. "Using Microsoft Learn, what is Azure AI Foundry?" — short pauses between, so distinct spans land. |
| 8 | `preflight-role.sh "Foundry User" <project-scope> --action setup-evals` | role check before the real eval create. |
| 9 | `YES=1 ensure_continuous_eval.py … --judge-model gpt-4o-mini` (**no** `--dry-run`) | creates `continuous-eval-smoke-traces-evals` for real. |
| 10 | `agent_status.py` stamp `deploy.status` + `verify.verdict` + `evals.continuous=created` | |
| — | *(harness, out-of-band)* App Insights `execute_tool` probe + `eval_rule_exists` + `eval_run_present` | the agent's self-stamp is **not** trusted for the trace/eval half — the harness verifies it directly. teardown_evals removes the data-plane rule afterward. |

Maps to recipe 01 Steps 1–5 **plus** the real continuous-eval path. Live-green is gated by
TD-35/TD-37. This is also the spine of the **greenfield + LangGraph + observability + eval**
journey below (swap the runtime).

### 05 — `05-troubleshoot.yaml` · Failure-mode diagnosis · Tier: offline · Source: command

Match a failing-deploy symptom against the failure-modes catalog and write a diagnosis. No Azure,
no deploy.

| # | Command / action | Notes |
|---|---|---|
| 1 | Match the symptom against `foundry-failure-modes` catalog → **F-01** (reserved env var, `APPLICATIONINSIGHTS_*`) | `/troubleshoot` cross-cutting command behaviour. |
| 2 | Write `diag/troubleshoot.md` with the diagnosis + the documented fix | offline artifact; no live state touched. |

Maps to `/troubleshoot` (the cross-cutting command in the §2 graph), run standalone against a
canned symptom.

### 06 — `06-prepare-deploy.yaml` · Preflight, stop before deploy · Tier: read-only · Source: command

Run `/prepare-deploy`'s Track-H preflight on a scaffolded agent and **stop at azd-ready** — prove
the gates without spending money.

| # | Command / action | Notes |
|---|---|---|
| 1 | Scaffold an agent layout | template files. |
| 2 | `/prepare-deploy` preflight (Track H gates H1–H5 + model GET + capability gate) | inspects agent.yaml/Dockerfile/requirements/main.py + the manifest. |
| 3 | Answer **NO** at the `azd up` offer → STOP at azd-ready | asserts `preflight.capabilities.guardrails.verdict=pass`. No deploy. |

Maps to `/prepare-deploy` up to (but not including) `azd up`.

### 07 — `07-audit-drift.yaml` · Read-only drift reconciliation · Tier: read-only · Source: command

Run `/audit-drift` against an agent with a baseline and produce a drift report. Read-only — never
remediates.

| # | Command / action | Notes |
|---|---|---|
| 1 | Scaffold an agent layout + `agent_status.py` init (sets a baseline hash) | gives `/audit-drift` something to reconcile against. |
| 2 | `/audit-drift` read-only reconcile (manifest vs. live/recorded state) | the audit never fixes anything. |
| 3 | Write `drift.md` (with a `SUMMARY`) + stamp the `verify.audit_summary` block | |

Maps to `/audit-drift` (the recurring `[9]` command), run once.

### 08 — `08-setup-purview.yaml` · Governance advisory brief · Tier: advisory · Source: command

Run `/setup-purview` and produce an honest governance brief — including the limitations it can't
enforce.

| # | Command / action | Notes |
|---|---|---|
| 1 | `/setup-purview` | advisory command. |
| 2 | Write `governance/purview-brief.md` | must disclose `AgentAdminActivity`, `AIInvokeAgent`, and the `purview-dlp` limitations (honesty requirement). |

Maps to `/setup-purview` (`[5]` in the §2 graph), advisory-only.

---

## Named example journeys (multi-recipe compositions)

The eight scenarios above each exercise one slice. Real customer journeys often **compose**
several recipes. Two representative end-to-end journeys, with the exact command order:

### Example A — Greenfield agent with LangGraph + observability traces + evaluation

> "Build a new greenfield agent with LangGraph, get observability traces, and add evaluation."

This is the recipe-01 lifecycle with the **LangGraph BYO runtime** instead of the agent-framework
template, run with instrumentation on and a real eval rule attached. The runtime swap is the only
difference from scenario 04's spine; the LangGraph clean sample lives at
`foundry-agent-playbook/.apm/skills/foundry-agent-playbook/samples/langgraph-chat-sample/`.

| # | Command / action | Why |
|---|---|---|
| 1 | `cp -r .agents/skills/foundry-agent-playbook/samples/langgraph-chat-sample agents/<name>` | start from the clean LangGraph BYO sample (deploys cleanly; the inverse of the deliberately-flawed `learn-agent` fixture). |
| 2 | *(optional)* `/plan-agent agent_name=<name> description="…"` | only if authoring from scratch instead of the sample — picks target + model + capabilities. The sample already ships a manifest. |
| 3 | Ensure instrumentation is on in `agent.yaml` (`ENABLE_INSTRUMENTATION: "true"`) | traces (`execute_tool`, model spans) require it — same dependency as scenario 04 step 1. |
| 4 | `/prepare-deploy agent_path=agents/<name>` | Track-H gates; for the clean sample every gate passes. |
| 5 | `azd up` | builds the image, agent version → `active`. |
| 6 | `/configure-rbac agent_path=agents/<name> agent_name=<name>` | Phase 1 (AcrPull) + Phase 2 (runtime roles). The LangGraph sample declares no external resources → no Phase 3 grants. |
| 7 | `/verify-agent agent_name=<name> test_query="What time is it?" agent_path=agents/<name>` | endpoint returns content; **OTel spans flow** (≥ 1 `execute_tool` span — the sample's `get_current_time` tool) — this is the **observability** proof. Confirm traces in App Insights / the Agent Monitoring dashboard. |
| 8 | `/setup-evals agent_name=<name> agent_path=agents/<name>` | creates a continuous-eval rule (`relevance` + `task_adherence` + `indirect_attack`); scores appear on the Monitor tab — this is the **evaluation** proof. |

**Observability detail:** traces are proven the same way scenario 04 proves them — drive real
queries, then confirm `execute_tool` spans landed in App Insights (`cloud_RoleName == <agent_name>`)
and the continuous-eval rule exists/has runs. The agent's own `agent-status.json` stamp is *not*
the proof of record; the App Insights / Foundry-project query is.

**Evaluation detail:** for a *real* (non-dry-run) eval rule the command is
`YES=1 ensure_continuous_eval.py … --judge-model <model>` (the path scenario 04 drives); the
`/setup-evals` command dry-runs first, then creates on confirmation.

### Example B — Brownfield agent: add evaluations + move model/MCP endpoints behind an APIM AI gateway

> "Onboard an existing (brownfield) agent, add evaluations, and route all model/MCP endpoints
> through an APIM AI gateway."

This composes **recipe 02 (brownfield onboarding)** → **recipe 05 (APIM-fronted MCP)** →
**`/setup-evals`**. Brownfield differs from greenfield at the front: you **scan existing code and
derive** the manifest instead of `/plan-agent` scaffolding it.

**Phase 1 — Onboard the existing code (recipe 02):**

| # | Command / action | Why |
|---|---|---|
| 1 | `mkdir -p agents/<name>` && `cp -r path/to/existing-code/* agents/<name>/` | stage the existing `main.py`/`requirements.txt` into the skillpack layout. Don't change the code yet. |
| 2 | `scan_knowledge_refs.py --agent-path agents/<name>` | regex scan emits a draft `knowledge.sources[]` block (signals-not-truth — review every TODO). |
| 3 | Author `agents/<name>/agent-capabilities.yaml` from the scan output | add real resource IDs; resolve every TODO/ambiguous signal. |
| 4 | `cp …/templates/agent.yaml.template … && cp …/templates/Dockerfile.template …` | brownfield code usually lacks these; substitute `${AGENT_NAME}` / model name; fix `COPY` lines for subfolders. |
| 5 | `/prepare-deploy agent_path=agents/<name>` | Track-H gates on the *existing* code (common ❌: unpinned `azure-identity`, unwired middleware). Fix + re-run until clean. |
| 6 | `azd up` | deploy the existing agent, unmodified except for the skillpack-required files. |
| 7 | `/configure-rbac agent_path=agents/<name> agent_name=<name>` | brownfield usually needs **Phase 3** grants (AI Search → `Search Index Data Reader`, Storage → `Storage Blob Data Reader`, etc.) because real code references real resources. Sets the **drift baseline**. |
| 8 | `/verify-agent agent_name=<name> test_query="<exercises your real workflow>" agent_path=agents/<name>` | smoke-retrieve per declared source; `verify.last_run_status: pass`. |

**Phase 2 — Move MCP endpoints behind the APIM AI gateway (recipe 05):**

| # | Command / action | Why |
|---|---|---|
| 9 | `az apim api create --api-id mcp-<name> --service-url <upstream> --path mcp/<name> --protocols https` | stand up the APIM API in front of the upstream MCP server; add inbound policies (JWT, OAuth/token injection, rate limit, correlation header). |
| 10 | `curl -H "Ocp-Apim-Subscription-Key: $APIM_KEY" https://<apim>.azure-api.net/mcp/<name>/…` | checkpoint: APIM front-door returns 200, not 401/404. |
| 11 | Update the manifest `toolbox.mcp_servers[].url` to the **APIM URL** (not the upstream) + read `APIM_SUBSCRIPTION_KEY` from env in `main.py` | the agent now calls APIM; the key is injected as `Ocp-Apim-Subscription-Key`. |
| 12 | `azd env set APIM_SUBSCRIPTION_KEY <key>` then `azd up` | redeploy with the key as a Bicep parameter (never bake the key into the image). |
| 13 | Verify per-source RBAC: `az role assignment list --assignee <caller> --scope <apim-rid> …` | for subscription-key auth the **caller** needs `API Management Service Contributor`; the per-agent SP needs **no** APIM grant. |
| 14 | `/verify-agent …` + KQL: `dependencies | where name=="execute_tool"` and `ApiManagementGatewayLogs | where ApiId=="mcp-<name>"` | confirm tool `target` shows `<apim>.azure-api.net/…` and matches an APIM gateway-log entry (stitched by `X-Correlation-Id`) — the traffic now goes through the gateway. |
| 15 | Confirm the drift baseline: `agent_status.py read --field drift.capability_hash_at_rbac` (and prove detection by editing the manifest + `agent_status.py drift` → exit 1) | the manifest changes from the APIM rewrite are captured. |

**Phase 3 — Add evaluations (recipe 04 / `/setup-evals`):**

| # | Command / action | Why |
|---|---|---|
| 16 | `/setup-evals agent_name=<name> agent_path=agents/<name>` | preflights `Foundry User`, dry-runs `ensure_continuous_eval.py`, then creates the rule on confirmation (regression-set / scheduled eval also available via `ensure_scheduled_eval.py`). |
| 17 | *(optional)* schedule `/audit-drift` weekly | catch forward drift (revoked role) + reverse drift (portal-added evaluator/MCP) against the baseline set in step 7. |

> **Model endpoints behind APIM:** recipe 05 fronts **MCP** endpoints. Routing the **model
> inference** endpoint through APIM (the AOAI/AI-gateway path) is a related but distinct surface —
> the manifest's MCP `url` rewrite (steps 11–12) is the proven path here; the model-endpoint
> gateway is configured at the Foundry-account/connection level, not in the agent manifest. See
> `foundry-agent-skillpack/.apm/skills/foundry-deploy/apim-as-mcp-frontdoor.md` for the full APIM
> surface. There is **no scenario authored** for the brownfield+APIM+evals composition yet — it is
> on the Track-2 backlog (AUTOMATION.md §6).

---

## Keeping this doc honest

- **A scenario's `prompt:` is the executable truth.** If this doc and a scenario disagree, the
  scenario wins (the driver runs the prompt, not this file) — fix the doc.
- When you author a new scenario: add the §6 coverage row **and** a flow section here, derived from
  the scenario `prompt:` + its source recipe.
- "Authored" ≠ "live-green". A flow documented here may never have run live yet — check the
  §6 `Live-green?` column. A failing live run auto-files on the rolling tester-track issue (the
  `e2e-test.yml` auto-finding step); record the fix in
  [`ITERATION-LOG.md`](./ITERATION-LOG.md).
