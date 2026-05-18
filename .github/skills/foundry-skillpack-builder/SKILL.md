---
name: foundry-skillpack-builder
description: 'Context loader for maintainers fixing bugs / triaging issues in THIS repo (the Foundry-Hosted-Agent-Skill APM monorepo that ships `foundry-agent-skillpack` + `foundry-agent-fixtures`). USE WHEN: a bug is reported against the skillpack, a recipe is broken, a prompt or skill misbehaves on a consumer install, a script under `.apm/skills/*/scripts/` errors, docs site drift is reported, TECHNICAL_DEBT entry needs work, or a roadmap item starts. Sets up source-of-truth boundaries (`.apm/` vs installed `.agents/` + `.github/` copies), maps symptom → likely owning skill/prompt/script, and runs the local install verification loop. DO NOT USE FOR: building or deploying a Foundry agent end-to-end (that is what consumers do via the slash commands — use `foundry-engineer` agent or the shipped prompts). DO NOT USE FOR: docs-site authoring outside drift triage (edit `docs/src/content/docs/` directly).'
---

# Foundry Skillpack Builder

Context bootstrap for maintainers of the **Foundry-Hosted-Agent-Skill** monorepo. Load this skill at the start of any bug-fix, issue-triage, or feature-work session so you start from the right files and never edit a regenerated copy by mistake.

## When to load this skill

- A user filed an issue / regression against `foundry-agent-skillpack` or `foundry-agent-fixtures`.
- A consumer reports `apm install` ships wrong files, or a slash command fails.
- A vendored script (`*.py`, `*.sh`, `*.kql`) under a skill's `scripts/` folder is broken.
- A recipe under `foundry-agent-fixtures` no longer matches reality.
- The docs drift checker (`docs/scripts/check-drift.mjs`) flags missing skill / prompt / TD coverage.
- You are starting work on a `TD-N` entry from [TECHNICAL_DEBT.md](../../../foundry-agent-skillpack/TECHNICAL_DEBT.md) or a [ROADMAP.md](../../../ROADMAP.md) item.
- You need to add a new skill, prompt, or vendored script.

## Critical invariant — source of truth

| Path | Status | Edit? |
|---|---|---|
| `foundry-agent-skillpack/.apm/{skills,prompts,agents,instructions}/` | **SOURCE OF TRUTH** | ✅ Yes — author here |
| `foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/{fixtures,recipes}/` | **SOURCE OF TRUTH** | ✅ Yes — author here |
| `.agents/skills/foundry-*` (repo root) | **APM-installed copy** | ❌ Never — regenerated on `apm install` |
| `.github/{prompts,agents}/` (repo root) | **APM-installed copy** | ❌ Never — regenerated on `apm install` |
| `docs/src/content/docs/` | Hand-curated subset (recipes auto-mirrored) | ✅ Yes — for site-only edits |
| Anything else outside `.apm/` (except `README.md`, `TECHNICAL_DEBT.md`, `apm.yml`, `LICENSE`) | NOT shipped by the package | n/a |

**If you find yourself editing under `.agents/skills/` or `.github/prompts/` at the repo root, stop.** Find the matching path under `foundry-agent-skillpack/.apm/` and edit there, then re-install (see [§ Verify](#5-verify-the-fix-end-to-end)).

## Repo map (load this once into context)

```
Foundry-Hosted-Agent-Skill/                  ← monorepo (this repo)
├── apm.yml                                  ← top-level APM aggregator
├── README.md                                 ← consumer overview
├── ROADMAP.md                                ← v0.x sequencing
├── TESTING.md                                ← apm-install verification loop
├── TESTING_SCENARIOS.md                      ← end-to-end scenario matrix
│
├── foundry-agent-skillpack/                   ← PACKAGE 1 — engineering knowledge
│   ├── apm.yml
│   ├── README.md
│   ├── TECHNICAL_DEBT.md                     ← TD-1..TD-17 (single source for gaps)
│   └── .apm/
│       ├── skills/foundry-{deploy,evals,fabric,failure-modes,guardrails,
│       │            identity,knowledge,multi-agent,observability,patterns,
│       │            prod-readiness,purview,roles,skills,teams-workiq}/
│       ├── prompts/{plan-agent,prepare-deploy,configure-rbac,verify-agent,
│       │            setup-evals,setup-purview,troubleshoot,audit-drift}.prompt.md
│       ├── agents/foundry-engineer.agent.md
│       └── instructions/foundry-conventions.md
│
├── foundry-agent-fixtures/                  ← PACKAGE 2 — recipes + fixtures (opt-in)
│   ├── apm.yml
│   ├── README.md
│   └── .apm/skills/foundry-agent-fixtures/
│       ├── fixtures/{learn-agent,langgraph-chat-fixture}/
│       └── recipes/0{1..5}-*.md
│
├── docs/                                    ← Astro Starlight site → Azure SWA
│   ├── astro.config.mjs
│   ├── scripts/{check-drift,mirror-recipes}.mjs
│   └── src/content/docs/{concepts,getting-started,recipes,reference}/
│
├── .agents/skills/foundry-*/                ← APM output (do not edit)
└── .github/{prompts,agents}/                ← APM output (do not edit)
```

## Symptom → likely owner

When a bug is reported, jump to the owning area first.

| Symptom | Most likely lives in |
|---|---|
| Slash command (`/plan-agent`, `/prepare-deploy`, `/configure-rbac`, `/verify-agent`, `/setup-evals`, `/setup-purview`, `/troubleshoot`, `/audit-drift`) misbehaves | `foundry-agent-skillpack/.apm/prompts/<name>.prompt.md` |
| RBAC role wrong / missing | `foundry-agent-skillpack/.apm/skills/foundry-roles/` (preflight) **or** `foundry-identity/scripts/grant-rbac.sh` (dispatch) |
| Eval / red-team SDK call drifted | `foundry-agent-skillpack/.apm/skills/foundry-evals/scripts/ensure_*.py` (and `_common.py`) — see TD-8, TD-9 |
| Knowledge source RBAC / network gate wrong | `foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/{verify-source-rbac,verify-source-network}.sh` |
| Network detection (publicNetworkAccess, PE, NSG) wrong | `foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/scripts/network/*.sh` (TD-10 covers NSG/Firewall gap) |
| Purview DLP middleware / classify call wrong | `foundry-agent-skillpack/.apm/skills/foundry-guardrails/scripts/purview_dlp_middleware.py` (TD-4) |
| Per-agent durable state corrupt | `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/agent_status.py` + `agent-status-schema.md` |
| Brownfield code scan miss | `foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/scan_knowledge_refs.py` (TD-13 — regex-only by design) |
| Capability manifest ↔ live world drift report wrong | `foundry-agent-skillpack/.apm/prompts/audit-drift.prompt.md` (no scripts; pure prompt) |
| Recipe instructions stale | `foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/0{1..5}-*.md` — bump `validity_date` after fix |
| Fixture (`learn-agent` / `langgraph-chat-fixture`) won't deploy | `foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/fixtures/<name>/` |
| Docs site missing a skill / prompt / TD | run `node docs/scripts/check-drift.mjs` (TD-17 Phase 1); fix in `docs/src/content/docs/` |
| Coding-convention question (SDK pin, env-var prefix, deploy boundary) | `foundry-agent-skillpack/.apm/instructions/foundry-conventions.md` |

If still unclear after that table, search the failure-modes catalog: `foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md` (25 verified symptom→fix entries).

## Architectural invariants (do not violate while fixing)

These are non-negotiable boundaries — a bug fix that crosses any of these is the wrong fix.

1. **APM ↔ azd boundary.** This package never runs `az acr build` or POSTs to `/agents/{name}/versions`. Image build, agent create, version create, and Entra Agent ID assignment are owned by `azd up` + the `azd ai agent` extension. APM validates and dispatches per-capability gates — that is all. (See `foundry-conventions.md` § "Deploy Boundary".)
2. **Skill router pattern.** Each `SKILL.md` stays ≤ ~50 lines (a task table + cross-refs). Deep content goes in sibling `<subtopic>.md` files that load on demand. Don't grow `SKILL.md` past that — grow a sub-doc.
3. **Vendored scripts.** Shell uses `set -euo pipefail` + `${1:?usage…}` + `chmod +x`. Python is standalone (no per-script `requirements.txt`) and starts with `from __future__ import annotations`. KQL filename = the question it answers; first line is a `//` description with `<placeholders>`.
4. **Cross-skill links must be relative** (`../foundry-identity/SKILL.md`), never absolute GitHub URLs — the package may be vendored offline.
5. **Convergent lifecycle scripts** (the `ensure_*` pattern in `foundry-evals/scripts/`) are idempotent: detect → create-or-update → never duplicate. Don't introduce sequential `create`-only scripts.
6. **Eval audit trail lives in Foundry**, not in sideband CI artifacts. Wrappers call `azure-ai-projects` SDK so rules are visible in the Foundry portal.
7. **Runbook-emit, don't escalate.** When a script lacks rights for an action (e.g., Fabric workspace role assign — TD-1), emit a paste-ready runbook for a privileged human. Never silently fail; never request elevation in-band.
8. **Reserved env-var prefixes** (`FOUNDRY_*`, `AGENT_*`, `APPLICATIONINSIGHTS_*`) cause the platform to return 400. Use a project prefix in examples / templates.

## Procedure — fixing a reported issue

### 1. Reproduce against the source-of-truth files
- Read the issue. Identify the symptom from the [Symptom → likely owner](#symptom--likely-owner) table.
- Open the matching file under `foundry-agent-skillpack/.apm/` or `foundry-agent-fixtures/.apm/`. **Do not** open the same-named file under `.agents/` / `.github/` at the repo root — that is the regenerated copy.

### 2. Cross-check related context
- Skill-level context: read the owning skill's `SKILL.md` + any sub-doc the prompt or script references.
- Cross-cutting context: check `foundry-conventions.md` (SDK pins, deploy boundary, env vars) before changing anything that touches build / deploy.
- If the symptom matches a known limitation, check `TECHNICAL_DEBT.md` (TD-1..TD-17) — the fix may already be designed and "deferred until X".

### 3. Implement the smallest fix
- Bug fix: edit only the offending file under `.apm/`.
- New script under an existing skill: drop it under `<skill>/scripts/`, follow the script conventions above, and reference it from the matching `SKILL.md` / sub-doc with a relative link.
- New skill: create `.apm/skills/foundry-<topic>/SKILL.md` with `name:` matching folder; cross-link from related skills' router tables; if it interacts with `agent-capabilities.yaml` add `capability-gates.md` and update `foundry-deploy/capabilities-manifest.md`.
- New prompt: create `.apm/prompts/<name>.prompt.md`; update consumer docs (README task table, docs site `reference/prompts.md`).

### 4. Mind the docs site
- If you added/removed a skill, prompt, or `TD-N` entry, update the matching docs page (`docs/src/content/docs/skills.md`, `reference/prompts.md`, or `technical-debt.md`).
- Recipes are auto-mirrored via `docs/scripts/mirror-recipes.mjs` — edit recipe sources only.
- Run `node docs/scripts/check-drift.mjs` from `docs/` and confirm the report is clean (or intentionally noisy).

### 5. Verify the fix end-to-end

Run the local install loop from a clean temp dir — this is the same loop documented in `TESTING.md`:

```bash
rm -rf /tmp/apm-test && mkdir /tmp/apm-test && cd /tmp/apm-test
cat > apm.yml <<'EOF'
name: apm-install-test
version: 0.0.1
targets: [copilot, agent-skills]
EOF

# Install the skillpack from your local working tree
apm install /path/to/Foundry-Hosted-Agent-Skill/foundry-agent-skillpack
# Optional — fixtures + recipes
apm install /path/to/Foundry-Hosted-Agent-Skill/foundry-agent-fixtures

find . -maxdepth 4 -not -path '*/apm_modules/*' | sort
```

Expected shape after install:
- `.agents/skills/` — 15 directories from skillpack (+ `foundry-agent-fixtures/` if installed).
- `.github/prompts/` — 8 `*.prompt.md`.
- `.github/agents/` — `foundry-engineer.agent.md`.

Anything stray at the package root being treated as a skill = a file outside `.apm/` is leaking into the package. Fix the file location and reinstall.

### 6. Versioning

Bump the package's `apm.yml` `version:`:
- **patch** — content edits, doc fixes, script bug fixes
- **minor** — new sub-docs, new scripts, new prompt, new recipe
- **major** — renamed prompts, renamed skills, removed scripts, schema breaking changes

Both packages version independently. Bumping fixtures rarely requires bumping the skillpack.

### 7. Update tracking docs
- If the fix closes a TD entry: edit `foundry-agent-skillpack/TECHNICAL_DEBT.md` and prepend `~~strikethrough~~` + add `(CLOSED in vX.Y.Z)` — keep the body for historical record (see TD-11, TD-12 for the established pattern).
- If the fix advances a roadmap item: edit `ROADMAP.md`.
- If you added/removed surface area: re-run the docs drift check (Step 4).

## Anti-patterns to catch in your own diff

- ❌ Editing files under `.agents/skills/` or `.github/{prompts,agents}/` at the repo root.
- ❌ Adding a runtime dependency for the package itself (the package is a knowledge artifact + standalone scripts; no shared `requirements.txt`).
- ❌ Adding `az acr build`, `az ai agent version create`, or raw control-plane REST POSTs to a prompt or script — that crosses the APM ↔ azd boundary.
- ❌ Absolute GitHub URLs in cross-skill links.
- ❌ A `SKILL.md` that grew past ~50 lines — split into sub-docs.
- ❌ A new sub-doc nobody links to from a `SKILL.md` task table — the agent will never load it.
- ❌ A "fix" that swallows an error a script previously raised — runbook-emit, don't silently pass.
- ❌ Closing a TD entry by deleting it — strikethrough + `(CLOSED in vX.Y.Z)` is the convention.

## Quick reference — key files

- [foundry-agent-skillpack/README.md](../../../foundry-agent-skillpack/README.md) — package overview + author section
- [foundry-agent-skillpack/TECHNICAL_DEBT.md](../../../foundry-agent-skillpack/TECHNICAL_DEBT.md) — TD-1..TD-17
- [foundry-agent-skillpack/.apm/instructions/foundry-conventions.md](../../../foundry-agent-skillpack/.apm/instructions/foundry-conventions.md) — SDK pins, env-var rules, deploy boundary
- [foundry-agent-skillpack/.apm/agents/foundry-engineer.agent.md](../../../foundry-agent-skillpack/.apm/agents/foundry-engineer.agent.md) — the consumer-facing persona
- [foundry-agent-fixtures/README.md](../../../foundry-agent-fixtures/README.md) — fixtures + recipes overview
- [ROADMAP.md](../../../ROADMAP.md) — release sequencing
- [TESTING.md](../../../TESTING.md) — install verification
- [TESTING_SCENARIOS.md](../../../TESTING_SCENARIOS.md) — scenario matrix
- [docs/scripts/check-drift.mjs](../../../docs/scripts/check-drift.mjs) — docs drift checker
