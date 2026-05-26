# Foundry Agent Skillpack

> Plan, build, deploy, govern, and troubleshoot AI agents on Microsoft Foundry Agent Service — installable as an APM package.

[![APM](https://img.shields.io/badge/APM-package-blue)](https://microsoft.github.io/apm/)
[![Foundry](https://img.shields.io/badge/Microsoft-Foundry-purple)](https://learn.microsoft.com/azure/foundry/agents/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **⚠️ v0.19.0 rename — action required by v0.20.0.** This package was renamed from `foundry-agent-harness` to `foundry-agent-skillpack`. The `apm.yml` ships `aliases: [foundry-agent-harness]` so old references keep resolving for one release. Please update your project's `apm.yml` `dependencies:` block to the new name before v0.20.0, when the alias is removed. See [TD-19](./TECHNICAL_DEBT.md#td-19--package-rename-foundry-agent-harness--foundry-agent-skillpack).

---

## What this is

An [APM](https://microsoft.github.io/apm/) package that gives your AI coding agent (Copilot, Claude, Cursor, Windsurf, …) deep knowledge of Microsoft Foundry Agent Service — plus slash commands and convergent lifecycle scripts that walk you end-to-end through the agent lifecycle:

```
/plan-agent → /prepare-deploy → azd up → /configure-rbac → /verify-agent → /setup-evals
```

> **New to Foundry hosted agents?** After installing this package, also install [foundry-agent-playbook](../foundry-agent-playbook) and start with [recipe 01 — Greenfield Quickstart](../foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/01-greenfield-quickstart.md). It's a ~30 minute end-to-end walkthrough.

> **Boundary.** APM scaffolds, validates, audits, and dispatches per-capability gates. `azd up` (with the `azd ai agent` extension) deploys. The eval / red-team wrappers under `foundry-evals/` create Foundry-native `EvaluationRule` / `RedTeam` resources via `azure-ai-projects` SDK — so audit lives inside Foundry, not sideband CI artifacts. This package never runs `az acr build` or POSTs raw control-plane REST itself — the extension owns image build, agent create, version create, and identity assignment.

---

# For Consumers — Installing & using the skills

## 1. Prerequisites

Fresh laptop, macOS / Linux / WSL2 — one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/sathik11/foundry-agent-skillpack/main/scripts/install-prereqs.sh | bash
```

Installs `az` (≥ 2.80), `jq`, `azd` (≥ 1.24) + `azd ai agent` extension, Python 3.12+. Checks `apm` separately (npm-based). Skips `az login` / subscription pick / RBAC (you must do those manually). Re-runnable.

**Windows:** native PowerShell / Git Bash are **not supported as of v0.23.0** — use **WSL2** (`wsl --install`, then run the one-liner inside WSL). Native Windows via dual bash + PowerShell-7 siblings is under evaluation — see [TD-28](./TECHNICAL_DEBT.md#td-28--cross-os-script-runtime--bash--pwsh-dual-script-bake-off).

Full per-tool prerequisites table, why-each-is-needed, and the "verify everything" one-liner: [docs → install → prerequisites](https://foundry-agent-skillpack.example.com/getting-started/install/#prerequisites).

## 2. Install

From your project root:

```bash
# Make sure your project's apm.yml declares your target(s)
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

apm install sathik11/foundry-agent-skillpack/foundry-agent-skillpack
```

## 3. Where files land

After `apm install`, you'll see (depending on your `targets:`):

```
.agents/skills/                          ← 15 skills (the knowledge base)
  foundry-deploy/
    SKILL.md
    scaffold.md, sdk-surface.md, rest-api.md, version-lifecycle.md, external-mcp.md
    apim-as-mcp-frontdoor.md  ← APIM AI Gateway pattern (rate limit, OAuth, audit)
    capabilities-manifest.md, agent-status-schema.md
    scripts/agent_status.py   ← per-agent durable state helper (used by 3 prompts)
    scripts/discover-target.sh ← NEW (v0.21.0) one-call target discovery
    scripts/select-model.sh    ← NEW (v0.21.0) auto-select model deployment
    scripts/safe-azd-init.sh   ← NEW (v0.21.0) guarded azd init
    templates/                ← agent-framework templates (4 files)
    templates/langgraph-byo/  ← LangGraph BYO Responses-protocol template (6 files)
  foundry-identity/
    SKILL.md, two-identities.md, rbac-matrix.md, entra-agent-id.md
    scripts/check-identities.sh, scripts/grant-rbac.sh
  foundry-roles/                          ← caller-side role preflight + operator mode
    SKILL.md, role-matrix.md, runbook-format.md
    operator-mode.md                          ← NEW (v0.21.0) try-first pattern doc
    scripts/preflight-role.sh, scripts/preflight-roles.sh,  ← NEW batch version
    scripts/try-or-runbook.sh,                ← NEW (v0.21.0) operator-mode core primitive
    scripts/ensure-provider-registration.sh,  ← NEW (v0.21.0) auto-register providers
    scripts/runbook-emit.sh, scripts/list-my-roles.sh
  foundry-knowledge/                      ← Foundry IQ, AI Search, file-search, blob-via-search; cross-links Fabric
    SKILL.md, decision-tree.md, foundry-iq.md, ai-search.md, file-search-tool.md,
    blob-via-search.md, network-compatibility.md
    scripts/scan_knowledge_refs.py, scripts/verify-source-rbac.sh, scripts/verify-source-network.sh
  foundry-skills/                         ← NEW — native file-based skills (SkillsProvider) inside the hosted agent
    SKILL.md
    scripts/example-script-runner.py
  foundry-evals/                          ← convergent scripts for eval / red-team (audited in Foundry)
    SKILL.md, continuous-eval.md, scheduled-eval.md, redteam.md, evaluator-catalog.md
    scripts/_common.py, scripts/ensure_continuous_eval.py,
    scripts/ensure_scheduled_eval.py, scripts/ensure_redteam.py
  foundry-guardrails/
    SKILL.md, middleware.md, content-safety.md, redteam-evals.md, capability-gates.md
    purview-dlp.md           ← NEW — Layer 1.5 unique enforcement gap (Foundry-hosted-only)
    scripts/guardrails.py, scripts/redteam.yml, scripts/grant-cs-access.sh
    scripts/purview_dlp_middleware.py        ← vendored Purview DLP middleware
    scripts/grant-purview-dlp-access.sh      ← operator-mode aware (tries Graph REST, runbook on 403)
    scripts/kql/guardrail-spans.kql
  foundry-prod-readiness/
    SKILL.md, networking.md
    scripts/network/check-foundry-network-mode.sh, check-source-network.sh,
    scripts/network/check-private-endpoint.sh, check-private-dns.sh,
    scripts/network/deep-walk-nsg.sh, deep-walk-firewall.sh,
    scripts/network/check-service-endpoint-policy.sh,
    scripts/network/templates/byo-vnet-with-pe.bicep,
    network-troubleshooter.md                ← NEW (v0.20.0, TD-10) deep-walk runbook
  foundry-observability/
    SKILL.md, scripts/kql/*.kql
  foundry-teams-workiq/
    SKILL.md, publish-flow.md,               ← (v0.20.0, TD-2) identity-flip publish flow
    scripts/preflight-publish.sh, scripts/refan-rbac-post-publish.sh
  foundry-fabric/
    SKILL.md
    scripts/grant-fabric-workspace-role.sh   ← NEW (v0.21.0) operator-mode Fabric role grant
  …6 more skills…

.github/prompts/                          ← 9 slash commands
  plan-agent.prompt.md
  prepare-deploy.prompt.md
  configure-rbac.prompt.md                   ← +post_publish input (v0.20.0)
  verify-agent.prompt.md
  setup-evals.prompt.md
  setup-purview.prompt.md
  publish-teams.prompt.md                    ← NEW (v0.20.0, TD-2)
  troubleshoot.prompt.md
  audit-drift.prompt.md                    ← read-only declared-vs-observed reconciler

.github/agents/foundry-engineer.agent.md  ← specialized persona
```

These deploy folders are **regenerated** by every `apm install` — never edit them directly. Add them to `.gitignore` (APM does this automatically on first install).

## 4. Use it

| You want to… | Run |
|---|---|
| Plan a new agent | `/plan-agent agent_name=… description=…` |
| Run pre-deploy gates + `azd up` | `/prepare-deploy agent_path=agents/<name>` |
| Apply base + capability RBAC after deploy | `/configure-rbac agent_path=agents/<name> agent_name=<name>` |
| Smoke-test the deployed endpoint | `/verify-agent agent_name=<name> test_query="…" agent_path=agents/<name>` |
| Schedule continuous evaluation | `/setup-evals agent_name=<name> agent_path=agents/<name>` |
| Publish to Teams / M365 Copilot | `/publish-teams agent_path=agents/<name> agent_name=<name> bot_app_id=<bot-app-id>` |
| Diagnose a failure | `/troubleshoot symptom="…"` |

> **v0.19.0 — upfront target + model selection.** `/plan-agent` Step 0a now elicits subscription / RG / Foundry account / project via picklists and runs `preflight-role.sh plan-agent`; Step 0b runs the [model-selection algorithm](.apm/skills/foundry-deploy/model-selection.md) (list existing → pick / deploy-with-consent / runbook) and stamps a `target:` + `model:` block into `agent-capabilities.yaml`. `/prepare-deploy` Step 0 enforces caller role minimums *before* loading any project files, and Step 2.4 reuses the same model-selection forks instead of dead-ending on a 404.

The vendored shell scripts and KQL files inside `.agents/skills/` are runnable — the prompts invoke them by path so you don't have to copy-paste from docs.

## 5. Runtime dependencies

The package itself ships *knowledge + convergent lifecycle scripts*, not a server runtime. To actually deploy an agent and create eval rules you'll need:

- **Azure Developer CLI** (`azd`) ≥ 1.24 with the `azd ai agent` extension (`azd ext install azure.ai.agents`)
- **Python 3.12+** (for local dev, smoke tests, and the eval / red-team wrappers)
- **Az CLI** with `cognitiveservices` and `role` extensions (for the RBAC and network detection scripts)
- **`jq`** (used by identity discovery and network detection scripts)
- **For `foundry-evals/scripts/ensure_*.py`**: `pip install "azure-ai-projects>=2.0.0,<3" azure-identity pyyaml`

The shipped `requirements.txt.template` pins:
- `agent-framework>=1.2.2`
- `agent-framework-foundry-hosting==1.0.0a260429` (alpha — exact pin)
- `azure-identity<1.26.0a0`

## 6. Compatibility

| Target | Skills land in | Prompts land in | Agent persona |
|---|---|---|---|
| `agent-skills` (default) | `.agents/skills/` | — | — |
| `copilot` | (uses `agent-skills`) | `.github/prompts/` | `.github/agents/` |
| `claude` | `.claude/skills/` | `.claude/commands/` | — |
| `cursor` | `.cursor/skills/` | — | — |
| `windsurf` | `.windsurf/skills/` | — | — |
| `opencode` | `.opencode/skills/` | — | — |
| `gemini` | `.gemini/skills/` | `.gemini/commands/` | — |
| `codex` | (instructions via `AGENTS.md`) | — | — |

---

# For Authors — Developing skills in this repo

## Project structure

```
foundry-agent-skillpack/
├── apm.yml                            ← package manifest (name, version, targets)
├── README.md                          ← you are here
├── TECHNICAL_DEBT.md                  ← tracked limitations (TD-1..TD-19; TD-2 + TD-10 closed v0.20.0)
└── .apm/                              ← SOURCE OF TRUTH — author here
    ├── skills/                        ← 11 skills (router SKILL.md + sub-docs + scripts/)
    ├── prompts/                       ← 9 slash commands
    ├── agents/                        ← persona
    └── instructions/                  ← coding conventions
```

> Files outside `.apm/` (except this README, `TECHNICAL_DEBT.md`, `apm.yml`, `LICENSE`) are NOT shipped. Anything inside `.apm/skills/`, `.apm/prompts/`, `.apm/agents/`, `.apm/instructions/` IS.

## Skill anatomy (router pattern)

Each skill is a folder containing:

```
foundry-<topic>/
├── SKILL.md            ← thin router with task table; loaded into context
├── <subtopic-1>.md     ← deep doc, loaded only when referenced
├── <subtopic-2>.md
├── scripts/            ← runnable code (shell, python, KQL, yaml)
│   └── …
└── templates/          ← scaffold templates (foundry-deploy only)
```

Why this split: agents load `SKILL.md` aggressively but treat sub-docs as on-demand reads. Keeping `SKILL.md` thin (≤ 50 lines, mostly a table + cross-refs) lowers the load-time cost. Sub-docs grow without penalty.

## Adding a new skill

1. Create `.apm/skills/foundry-<topic>/SKILL.md` with frontmatter:
   ```yaml
   ---
   name: foundry-<topic>
   description: <one-liner used by the agent for retrieval>
   ---
   ```
2. Cross-link it from related skills' router tables.
3. If the skill interacts with `agent-capabilities.yaml`, document Phase A / B / C gates in a `capability-gates.md` sub-doc and update [.apm/skills/foundry-deploy/capabilities-manifest.md](.apm/skills/foundry-deploy/capabilities-manifest.md).

## Adding a vendored script

Drop it under `<skill>/scripts/`. Conventions:

- **Shell**: `set -euo pipefail`; positional args validated with `${1:?usage…}`; `chmod +x`
- **Python**: standalone (no own `requirements.txt`); `from __future__ import annotations`
- **KQL**: filename = the question it answers (`tool-success-rate.kql`); first line is a `//` description with `<placeholders>` to substitute
- **YAML CI**: target the `.github/workflows/` consumer location; use `secrets.AZURE_CLIENT_ID` etc.

Reference scripts from the matching `SKILL.md` / sub-doc using a relative link.

## Local install loop (verify your changes)

```bash
rm -rf /tmp/apm-test && mkdir /tmp/apm-test && cd /tmp/apm-test
cat > apm.yml <<'EOF'
name: apm-install-test
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
apm install /path/to/foundry-agent-skillpack/foundry-agent-skillpack
find . -maxdepth 4 -not -path '*/apm_modules/*' | sort
```

You should see exactly 11 entries under `.agents/skills/` and 9 under `.github/prompts/`. Anything else means a stray file at the package root is being treated as a skill — fix and reinstall.

## Versioning

Bump `apm.yml` → `version:` for any consumer-visible change. Patch for content edits, minor for new sub-docs / scripts, major for breaking changes (renamed prompts, renamed skills, removed scripts).

## Cross-references

Always use **relative** links between skills (`../foundry-identity/SKILL.md`), never absolute URLs to GitHub. The package may be vendored offline.

---

## Key warnings

> **`FoundryAgent` class (v1.1.1) silently fails in the refreshed preview.** It uses `extra_body={"agent_reference": ...}` — the deprecated initial-preview pattern. Use the client-swap pattern. See [.apm/skills/foundry-deploy/sdk-surface.md](.apm/skills/foundry-deploy/sdk-surface.md).

> **Foundry hosted agents are public preview.** Production-readiness claims here scope to the agent-identity and governance layers (GA), not the hosting runtime.

> **Initial-preview backend retires May 22, 2026.** Migrate before then.

---

## License

MIT
