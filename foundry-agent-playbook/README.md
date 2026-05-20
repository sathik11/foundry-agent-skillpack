# foundry-agent-playbook

> Runnable fixtures and end-to-end recipes for [foundry-agent-skillpack](../foundry-agent-skillpack). **Opt-in.** You don't need this in production.

## What this is

A second APM package that ships:

- **Fixtures** — runnable hosted-agent projects you can deploy into your own Foundry project as smoke-tests for the engineering package's prompts and scripts.
- **Recipes** — end-to-end walkthroughs that combine the agent runtime with tools/knowledge and at least one outer-loop concern (guardrails, eval, red-team, Purview, APIM).

It is deliberately separate from `foundry-agent-skillpack` so that:
- The engineering package stays a pure knowledge artifact (skills + prompts).
- Recipes can iterate without bumping the engineering package's version.
- Consumers who already know what they're doing don't pay for fixture content.

## Install

After installing the engineering package:

```bash
# Make sure your project's apm.yml declares targets (idempotent — skips if file exists).
[ -f apm.yml ] || cat > apm.yml <<'EOF'
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
apm install sathik11/foundry-agent-skillpack/foundry-agent-playbook   # this package
```

After install you'll see (under `agent-skills` target → `.agents/skills/`):

```
.agents/skills/foundry-agent-playbook/
├── fixtures/
│   ├── learn-agent/                    ← deliberately flawed agent-framework fixture
│   └── langgraph-chat-sample/         ← clean LangGraph BYO fixture
└── recipes/
    ├── README.md                        ← index of recipes
    ├── 01-greenfield-quickstart.md
    ├── 02-brownfield-onboarding.md
    ├── 03-knowledge-with-purview.md
    ├── 04-ai-search-with-scheduled-eval.md
    └── 05-apim-fronted-mcp.md
```

> APM ships these under the `agent-skills` target as static asset folders — they're not skills the model loads at edit-time. Treat them as reference material that lives next to your engineering-package skills.

## Where to start

| You are… | Read |
|---|---|
| New to Foundry hosted agents — building from scratch | [recipes/01-greenfield-quickstart.md](.apm/skills/foundry-agent-playbook/recipes/01-greenfield-quickstart.md) |
| Already have working agent code, want to host it on Foundry | [recipes/02-brownfield-onboarding.md](.apm/skills/foundry-agent-playbook/recipes/02-brownfield-onboarding.md) |
| Want to validate the package end-to-end against a real Foundry project | [recipes/README.md](.apm/skills/foundry-agent-playbook/recipes/README.md) |
| Just want to smoke-test that `apm install` works | [TESTING.md](../TESTING.md) at the repo root |

## Maintenance posture

Each recipe carries a `validity_date`. When a recipe goes stale (Foundry preview surface changes, SDK renames, region availability shifts), bump the date after re-validating. The daily-docs-scan workflow (planned, see TD-9 in the engineering package) will flag stale recipes.

Fixtures are pinned to specific package versions — when the engineering package introduces a breaking change, the fixture gets re-validated and this package's `apm.yml` version bumps.

## License

MIT
