<!-- MAINTAINER/CI-ONLY — live E2E smoke iteration log. Append findings per run. -->

# E2E Smoke — Iteration Log

The "execute → capture feedback → iterate" loop the maintainer asked for. Each live run appends a
dated block of findings + the fix.

## Environment proven (2026-06-24)

- Baseline provisioned in `agentskillpack-testbed-rg` (westus), `DEPLOY_SCOPE=group`, APIM off:
  Foundry project `ai-project-skillpack-e2e`, **gpt-4o-mini** deployed, capability host + Cosmos +
  Search + Storage + ACR + monitoring. 9 resources, tagged `purpose=skillpack-e2e-baseline`,
  `createdOn=24062026`.
- Driver (opencode → Foundry gpt-5.4 via AAD token) + guarded runner + harness all wired.
- opencode skillpack commands installed (`apm install` → `.opencode/commands/`).

## Run greenfield-live-1 (2026-06-24) — FAIL (expected; first run)

| ID | Finding | Severity | Status |
|---|---|---|---|
| F-A | Driver child failed with `EBADF: bad file descriptor, read` under detached/nohup launch (no valid stdin). | blocker | **FIXED** — `run_driver.py` now passes `stdin=subprocess.DEVNULL` (driver is always non-interactive). |
| F-B | The agent **searched the repo for `/plan-agent` command files** instead of executing the workflow. opencode slash-commands are user-typed expansions; the model does not auto-invoke them mid-prompt. Driver verdict `failed`, 16 events, 0 commands, 80s. | high (design) | **OPEN** — next iteration. |

### F-B options (next iteration)
1. **Drive the shipped agent persona:** run opencode with `--agent foundry-engineer` (installed at
   `.opencode/agents/foundry-engineer.md`) and phrase the journey as a goal, letting that agent's
   own instructions pull in the right skills — closest to "real user with the agent".
2. **Expand the command in-prompt:** pre-read `.opencode/commands/plan-agent.md` and inline its body
   into the driver prompt so the model executes the actual procedure, not a `/command` token.
3. **Hybrid:** `--agent foundry-engineer` + an explicit step list referencing the command bodies.

Leaning **option 1** (most faithful to real usage) with option 2 as fallback if the persona doesn't
reliably pick up the lifecycle. Also: the scenario prompt should pass the concrete target
(subscription/RG/project/model) so the headless agent doesn't need interactive picklists.

### Also note
- `azd ai agent` extension has an update available (`0.1.40-preview` → newer) — verify before the
  deploy step so we test against current.
- Headless `/plan-agent` Step 0a/0b are interactive (picklists, model-deploy consent). The journey
  prompt must supply target + "use existing gpt-4o-mini; do not deploy a model" up front (already
  partially worded; tighten with the exact project endpoint/name).

## Run greenfield-live-2 (2026-06-24) — STALLED (watchdog fired correctly)

Drove `--agent foundry-engineer` with concrete target facts on the scaffold→preflight slice.

| ID | Finding | Severity | Status |
|---|---|---|---|
| F-B | foundry-engineer agent now behaves correctly — loaded foundry-deploy skill, read templates/scripts (no aimless searching). | — | **RESOLVED** by --agent + concrete facts. |
| F-C | After ~29 events of exploration the run went silent for 600s → watchdog killed it (`stalled`, 836s). gpt-5.4 is a REASONING model: slow/overkill for a coding-scaffolding task, emitting no opencode events during a long reasoning turn. The guardrail WORKED (caught the stall). | high | **FIX:** switch coding scenarios to **gpt-5.3-codex** (the coding-optimized deployment) instead of gpt-5.4; it should act (write files) far faster. Optionally cap reasoning via `--variant minimal`. |

### Takeaways
- The anti-stall watchdog is validated on a real stall (not just synthetic).
- Model choice matters: use **gpt-5.3-codex** for scaffold/deploy (coding) scenarios; reserve gpt-5.4
  for reasoning-heavy judgement. The driver/backends already support per-scenario model.

## Run greenfield-live-3 (2026-06-24) — ✅ PASS (first green E2E smoke)

Same scenario, model switched to **gpt-5.3-codex**. Driver `completed` in **108.7s** (62 events,
2 commands). Scaffolded Dockerfile/agent.yaml/main.py/requirements.txt + a correct
agent-capabilities.yaml (schema_version 1, hosted, container, target block populated from the
confirmed facts, model gpt-4o-mini, guardrails middleware), then ran prepare-deploy.sh.

**Harness: OVERALL PASS — 5/5 assertions.** End-to-end pipeline proven:
provisioned baseline → opencode(foundry-engineer, gpt-5.3-codex) → guarded driver → scaffold →
assertions. F-C confirmed fixed by model choice (codex model is ~8x faster + actually acts).

### Standing decisions from this loop
- Default driver model for CODING/scaffold/deploy scenarios = **gpt-5.3-codex**.
- Reserve gpt-5.4 (reasoning) for judgement-heavy scenarios.
- Next milestones: extend this scenario to azd up + /verify-agent (real deploy), then add the
  brownfield + knowledge scenarios.

## Run greenfield-deploy-1 (2026-06-25) — partial (real preflight gate found)

Full-deploy journey (Learn MCP + azd up + verify), gpt-5.3-codex. Driver `completed` in 214s.
Agent scaffolded all files with Learn MCP wired, ran prepare-deploy.sh, hit a REAL gate and STOPPED
cleanly (no loop — guardrail-respecting behavior). Harness: 2/4 (scaffold + MCP pass; deploy/verify
blocked).

| ID | Finding | Severity | Status |
|---|---|---|---|
| F-D | azd up needs background+poll (bash 120s timeout + no events during long ops). | design | Built into the prompt (not yet exercised — blocked before deploy). |
| F-E | `prepare-deploy.sh` hard-requires `./assessment/project-topology.json` from a prior `/assess-project`. The journey skipped it. Real, correct skillpack dependency the smoke surfaced. | high | **FIX:** add an assess-project.sh step (sub, rg, account, project) before prepare-deploy. |

### Good signals
- gpt-5.3-codex scaffolds fast + correctly wires the no-auth Learn MCP.
- Agent honored "stop on first failure, don't loop" — clean failure, accurate root-cause report.

## Run greenfield-deploy-2 + direct debug (2026-06-25) — 4 REAL skillpack issues found & fixed

The smoke drove past scaffold into the real deploy preflight and surfaced a CHAIN of genuine
skillpack bugs/gaps + CLI drift. Debugged directly (as the SP) for speed; all fixes in .apm source.

| ID | Finding | Severity | Status |
|---|---|---|---|
| F-E | prepare-deploy requires ./assessment/project-topology.json from /assess-project. | high | FIXED (added assess step to journey) |
| F-F | `read-topology.sh` `emit()` returns 1 on an absent optional field; under `set -e` this aborted the whole dump on the FIRST missing field → exit 1 despite valid topology. | bug | **FIXED** — emit() now `return 0`. |
| F-G | agent-framework template shipped NO AgentManifest (`agent.manifest.yaml`) — only langgraph-byo had one — yet `safe-azd-init` requires AgentManifest for `--manifest`. Also safe-azd-init only ever read `agent.yaml`, never the sibling manifest file. | gap+bug | **FIXED** — added templates/agent.manifest.yaml.template; safe-azd-init now prefers agent.manifest.yaml (INIT_MANIFEST) for schema check + --manifest; scaffold.md file map updated. |
| F-H | **CLI DRIFT (headline):** `azd ai agent init` removed `--location` in azd.ai.agents >= 0.1.41; safe-azd-init still passed it → `unknown flag: --location`. | drift | **FIXED** — safe-azd-init now probes `init --help` for `--location`; if absent, sets AZURE_LOCATION in the azd env instead. Drift-resilient. |
| F-I | `prepare-deploy.sh` `run_stage()` captured `$?` AFTER a `2> >(tee…)` process substitution, clobbering it → every real stage failure reported `FAIL_EXIT_CODE=0` (masked root cause). | bug | **FIXED** — stderr to a plain file + tee afterwards so `$?` reflects the stage exactly. |
| F-J | In the full pipeline, `azd ai agent init` errors `directory 'smoke-greenfield' already exists and is not empty` (azd init -t scaffolds a subdir conflicting with the existing agents/<name>/ scaffold). Standalone safe-azd-init succeeds; the sync-azd-env→safe-azd-init interaction triggers it. | high | **OPEN** — next iteration (azd init working-dir / --src semantics). |

### Significance
This is the core thesis of the project, proven on the live testbed: the autonomous E2E smoke
**found 4 real skillpack defects + 1 real CLI drift**, and the guarded driver behaved correctly
throughout (stopped cleanly on failures, no loops). F-H is exactly the SDK/CLI-drift class the
twice-weekly watcher + fix loop is built to catch and auto-PR.

After F-F/F-G/F-H fixes, `azd ai agent init` SUCCEEDS standalone (azure.yaml created). F-J (a
pipeline-ordering interaction) is the remaining blocker before a full `azd up`.

## 2026-06-25 — ✅✅ FULL GREEN DEPLOY + VERIFY (real hosted agent on Azure)

Drove the complete journey to a working deployed agent. Final verify: **HTTP 200**, agent answered
"What is Azure AI Foundry?" correctly. Container built + pushed to ACR, hosted agent
`smoke-greenfield:1` created and active in ai-project-skillpack-e2e.

### Findings that unblocked it (all root-caused on the live testbed)

| ID | Finding | Status |
|---|---|---|
| F-J | `azd ai agent init` creates a self-contained project subdir with its own `.git`; running inside the skillpack's git WORKTREE breaks azd's template git-staging (`pathspec '*' did not match`). Works in a clean non-git dir. | root-caused → F-K |
| F-K | **E2E must run in a CLEAN non-git workspace** (also faithful to real usage: a user runs the skillpack in THEIR project, not inside the skillpack repo). Harness needs a workspace-setup step. | OPEN (harness design) |
| F-L | `azd up` provisions at SUBSCRIPTION scope → fails for our deliberately RG-scoped SP. Since the baseline is standing, the agent layer must deploy with **`azd deploy`** (not `azd up`). Matches the hybrid infra model. Requires azd env: AZURE_AI_PROJECT_ID, FOUNDRY_PROJECT_ENDPOINT, USE_EXISTING_AI_PROJECT=true, etc. | **RESOLVED** (use azd deploy) |
| F-M | Deployed container failed `/readiness` (HTTP 424 session_not_ready). Two causes: (1) azd's `{{AZURE_AI_MODEL_DEPLOYMENT_NAME}}` placeholder is a MANUAL-replace token, left literal in agent.yaml; (2) **env-var name mismatch**: agent-framework `main.py` reads `MODEL_DEPLOYMENT_NAME` but the AgentManifest (my F-G template, copied from langgraph-byo) set `AZURE_AI_MODEL_DEPLOYMENT_NAME`. Setting `MODEL_DEPLOYMENT_NAME=gpt-4o-mini` + redeploy → agent became ready → verify 200. | **FIXED in template** |

### The deploy recipe (for the harness, F-K)
1. Clean non-git workspace; apm-install skillpack (for .opencode commands + scripts).
2. Scaffold agent-framework + Learn MCP + agent.manifest.yaml.
3. `azd ai agent init -m agent.manifest.yaml --src agents/<name> --model-deployment <m> --protocol responses`.
4. azd env set: AZURE_SUBSCRIPTION_ID, AZURE_LOCATION, AZURE_RESOURCE_GROUP, AZURE_AI_ACCOUNT_NAME,
   AZURE_AI_PROJECT_NAME, AZURE_AI_PROJECT_ID, FOUNDRY_PROJECT_ENDPOINT, AZURE_AI_MODEL_DEPLOYMENT_NAME,
   USE_EXISTING_AI_PROJECT=true, AZURE_PRINCIPAL_ID/TYPE.
5. Resolve the `{{...}}` placeholder + ensure MODEL_DEPLOYMENT_NAME in agent.yaml.
6. `azd deploy --no-prompt` (NOT azd up — RG-scoped SP).
7. Verify: POST agents/<name>/endpoint/protocols/openai/responses?api-version=v1 with structured input → expect 200 + answer.

Total real skillpack defects found by this smoke: **F-F, F-G, F-H, F-I, F-M** (5 fixed) + harness/azd
design findings F-J/F-K/F-L. The autonomous E2E test has decisively proven its value.
