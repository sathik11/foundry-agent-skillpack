---
name: foundry-agent-fixtures
description: Runnable fixtures and end-to-end recipes for the foundry-agent-skillpack APM package. Reference material — not loaded into agent context for normal use; consult when smoke-testing the engineering package or following an end-to-end walkthrough.
---

# Foundry Agent Fixtures

Static asset folders shipped under the `agent-skills` target. **Not** consumed by your coding agent at edit time — these are reference material you read or `cd` into.

| Topic | Read |
|---|---|
| Recipe index + which surfaces each touches | [recipes/README.md](recipes/README.md) |
| Greenfield 30-min quickstart | [recipes/01-greenfield-quickstart.md](recipes/01-greenfield-quickstart.md) |
| Brownfield onboarding (existing code → Foundry) | [recipes/02-brownfield-onboarding.md](recipes/02-brownfield-onboarding.md) |
| 3-surface scenario: Foundry IQ + CS + Purview audit | [recipes/03-knowledge-with-purview.md](recipes/03-knowledge-with-purview.md) |
| 3-surface scenario: AI Search direct + scheduled eval gating publish | [recipes/04-ai-search-with-scheduled-eval.md](recipes/04-ai-search-with-scheduled-eval.md) |
| 3-surface scenario: APIM-fronted MCP + RBAC verify + drift baseline | [recipes/05-apim-fronted-mcp.md](recipes/05-apim-fronted-mcp.md) |
| Flawed agent-framework fixture (deploy gate exercise) | [fixtures/learn-agent/](fixtures/learn-agent/) |
| Clean LangGraph BYO fixture (success-path smoke) | [fixtures/langgraph-chat-fixture/](fixtures/langgraph-chat-fixture/) |

## How fixtures and recipes relate

Recipes can use either fixture, OR your own agent. Each recipe says explicitly which.

- **Fixtures** are concrete `agents/<name>/` folders you can `cp -r` into your project and `azd up`.
- **Recipes** are walkthroughs with checkpoints; they may reference a fixture or just a starter `agent-capabilities.yaml` snippet you bring your own code for.

## Cross-package references

- Engineering package (skills + prompts + convergent lifecycle scripts) → [foundry-agent-skillpack](../../../../foundry-agent-skillpack)
- Top-level package smoke test → [TESTING.md](../../../../TESTING.md)
