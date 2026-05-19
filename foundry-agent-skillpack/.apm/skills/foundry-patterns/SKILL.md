---
name: foundry-patterns
description: Agent pattern catalog and decision tree for Microsoft Foundry — hosted, prompt, single-agent, and multi-agent patterns
---

# Foundry Agent Patterns

## Two Agent Kinds

| Kind | Runtime | Custom Code | Container |
|------|---------|-------------|-----------|
| **Hosted** | Your Docker container on Foundry-managed infra | Yes | You build + push to ACR |
| **Prompt** | Foundry-managed (no container) | No | None |

## Single-Agent Patterns

- **1a — Hosted + Custom Tools**: `@tool` functions with business logic. Most common.
- **1b — Hosted + Toolbox MCP (zero custom code)**: All data via Foundry Toolbox connections. No `tools.py`.
- **1c — Middleware Short-Circuit**: Deterministic logic in `AgentMiddleware.process()` skips the LLM. 103s → 6s.
- **1d — Prompt + Built-in Tools**: `web_search_preview`, `code_interpreter`, `file_search`, `memory_search`.
- **1e — Prompt + MCP Connections**: GitHub MCP, WorkIQ Teams MCP with `require_approval: always`.
- **1f — Prompt + Memory**: `memory_search` with `chat_summary_enabled` for persistent context.
- **1g — Swiss Army + Toolbox**: One hosted agent, all tools via Toolbox. Simplest enterprise pattern.

## Multi-Agent Patterns

- **2a — Sequential Fan-out**: Orchestrator calls N siblings in order via Responses API.
- **2b — Parallel Fan-out**: Some siblings run concurrently (LLM calls multiple tools in one turn).
- **2c — Hybrid**: Hosted orchestrator + prompt sub-agents. Watch for model mismatch trap.
- **2d — Peer-to-Peer A2A**: No central orchestrator. Each agent owns its routing.
- **2e — Event-Driven**: Schedule/webhook/eventstream triggers. ACA cron → agent endpoint.

For 2a/2b/2c implementation mechanics — sub-agent invocation URL, retry, three-tier response extraction, the **inter-tool data buffer** (LLM serialization bypass for >25 records / >20KB), and SSE streaming for >120s pipelines — use the **foundry-multi-agent** skill.
For an end-to-end walkthrough (orchestrator + 3 siblings + per-sibling identity, RBAC, OTel, eval) see [Recipe 06 — Multi-Agent Orchestration](../../../../foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/06-multi-agent-orchestration.md).

## Decision Tree

1. Need custom code? NO → Prompt agent. YES → continue.
2. Logic deterministic? YES → Pattern 1c (middleware). NO → continue.
3. All data via Toolbox? YES → Pattern 1b. NO → Pattern 1a.
4. Broad scope? → Pattern 1g (Swiss army).
5. Multiple agents needed? Sequential → 2a. Parallel → 2b. Mix hosted+prompt → 2c.

## Anti-Patterns

- Multi-agent when single suffices — unnecessary RBAC complexity
- LLM as data router — serialization bottleneck, use inter-tool buffer instead
- Same model for all agents — right-size: nano for ingestion, mini for scoring, chat for narrative
- No fallback for NL2SQL — Fabric Data Agent is non-deterministic, always have a Delta read fallback
