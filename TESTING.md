# Testing the toolkit end-to-end

This repo ships **two halves** that you can test independently:

1. **The APM package** — `foundry-agent-engineering/` — installs cleanly into any project as 11 skills + 7 prompts + 1 agent persona.
2. **A fixture agent** — `agents/learn-agent/` — a *deliberately flawed* hosted-agent project used to exercise the `/prepare-deploy` slash command end-to-end.

---

## Prerequisites

- [APM CLI](https://microsoft.github.io/apm/) ≥ 0.12 (`apm --version`)
- A coding agent that supports `agent-skills` + `copilot` targets (VS Code Copilot Chat, Claude Code, Cursor, …)
- For the live deploy half: `azd ≥ 1.24` with the `azure.ai.agents` extension installed (`azd extension install azure.ai.agents`), `az` logged in, and access to a Foundry project + ACR

---

## Half 1 — Verify the APM package installs cleanly

```bash
rm -rf /tmp/apm-test && mkdir /tmp/apm-test && cd /tmp/apm-test
cat > apm.yml <<'EOF'
name: apm-install-test
version: 0.0.1
targets: [copilot, agent-skills]
EOF
apm install /path/to/Foundry-Hosted-Agent-Skill/foundry-agent-engineering
```

**Expected output:**

```
[i] Targets: agent-skills, copilot  (source: apm.yml)
  [+] foundry-agent-engineering (local)
  |-- 7 prompts integrated -> .github/prompts/
  |-- 1 agents integrated -> .github/agents/
  |-- 11 skill(s) integrated -> .agents/skills/
```

**Verify the layout:**

```bash
ls .agents/skills | wc -l        # → 11
ls .github/prompts               # → 7 .prompt.md files
find .agents/skills/foundry-deploy -type f | wc -l        # → 11 (router + 5 sub-docs + 4 templates)
find .agents/skills/foundry-guardrails -type f | wc -l    # → 9 (router + 4 sub-docs + scripts/{guardrails.py, redteam.yml, grant-cs-access.sh, kql/guardrail-spans.kql})
find .agents/skills/foundry-identity -type f | wc -l      # → 6 (router + 3 sub-docs + scripts/{check-identities.sh, grant-rbac.sh})
```

If any number differs, something is being treated as a stray skill at the package root — fix and reinstall.

---

## Half 2 — Run `/prepare-deploy` against the fixture agent

The `agents/learn-agent/` fixture is **intentionally flawed** so the prompt has something to catch. The flaws are:

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

## Other prompts to smoke-test (no live Foundry needed)

| Prompt | What to check |
|---|---|
| `/plan-agent name=foo description="…"` | Walks through pattern selection (Track A) or scaffolds a fresh agent under `agents/foo/` from `foundry-deploy/templates/` (Track B). |
| `/troubleshoot symptom="container exits 1"` | Routes to `foundry-failure-modes` skill and surfaces the matching diagnosis. |
| `/configure-rbac …` (dry-run) | Should print the `check-identities.sh` and `grant-rbac.sh` invocations it would run. |

---

## Reporting issues

If a step fails or the prompt drifts off-script, capture:
- The exact slash command + arguments
- The full prompt response
- `apm --version` and `azd version`

Open an issue against this repo with the above plus the `agents/learn-agent/` flaw # you were exercising.
