---
title: Contributing
description: How to propose changes, add a skill, add a recipe, or update content.
---

The skillpack is two APM packages plus a docs site. Contributions land via PRs to [github.com/sathik11/foundry-agent-skillpack](https://github.com/sathik11/foundry-agent-skillpack).

## Maintainers

| Name | Contact | Areas |
| --- | --- | --- |
| Sathik Basha | [sathik.basha@microsoft.com](mailto:sathik.basha@microsoft.com) | Skills, prompts, lifecycle scripts, docs |
| Salim Naim | [salimn@microsoft.com](mailto:salimn@microsoft.com) | Skills, prompts, lifecycle scripts, docs |

For substantive proposals (new skill, new recipe, capability-gate changes) please open a GitHub issue first so we can sequence it against the [roadmap](/roadmap/). For typos / clarifications / dead-link fixes, a PR straight to `main` is fine.

## Repo layout

```
foundry-agent-skillpack/
├── foundry-agent-skillpack/        # Engineering package (skills + prompts + scripts)
│   ├── apm.yml
│   ├── README.md
│   ├── TECHNICAL_DEBT.md
│   └── .apm/
│       ├── skills/               # 15 skills
│       ├── prompts/              # 9 slash commands
│       ├── agents/               # 1 agent persona
│       └── instructions/
├── foundry-agent-playbook/       # Fixtures + recipes (opt-in)
│   ├── apm.yml
│   ├── README.md
│   └── .apm/skills/foundry-agent-playbook/
│       ├── samples/             # learn-agent, langgraph-chat-sample
│       └── recipes/              # 6 end-to-end walkthroughs
├── docs/                         # This Astro Starlight site
├── ROADMAP.md
├── TESTING.md
└── TESTING_SCENARIOS.md
```

## Branch + PR workflow

1. Fork + clone.
2. Branch from `main`: `git checkout -b feat/<short-description>`.
3. Make changes.
4. Run the local APM smoke (see below).
5. If touching docs, run the docs build locally.
6. Push + open a PR.

## Adding a new skill

1. Create `.apm/skills/foundry-<topic>/SKILL.md` with frontmatter:
   ```yaml
   ---
   name: foundry-<topic>
   description: <one-liner used by the agent for retrieval>
   ---
   ```
2. Cross-link from related skills' router tables.
3. If the skill interacts with `agent-capabilities.yaml`, document Phase A / B / C gates in a `capability-gates.md` sub-doc and update [`foundry-deploy/capabilities-manifest.md`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/capabilities-manifest.md).
4. Add the skill to the [Skills overview](/skills/) page in this site.

## Adding a vendored script

Drop it under `<skill>/scripts/`. Conventions:

- **Shell**: `set -euo pipefail`; positional args validated with `${1:?usage…}`; `chmod +x`.
- **Python**: standalone (no own `requirements.txt`); `from __future__ import annotations`; lazy imports for optional SDK deps.
- **KQL**: filename = the question it answers (`tool-success-rate.kql`); first line is a `//` description with `<placeholders>` to substitute.
- **YAML CI**: target the `.github/workflows/` consumer location; use `secrets.AZURE_CLIENT_ID` etc.

Reference scripts from the matching `SKILL.md` / sub-doc using a relative link.

## Adding a recipe

Recipes live in `foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/`. Conventions:

- Frontmatter must include `validity_date`, `audience`, `duration`, `surfaces` (list), `prerequisites` (list).
- Must touch **3 surfaces minimum**: agent runtime + tools/knowledge + at least one outer-loop concern (guardrails / eval / red-team / Purview).
- Numbered: `<NN>-<short-name>.md`. Add to the [recipes README](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/README.md) table.
- Add to the [Recipes overview](/recipes/) page in this site.

## Adding a fixture

Fixtures live in `foundry-agent-playbook/.apm/skills/foundry-agent-playbook/fixtures/`. Each is a complete `agents/<name>/` folder (Dockerfile, agent.yaml, agent-capabilities.yaml, main.py, requirements.txt, README.md).

- **Clean fixtures** (intended to deploy successfully) demonstrate happy paths for templates / capabilities.
- **Flawed fixtures** (intended to fail specific gates) demonstrate the skillpack catching errors. `learn-agent` is the canonical flawed fixture.

Don't bake credentials into a fixture. Don't include subscription/RG-specific values — keep them parameterized.

## Local APM smoke

```bash
rm -rf /tmp/apm-test && mkdir /tmp/apm-test && cd /tmp/apm-test
cat > apm.yml <<'EOF'
name: apm-install-test
version: 0.0.1
targets: [copilot, agent-skills]
EOF
apm install /path/to/foundry-agent-skillpack/foundry-agent-skillpack
apm install /path/to/foundry-agent-skillpack/foundry-agent-playbook

# Verify expected counts
ls .agents/skills | wc -l            # → 16
ls .github/prompts | wc -l           # → 8
```

If counts differ, something is being treated as a stray skill — fix and reinstall.

## Local docs build

```bash
cd docs
npm install
npm run dev          # → http://localhost:4321
npm run build        # → produces ./dist/
```

## Versioning

Bump `apm.yml` `version:` for any consumer-visible change.

- **Patch** for content edits (typo fixes, sub-doc clarifications).
- **Minor** for new sub-docs / scripts / capabilities.
- **Major** for breaking changes (renamed prompts, renamed skills, removed scripts, manifest schema breakage).

Both packages version independently. Bump only what changed.

## Cross-references

Always use **relative** links between skills (`../foundry-identity/SKILL.md`), never absolute URLs to GitHub. The package may be vendored offline.

## Code of conduct

Be kind. Be honest about what you know vs guess. Push back when proposals seem premature. Ship the smallest version of an idea that's defensible.

## Reading further

- [Roadmap](/roadmap/) — what's planned.
- [Technical debt](/technical-debt/) — what we know is incomplete.
- [Skills overview](/skills/) — the existing surface to extend.
