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
