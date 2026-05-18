---
name: foundry-multi-agent
description: Multi-agent orchestration patterns — sibling calls, data buffer, SSE streaming, sub-agent contracts
---

# Foundry Multi-Agent Orchestration

> **When to use this skill.** You've already chosen a multi-agent pattern (2a–2e) via [foundry-patterns](../foundry-patterns/SKILL.md) and need the implementation mechanics. For an end-to-end walkthrough that wires all of this together (4 agents, per-sibling identity / RBAC / OTel / eval, drift baseline) see [Recipe 06 — Multi-Agent Orchestration](../../../../foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/06-multi-agent-orchestration.md).

## The Core Problem

Orchestrator LLM serializes Agent A's output as Agent B's tool argument — token by token.
For 25+ records (~20KB): 40-60s of output generation, risks SSE stream timeout.

## Solution 1 — Inter-Tool Data Buffer

```python
_DATA_BUFFER: dict[str, Any] = {}

@tool(approval_mode="never_require")
def invoke_harvester(query): 
    result = _invoke_sibling("harvester", query)
    _DATA_BUFFER["harvest_records"] = result["text"]  # Full data stored
    return json.dumps({"status": "success", "count": 119})  # Summary only to LLM

@tool(approval_mode="never_require")
def invoke_sentiment(records_json):
    full_data = _DATA_BUFFER.get("harvest_records", records_json)  # Bypass LLM
    result = _invoke_sibling("sentiment", full_data)
    return json.dumps({"status": "success"})
```

## Solution 2 — Payload Truncation

Cap at 30 records / ~30KB before passing to sub-agents. Foundry returns `server_error` on 50KB+.

## Sub-Agent Invocation

URL: `{EP}/agents/{name}/endpoint/protocols/openai/responses?api-version=v1`
Header: `Foundry-Features: HostedAgents=V1Preview`
Model: must exactly match sub-agent's configured model (`SUBAGENT_MODELS` mapping)

## Retry Strategy

5 attempts, exponential backoff (2s/4s/8s/8s). Retry on: HTTP 408/429/5xx, `status:"failed"` with empty output, `Connection refused`.

## Response Extraction — Three-Tier Fallback

1. `output_text` shortcut field
2. `output[].type=="message".content[].text`
3. Last `function_call_output.output` (raw tool JSON)

Strip ```json fences. Always extract from `function_call_output` for complete data (LLM summarizes and loses fidelity).

## SSE Streaming (>120s pipelines)

```python
body["stream"] = True
headers["Accept"] = "text/event-stream"
```

Event-driven state machine:
| Event | item.type | Action |
|-------|----------|--------|
| `output_item.added` | `function_call` | Mark agent RUNNING |
| `output_item.done` | `function_call_output` | Mark COMPLETE, cache output |
| `output_item.done` | `message` | Capture final text |
| `response.completed` | — | Finalize |

Stream close without `[DONE]` = mark FAILED. Single token (~1h) covers 9-min pipeline.

## Sub-Agent Contracts

- **Raw JSON mode**: Append "Return raw JSON records only." to every directive
- **Input unwrapping**: Tools must check `data.get("records") or data.get("rows") or data.get("enriched_records")`

## Timing Budget

| Stage | Duration |
|-------|---------|
| Harvester | ~30s |
| Sentiment | ~120s |
| Priority (reasoning:xhigh) | ~180s |
| Narrator | ~90s |
| **Total** | **~9 min** |
