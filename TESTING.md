# Testing the toolkit end-to-end

This repo ships **two installable APM packages** plus end-to-end recipes:

1. **The engineering package** — `foundry-agent-skillpack/` — installs as 15 skills + 9 prompts + 1 agent persona.
2. **The fixtures package** — `foundry-agent-fixtures/` — opt-in; ships runnable fixtures (`learn-agent`, `langgraph-chat-fixture`) and 5 end-to-end recipes.
3. **A flawed fixture** — `learn-agent` (now inside the fixtures package) — deliberately broken to exercise the `/prepare-deploy` slash command end-to-end.

Full recipe-driven walkthroughs (greenfield, brownfield, 3-surface scenarios): see [TESTING_SCENARIOS.md](TESTING_SCENARIOS.md) and the per-recipe files inside the fixtures package.

---

## Prerequisites

- [APM CLI](https://microsoft.github.io/apm/) ≥ 0.12 (`apm --version`)
- A coding agent that supports `agent-skills` + `copilot` targets (VS Code Copilot Chat, Claude Code, Cursor, …)
- For the live deploy half: `azd ≥ 1.24` with the `azure.ai.agents` extension installed (`azd extension install azure.ai.agents`), `az` logged in, and access to a Foundry project + ACR

---

## Half 1 — Verify the APM packages install cleanly

```bash
rm -rf /tmp/apm-test && mkdir /tmp/apm-test && cd /tmp/apm-test
cat > apm.yml <<'EOF'
name: apm-install-test
version: 0.0.1
targets: [copilot, agent-skills]
EOF
apm install /path/to/Foundry-Hosted-Agent-Skill/foundry-agent-skillpack
apm install /path/to/Foundry-Hosted-Agent-Skill/foundry-agent-fixtures   # opt-in
```

**Expected output:**

```
[i] Targets: agent-skills, copilot  (source: apm.yml)
  [+] foundry-agent-skillpack (local)
  |-- 9 prompts integrated -> .github/prompts/
  |-- 1 agents integrated -> .github/agents/
  |-- 15 skill(s) integrated -> .agents/skills/
  [+] foundry-agent-fixtures (local)
  |-- 1 skill(s) integrated -> .agents/skills/
```

**Verify the layout:**

```bash
ls .agents/skills | wc -l                                                          # → 16 (15 engineering + 1 fixtures-package skill)
ls .github/prompts                                                                  # → 9 .prompt.md files
find .agents/skills/foundry-agent-fixtures/fixtures -mindepth 1 -maxdepth 1 -type d # → 2 (learn-agent, langgraph-chat-fixture)
find .agents/skills/foundry-agent-fixtures/recipes -name '*.md' | wc -l             # → 6 (README + 5 recipes)
```

If any number differs, something is being treated as a stray skill at the package root — fix and reinstall.

---

## Half 2 — Run `/prepare-deploy` against the fixture agent

The `learn-agent` fixture (now under `foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/fixtures/learn-agent/`) is **intentionally flawed** so the prompt has something to catch. Copy it into your test workspace first:

```bash
cp -r .agents/skills/foundry-agent-fixtures/fixtures/learn-agent agents/learn-agent
```

The flaws are:

| # | Where | Flaw | Which prompt step catches it |
|---|---|---|---|
| 1 | `agents/learn-agent/requirements.txt` | `azure-identity>=1.19.0` is missing the `<1.26.0a0` upper bound — would silently pull beta `1.26.0b2` | **H3** |
| 2 | `agents/learn-agent/main.py` | No `GuardrailAgentMiddleware` import / no `middleware=[…]` arg on `Agent(…)` | **H4** + **Step 2.5** capability gate |
| 3 | `agents/learn-agent/` | No `guardrails.py` file vendored, even though `agent-capabilities.yaml` declares `guardrails.enabled: true middleware_mode: entry` | **Step 2.5** |
| 4 | `agents/learn-agent/Dockerfile` | `COPY main.py .` instead of `COPY *.py ./` — even if (3) is fixed, the vendored guardrails file won't ship | **H2** (transitive once #3 is fixed) |
| 5 | repo root | No `azure.yaml`, no `infra/` — `azd up` cannot run | **Step 3** |

### How to run

In your APM-installed workspace (where you ran Half 1, or any workspace where you've installed this package):

```
/prepare-deploy agent_path=agents/learn-agent resource_group=<your-rg>
```

> Tip: copy the `agents/learn-agent/` folder into your test workspace first if you're not testing inside this repo directly.

### Expected behavior (per step)

1. **Step 1 — Detect agent kind:** prompt reports `Hosted (container)` (because `agent.yaml` has `kind: hosted` and `Dockerfile` + `main.py` are present).
2. **Track H preflight (H1–H5):** prints a checklist with **at least** ❌ for H3 (azure-identity unpinned) and H4 (no middleware wired). H1 / H2 / H5 should be ✅.
3. **Step 2 — Foundry resource validation:** picklists subscription / RG / project / model / ACR. The fixture is wired for `MODEL_DEPLOYMENT_NAME=gpt-5.4-mini-1`. Confirm that the prompt looks up the deployment via Azure MCP and prints a target table.
4. **Step 2.5 — capability gates:** loads `agents/learn-agent/agent-capabilities.yaml`, sees `toolbox` (✅ public Learn MCP) and `guardrails` (❌ missing `guardrails.py` and missing middleware wiring in `main.py`). Should STOP here.
5. **Step 3 — `azure.yaml`:** prompt should report `azure.yaml` missing at repo root and offer to either run `azd ai agent init` or hand-author a minimal one. (Won't reach here if Step 2.5 STOPs first — that's expected.)

### What a "successful test" looks like

The `/prepare-deploy` run STOPs at **Step 2.5** (or earlier at Track H), surfaces the 4 fixable flaws by file path with the exact fix, and **does not** call `azd up`. That proves the gates work.

Optional: have the agent auto-fix flaws #1–#4 (vendor `guardrails.py` from `.agents/skills/foundry-guardrails/scripts/`, edit `Dockerfile`, pin `requirements.txt`, wire middleware in `main.py`), then re-run `/prepare-deploy` to confirm a clean preflight followed by the `azure.yaml` scaffold prompt.

---

## Half 3 — End-to-end recipes

Five scenario recipes live under `foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/`:

| # | Recipe | Surfaces |
|---|---|---|
| 01 | Greenfield quickstart | agent + MCP + middleware + continuous eval |
| 02 | Brownfield onboarding | code-scan + manifest + RBAC verify + drift |
| 03 | Knowledge agent with Purview audit | agent + Foundry IQ + CS + Purview |
| 04 | AI Search direct + scheduled eval | agent + AI Search + scheduled eval gate |
| 05 | APIM-fronted MCP + RBAC + drift | agent + APIM + RBAC + drift |

Start at the [recipes index](foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/README.md) for the decision tree (greenfield vs brownfield).

## Other prompts to smoke-test (no live Foundry needed)

| Prompt | What to check |
|---|---|
| `/plan-agent name=foo description="…"` | Walks through pattern selection (Track A) or scaffolds a fresh agent under `agents/foo/` from `foundry-deploy/templates/` (Track B). |
| `/troubleshoot symptom="container exits 1"` | Routes to `foundry-failure-modes` skill and surfaces the matching diagnosis. |
| `/configure-rbac …` (dry-run) | Should print the `check-identities.sh` and `grant-rbac.sh` invocations it would run. |
| `/configure-rbac post_publish=true …` | Re-fan mode — should skip Phase 1/2 and target `publish.application_identity_principal_id` instead of the project identity (requires `publish` block already populated by `/publish-teams`). |
| `/setup-evals agent_path=…` | Should detect the eval rules in `agent-capabilities.yaml` and print the `ensure_*.py` invocations. |
| `/setup-purview agent_path=…` | Should print the Purview enablement steps + DLP middleware vendoring instructions. |
| `/publish-teams agent_path=… agent_name=…` | Step 0 short-circuit if `publish` block already present; otherwise runs preflight-publish.sh and prints the `azd ai agent publish` CLI (must NOT execute it). |
| `/audit-drift agent_path=…` | Reads `agent-status.json` and diffs declared vs live RBAC + capabilities; should flag drift in `rbac.capability_grants_post_publish` after a Teams publish. |

---

## Reporting issues

If a step fails or the prompt drifts off-script, capture:
- The exact slash command + arguments
- The full prompt response
- `apm --version` and `azd version`

Open an issue against this repo with the above plus the `agents/learn-agent/` flaw # you were exercising.
