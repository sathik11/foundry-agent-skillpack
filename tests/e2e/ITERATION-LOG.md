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

## 2026-06-25 — F-K RESOLVED: harness clean-workspace setup step

Built the missing workspace-setup step so the full-deploy journey is reproducible by the harness
alone (was previously achieved partly by manual SP debugging).

| ID | Finding | Status |
|---|---|---|
| F-K | E2E must run in a CLEAN non-git workspace with the skillpack apm-installed. | **RESOLVED** |

What landed:
- `tests/e2e/setup-workspace.sh` — creates a NON-git workspace (default
  `$HOME/.cache/foundry-skillpack-e2e/<run-id>`), `apm install`s the local skillpack + playbook
  (`--target opencode,agent-skills`), and verifies the installed layout. Hard guard: refuses any
  `--dest` inside a git repo (exit 3) — the F-J root cause.
- `harness.py` — new `--clean-workspace` (mut-excl with `--workdir`), `--workspace-root`,
  `--skillpack-src`; on a clean run it builds the workspace, drives in it, and records `workdir`
  in `harness-report.json`. `--skip-driver` still requires `--workdir`.
- `scenarios/01-greenfield.yaml` — script/template/recipe references repointed from `.apm/` SOURCE
  paths to the **installed** paths (`.agents/skills/foundry-deploy/...`,
  `.agents/skills/foundry-agent-playbook/recipes/...`), matching what a real installed project has.

Validated (offline): non-git guard fires (exit 3); `apm install` into a fresh dir yields
`.opencode/agents/foundry-engineer.md` + 11 commands + 15 skills incl. the F-G/F-M
`agent.manifest.yaml.template`; harness `setup_clean_workspace()` returns the prepared non-git path.

Run it:
```
python3 tests/e2e/harness.py --scenario tests/e2e/scenarios/01-greenfield.yaml --clean-workspace
```

### Remaining before a full GREEN via harness alone
The scenario prompt still says `azd up` (step 5). Per **F-L** the RG-scoped SP must deploy with
`azd deploy` using the standing baseline (env: USE_EXISTING_AI_PROJECT=true, AZURE_AI_PROJECT_ID,
FOUNDRY_PROJECT_ENDPOINT, …). Encoding the 7-step deploy recipe above into the scenario is the next
task; until then a live `--clean-workspace` run reaches the deploy gate and stops there (correctly).

## 2026-06-25 — Scenario 02 (setup-evals) + two skillpack defects (F-N, F-O)

Built a second scenario to extend coverage past the greenfield deploy path: `/setup-evals` driven in
**dry-run** (no mutation, cheap, repeatable). Building it surfaced two real skillpack bugs via direct
script invocation — both fixed and verified.

| ID | Finding | Status |
|---|---|---|
| F-N | `foundry-evals/scripts/_common.py` imported `azure-ai-projects` + `azure-identity` + `yaml` **at module load**, so `--dry-run` crashed with `ModuleNotFoundError: No module named 'azure'` even though each `ensure_*_eval.py` carefully DEFERS its own `azure.ai.projects.models` import until after the dry-run early-return. The shared module defeated that contract: dry-run / role-preflight could never run without the full SDK installed (contradicts the prompt's "Legacy fallback … without the SDK installed" note and the caller-side dep model). | **FIXED** — made the three heavy imports lazy (moved into `load_capabilities` / `get_project_client`; `from __future__ import annotations` already makes the return hint lazy). |
| F-O | `foundry-roles/scripts/preflight-role.sh` resolved the caller via `az ad signed-in-user show`, which **only works for interactive USER logins**. Under a **service-principal / managed-identity** login — exactly the DevOps/CI persona this gate targets — it returned empty → "Not logged in to az" → exit 2 (best-effort). So in automation the role preflight was **permanently blind** and never actually verified any role across the whole skillpack (it's the shared gate for setup-evals, configure-rbac, prepare-deploy, setup-purview, publish-teams, audit-drift). | **FIXED** — fall back to `az account show` (`user.type == servicePrincipal`), resolve the SP's object id via `az ad sp show --id <appId>` (fallback to the appId, which `az role assignment list --assignee` also accepts). |

What landed:
- `foundry-agent-skillpack/.apm/skills/foundry-evals/scripts/_common.py` — lazy imports (F-N).
- `foundry-agent-skillpack/.apm/skills/foundry-roles/scripts/preflight-role.sh` — SP identity
  resolution (F-O).
- `tests/e2e/scenarios/02-setup-evals.yaml` — dry-run-first scenario: scaffolds a minimal
  `agent-capabilities.yaml` (declares `capabilities.evals.{role,continuous,scheduled}`, redteam
  disabled), runs preflight + `ensure_continuous_eval.py --dry-run` + `ensure_scheduled_eval.py
  --dry-run`, captures combined stdout/stderr to logs, asserts on the printed plans + preflight
  verdict. Red-team is intentionally skipped (project is westus → unsupported red-team region →
  `ensure_redteam.py` exits 3 before the dry-run return).

Schema notes confirmed from the wrappers:
- continuous reads `capabilities.evals.continuous.*` + `capabilities.evals.role`; scheduled reads
  `capabilities.evals.scheduled.*`; redteam reads `capabilities.evals.redteam.*`.
- scheduled **hard-requires** a dataset (`--dataset-jsonl`/`--dataset-id` or
  `evals.scheduled.dataset.path/dataset_id`) or it exits 2 — the scenario provides
  `eval/regression-set.jsonl`.
- the SP baseline has **Foundry User** assigned directly at project scope (granted during the
  greenfield deploy), so preflight returns rc 0 once F-O lets it resolve the SP.

Validated **deterministically** (no LLM driver) in a fresh F-K clean workspace
(`apm install` propagates both fixes into `.agents/skills/…`): preflight rc 0 ("Caller has
'Foundry User'"), continuous rc 0, scheduled rc 0; **all 6 scenario assertions PASS**.

Run it:
```
python3 tests/e2e/harness.py --scenario tests/e2e/scenarios/02-setup-evals.yaml --clean-workspace
```

Total real skillpack defects found by this smoke: **F-F, F-G, F-H, F-I, F-M, F-N, F-O** (7 fixed).

## 2026-06-26 — Scenario 03 (configure-rbac) + three defects in the never-driven RBAC path (F-P/Q/R)

Built the configure-rbac coverage (TD-38, PO's highest test priority). Like scenario 02 it runs in a
**dry-run / read-only** tier — no role assignment is created — so it is safe + repeatable and does not
need a deployed agent. To make `grant-rbac.sh` previewable I added a `--dry-run` / `--what-if` flag
(mirrors `ensure_*_eval.py --dry-run`): it prints the Phase 1 + Phase 2 plan and exits before any
`az role assignment create`, using a placeholder principal when no agent is deployed.

Driving it directly against the live testbed surfaced a **chain of three genuine defects** in this
command path (one of the six that had never been exercised):

| ID | Finding | Status |
|---|---|---|
| F-P | `check-identities.sh` printed its `[+]`/`[!]` progress to **stdout**, but `grant-rbac.sh` consumes the script via `eval "$(...)"` — so those lines were eval'd as commands (would fail under `set -e`). The script's contract is "stdout = machine `KEY=value` only". | **FIXED** — progress lines routed to stderr; only the `PROJECT_MI=`/`AGENT_PRINCIPAL=` heredoc stays on stdout. |
| F-Q | `azd ai agent show --name <not-yet-deployed>` writes a **non-JSON** banner to stdout; the `2>/dev/null \| jq` pipe parse-errored, and under `set -e` that aborted the whole script **before `PROJECT_MI` was ever emitted** — so identity discovery returned nothing at all for any not-yet-deployed agent. | **FIXED** — capture azd output first, `jq` only if valid, tolerate missing agent → empty principal. |
| F-R | When discovery degraded (F-Q), `grant-rbac.sh` hit `[[ -z "$AGENT_PRINCIPAL" ]]` with the var **unbound** → `set -u` crash (`AGENT_PRINCIPAL: unbound variable`). | **FIXED** — defaulted `PROJECT_MI`/`AGENT_PRINCIPAL` to empty after the `eval`; dry-run falls back to a placeholder. |

After the fixes, the live dry-run prints the complete, correct plan and the scenario's 7 assertions
all match:
```
[+] Phase 1 — Image pull (Project MI)
  - AcrPull @ acrskillpacke2e
[+] Phase 2 — Runtime (per-agent identity)
  - 53ca6127-db72-4b80-b1b0-d745d6d5456d @ ai-account-cnkboq4uixafy   (Foundry User)
  - 53ca6127-db72-4b80-b1b0-d745d6d5456d @ ai-project-skillpack-e2e    (Foundry User)
  - Cognitive Services OpenAI User @ ai-account-cnkboq4uixafy
  - Cognitive Services User @ ai-account-cnkboq4uixafy
[dry-run] Plan only — no role assignments created.
```
`check-identities.sh` stdout is now clean: `PROJECT_MI=<guid>` + `AGENT_PRINCIPAL=` (empty).

Run it:
```
python3 tests/e2e/harness.py --scenario tests/e2e/scenarios/03-configure-rbac.yaml --clean-workspace
```

**Still open (TD-38 live tier):** actual `az role assignment create`, idempotent re-run, a dependent
operation succeeding because of the grant, and teardown of test-only assignments — gated on a deployed
agent principal (the greenfield deploy).

Total real skillpack defects found by these smokes: **F-F, F-G, F-H, F-I, F-M, F-N, F-O, F-P, F-Q, F-R** (10 fixed).
