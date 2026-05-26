---
title: Install
description: Install the Foundry Agent Skillpack packages and set up prerequisites.
---

The skillpack ships as **two opt-in APM packages**. Most consumers install both; production deployments may install only the engineering package.

## Prerequisites

### Quickest path — one-liner installer (macOS / Linux / WSL2)

```bash
curl -fsSL https://raw.githubusercontent.com/sathik11/foundry-agent-skillpack/main/scripts/install-prereqs.sh | bash
```

Detects your OS, installs only what's missing, prints exactly what you must still do manually. Re-running is safe.

| Flag | Use when |
|---|---|
| `--dry-run` | Show what would happen, install nothing |
| `--no-python` | You manage Python with pyenv/asdf/conda |
| `--no-azd` | You only run caller-side eval/audit scripts, never `azd up` |

### Full prerequisites table

| Tool | Minimum | Why (audited usage) |
| --- | --- | --- |
| **`bash`** | 4.0+ | Every `.apm/skills/*/scripts/*.sh` is `#!/usr/bin/env bash`. Windows → use **WSL2** (see below). |
| [APM CLI](https://microsoft.github.io/apm/) | `0.12` | Installs the packages. ≥ 0.12 specifically — no longer auto-defaults `targets:` |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | `2.80` | **79 invocations** across scripts. ≥ 2.80 because the api-versions bumped in v0.23.0 (`2026-03-01`, `2025-09-01`) need recent provider metadata |
| **`jq`** | any | **104 invocations** — every script parses `az` JSON through `jq` |
| **`az login` + active subscription** | n/a | Every `az` call assumes auth context. Fresh laptop → `az login` then `az account set --subscription <id>` |
| **Reader role at RG scope** (caller-side) | n/a | Even read-only `discover-target.sh` returns empty results without Reader — looks like "nothing exists" (this is the TD-24 silent-failure class) |
| [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) | `1.24` | Required for `azd up` — skip if you only run eval/audit |
| `azd ai agent` extension | latest | `azd extension install azure.ai.agents` — owns image build + agent create + version create |
| **Python** | `3.12+` | Eval / DLP / agent_status wrappers (9 `.py` files) |
| Coding agent | Copilot Chat / Claude Code / Cursor / Windsurf / Codex / Gemini / OpenCode | To run the slash commands |

For the eval / DLP wrappers, also:

```bash
pip install "azure-ai-projects>=2.0.0,<3" azure-identity pyyaml httpx
```

### Verify everything in one go

```bash
apm --version            # >= 0.12
az --version | head -1   # >= 2.80
azd version              # >= 1.24 (if deploying)
jq --version
python3 --version        # >= 3.12 (if running eval/DLP wrappers)
az account show          # confirms az login + active subscription
```

### Windows users — read this first

The skillpack is **bash-only as of v0.23.0**. Native Windows (PowerShell / cmd) cannot run the scripts. Two paths:

| Path | Setup | Status |
|---|---|---|
| **WSL2 + Ubuntu** ⭐ recommended | `wsl --install`, open VS Code with WSL Remote extension; integrated terminal defaults to bash; run the curl one-liner inside WSL | **Supported** |
| **Git Bash** | Install Git for Windows; set VS Code default terminal to `Git Bash` | **Not supported** — works for trivial scripts but bites on path mangling, `python3` aliasing, and process substitution in our multi-line `jq` pipelines |
| **Native PowerShell** | n/a | **Not supported today.** Dual bash + PowerShell-7 sibling scripts are under formal evaluation — see [TD-28 → cross-OS script runtime bake-off](/technical-debt/) |

**Setting WSL2 as your VS Code terminal:** `Ctrl+Shift+P` → `Terminal: Select Default Profile` → choose `Ubuntu (WSL)`. Then every Copilot-invoked script runs in bash.

## Two dependency surfaces — don't mix them

The skillpack has **two distinct Python dependency tiers**. Mixing them is the most common brownfield onboarding mistake.

### Caller-side (your laptop / CI runner)

What runs locally to call Foundry control-plane APIs through the skillpack wrappers and `/audit-drift`.

```bash
pip install "azure-ai-projects>=2.0.0,<3" azure-identity pyyaml httpx
```

These are installed **once per machine**. They never enter the agent's container.

### Container-side (the Docker image Foundry runs)

What ships **inside the hosted agent's image** and runs at request time. Declared in `agents/<name>/requirements.txt`.

Base set comes from the skillpack templates (agent-framework or LangGraph BYO). On top of the base, you add per declared capability:

| Capability declaration | Add to container `requirements.txt` |
| --- | --- |
| Telemetry to App Insights (always recommended) | `azure-monitor-opentelemetry>=1.7` (already in templates as of v0.18) |
| `guardrails.layers` includes `content_safety` (Layer 2) | `azure-ai-contentsafety>=1.0.0` |
| `guardrails.layers` includes `purview_dlp` (Layer 1.5) | `httpx>=0.27`, `opentelemetry-api>=1.27` |
| `knowledge.sources[].kind == fabric_direct_delta` | `deltalake>=0.18` |
| `knowledge.sources[].kind == ai_search_direct` (direct SDK in your code) | `azure-search-documents>=11.5` |

Full table + every capability + common-mistake matrix: [Runtime dependencies (foundry-deploy skill)](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/runtime-dependencies.md).

### Quick check — what NOT to do

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ModuleNotFoundError: azure_ai_projects` when running `/setup-evals` | Treated caller-side dep as container-side | Install on the *caller*, not in the agent image |
| Agent runs but no spans in App Insights | Missing `azure-monitor-opentelemetry` in container `requirements.txt` | Add it; redeploy |
| `purview_dlp_middleware` import fails in container | Missing `httpx` in container `requirements.txt` | Add `httpx>=0.27` to the agent's requirements; rebuild |

## Install both packages

In your project root:

```bash
# 1. Make sure your project's apm.yml declares your target(s)
cat > apm.yml <<'EOF'
name: my-foundry-project
version: 0.0.1
targets:
  - copilot
  - agent-skills
  - claude
  - cursor
  - windsurf
  - codex
  - gemini
  - opencode
EOF

# 2. Engineering skillpack — knowledge + prompts + scripts
apm install sathik11/foundry-agent-skillpack/foundry-agent-skillpack

# 3. Optional but recommended: playbook (samples + recipes)
apm install sathik11/foundry-agent-skillpack/foundry-agent-playbook
```

After install you should see (depending on your `targets:`):

```
.agents/skills/                          ← 16 skills (15 engineering + 1 playbook)
.github/prompts/                         ← 9 slash commands
.github/agents/                          ← 1 agent persona
```

## Verify

```bash
ls .agents/skills | wc -l            # → 16
ls .github/prompts | wc -l           # → 9
ls .github/agents/                   # → foundry-engineer.agent.md
```

## What lives where

| Path | What | Edit? |
| --- | --- | --- |
| `.agents/skills/foundry-*/` | Engineering skills (knowledge, scripts) | ❌ regenerated by every `apm install` |
| `.agents/skills/foundry-agent-playbook/recipes/` | End-to-end recipes | ❌ same |
| `.agents/skills/foundry-agent-playbook/samples/` | Runnable sample agents (`learn-agent`, `langgraph-chat-sample`) | ❌ — copy them into `agents/<name>/` to use |
| `.github/prompts/*.prompt.md` | Slash commands | ❌ regenerated by `apm install` |

`apm install` adds these directories to `.gitignore` automatically. Don't edit them in place — fork the repo if you need to.

## Troubleshooting — `No harness detected`

If you see this error on a fresh install:

```text
[x] No harness detected

APM scanned for harness markers (.claude/, CLAUDE.md, .cursor/, .cursorrules,
.github/copilot-instructions.md, .codex/, .gemini/, GEMINI.md, .opencode/,
.windsurf/) but found none in this project.

Previously APM defaulted to copilot; this is now explicit.
```

**Cause.** APM CLI ≥ 0.12 no longer auto-defaults to `copilot` when no client folder is present. You must declare `targets:` explicitly in your project's `apm.yml`.

**Fix.** Add a `targets:` line to `apm.yml`. Use whichever clients you actually run:

```yaml
# apm.yml — minimum to install
name: my-foundry-project
version: 0.0.1
targets:
  - copilot
  - agent-skills
  - claude
  - cursor
  - windsurf
  - codex
  - gemini
  - opencode
```

| Target | Writes to | Use when |
|---|---|---|
| `agent-skills` | `.agents/skills/` | Universal — any client that respects the APM skill convention. **Always include this.** |
| `copilot` | `.github/{prompts,agents,instructions}/` | GitHub Copilot Chat |
| `claude` | `.claude/{commands,agents}/` | Claude Code |
| `cursor` | `.cursor/skills/` | Cursor |
| `windsurf` | `.windsurf/skills/` | Windsurf |
| `opencode` | `.opencode/` | OpenCode |
| `codex` | `AGENTS.md` (single file) | Codex CLI |
| `gemini` | `.gemini/` + `GEMINI.md` | Gemini CLI |

`[copilot, agent-skills]` is the recommended starting pair: prompts surface in Copilot Chat as slash commands, and skills are still available to any other client you add later. Add more targets to your `apm.yml` and re-run `apm install` whenever you adopt a new client.

You can also one-shot a target on the command line: `apm install <pkg> --target claude`.

## Discovering the slash commands

After `apm install`, your coding agent surfaces the prompts when you type `/` in chat. **Two different things share the `/` prefix in some clients** — the table below disambiguates:

| What you see | What it is | Source path (Copilot target) | Has inputs? |
| --- | --- | --- | --- |
| `/plan-agent`, `/prepare-deploy`, `/configure-rbac`, `/verify-agent`, `/setup-evals`, `/setup-purview`, `/publish-teams`, `/troubleshoot`, `/audit-drift` | **Prompts** (executable workflows) — the 9 slash commands this skillpack ships | `.github/prompts/*.prompt.md` | ✓ see [Reference → Prompts](/reference/prompts/) for the per-command table |
| `/foundry-deploy`, `/foundry-identity`, `/foundry-roles`, `/foundry-knowledge`, `/foundry-guardrails`, `/foundry-purview`, `/foundry-fabric`, `/foundry-teams-workiq`, `/foundry-evals`, `/foundry-observability`, `/foundry-prod-readiness`, `/foundry-patterns`, `/foundry-multi-agent`, `/foundry-failure-modes`, `/foundry-skills` | **Skills** (knowledge corpus that prompts read) — surfaced by Copilot Chat under the same `/` autocomplete | `.github/instructions/*.instructions.md` | ✗ no inputs; selecting one loads the knowledge as context |
| `/agents`, `/help`, etc. | Built-in client commands | n/a | varies |

**Naming convention.** Anything prefixed with `foundry-` is a **skill** (knowledge). Bare verbs (`plan-agent`, `verify-agent`, `setup-evals`, …) are **prompts** (executable). You invoke prompts to *do* something; skills are loaded as context while a prompt runs.

**Per-client install location:**

| Client | Prompts install to | Skills install to | How to discover |
| --- | --- | --- | --- |
| Copilot Chat (VS Code) | `.github/prompts/` | `.github/instructions/` | Type `/` in chat — shows both prompts and skill instructions |
| Claude Code | `.claude/commands/` | `.claude/skills/` | Type `/` — only commands are listed |
| Cursor | `.cursor/skills/` | `.cursor/skills/` | Mentioned via `@` (not `/`) |
| Windsurf | `.windsurf/skills/` | `.windsurf/skills/` | Cascade picks them up automatically |
| OpenCode / Gemini / Codex | aggregated into `AGENTS.md` | aggregated into `AGENTS.md` | Document loaded as system context |

> The 9 prompts and 15 skills are identical across all targets — only the install path differs.

## Next

- [Greenfield quickstart →](/getting-started/greenfield/) — 30 minutes from nothing to a working agent.
- [Brownfield onboarding →](/getting-started/brownfield/) — onboard existing Python agent code.
