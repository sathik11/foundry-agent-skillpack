---
title: Greenfield quickstart
description: Stand up a working hosted agent in ~30 minutes, end-to-end.
---

You have nothing. You want a working hosted agent on Foundry that calls the public Microsoft Learn MCP server, has middleware guardrails, and gets continuous evaluation.

The full step-by-step lives in **Recipe 01** inside the fixtures package. After installing both packages, open it locally:

```bash
.agents/skills/foundry-agent-fixtures/recipes/01-greenfield-quickstart.md
```

[View the recipe on GitHub →](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/01-greenfield-quickstart.md)

## What you'll touch

| Surface | Choice |
| --- | --- |
| Agent runtime | `agent-framework` (or LangGraph BYO — same lifecycle) |
| Tool | Microsoft Learn MCP — public, no auth |
| Outer loop | Middleware guardrails (Layer 1) + continuous eval |

## What you'll run, in order

```text
/plan-agent name=hello-foundry description="..."
/prepare-deploy agent_path=agents/hello-foundry
azd up
/configure-rbac agent_path=agents/hello-foundry agent_name=hello-foundry
/verify-agent agent_name=hello-foundry test_query="..." agent_path=agents/hello-foundry
/setup-evals agent_name=hello-foundry agent_path=agents/hello-foundry
```

## What good looks like

When you finish:

- `azd ai agent show` returns `status: active` with a non-empty `instance_identity.principal_id`.
- A test query returns a response that cites Microsoft Learn.
- App Insights shows `execute_tool` spans and `guardrail.middleware` spans.
- The Foundry portal **Monitor** tab shows continuous-eval scores within ~5 minutes of traffic.
- An `agent-status.json` exists in the agent folder with `preflight`, `deploy`, `identities`, `rbac`, `evals`, `verify`, and `drift` sections populated.

## If something goes wrong

The skillpack's `/troubleshoot` slash command routes by symptom:

```text
/troubleshoot symptom="..."
```

Common first-time failures:

| Symptom | Likely cause |
| --- | --- |
| `provision` fails on `azd up` | Missing prerequisites — see [Install](/getting-started/install/) |
| `403` on first verify | RBAC propagation (5–15 min); retry |
| No tool spans | `ENABLE_INSTRUMENTATION=true` not set on the agent version |
| No eval scores | Agent received no traffic in the sample window — generate test traffic |

Full troubleshooting matrix in the **foundry-failure-modes** skill.

## Then

- Add knowledge sources → [Recipe 03 — Knowledge with Purview](/recipes/) (covered in the recipes index).
- Schedule weekly drift audits → [`/audit-drift`](/reference/prompts/) (read-only).
- Hitting a single-agent wall (>60s latency, 3+ kinds of work, want different models per task)? → [Recipe 06 — Multi-agent orchestration with data buffer + SSE](/recipes/06-multi-agent-orchestration/).
