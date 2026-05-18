---
name: foundry-observability
description: OTel spans, App Insights traces, tool span verification, KQL cookbook, and token tracking for Foundry agents
---

# Foundry Observability

## Enabling

| Env Var | Value | Effect |
|---------|-------|--------|
| `ENABLE_INSTRUMENTATION` | `"true"` | Emits `execute_tool` spans |
| `ENABLE_SENSITIVE_DATA` | `"true"` | Includes tool input/output in spans |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | (auto-injected) | Do NOT set manually |

Without both: HTTP traces only, no tool spans.

## Tool Span Attributes

| Attribute | Example |
|-----------|---------|
| `gen_ai.tool.name` | `harvest_feedback` |
| `gen_ai.tool.call.arguments` | `{"query":"enterprise customers",...}` |
| `gen_ai.tool.call.result` | `{"status":"success","rows":119,...}` |
| `gen_ai.tool.call.id` | `call_FZOVXRL82J...` |

## KQL Cookbook

### Verify tool spans flowing
```kql
dependencies
| where cloud_RoleName == "<name>-v3"
| where name startswith "execute_tool"
| project timestamp, name, duration, customDimensions
| order by timestamp desc | take 10
```

### Tool latency by function
```kql
dependencies
| where cloud_RoleName == "<name>-v3" and name startswith "execute_tool"
| extend tool_name = tostring(customDimensions["gen_ai.tool.name"])
| summarize avg_ms=avg(duration), p95_ms=percentile(duration,95), count=count() by tool_name
```

### Guardrail activations
```kql
dependencies
| where name startswith "guardrail." and customDimensions["guardrail.action"] != "allow"
| project timestamp, name, customDimensions["guardrail.reason"]
```

### Cross-agent trace
```kql
union dependencies, requests
| where operation_Id == "<trace-id>"
| project timestamp, name, duration, cloud_RoleName
| order by timestamp asc
```

## Token Usage

The hosting SDK drops `usage` from SSE events. Extract from raw stream if needed:
```python
if event_type == "response.completed":
    usage = payload.get("response", {}).get("usage", {})
```

## SSE Stream Health

- 15s keepalive interval
- `[DONE]` = clean completion; absent = interrupted
- Stream silently closes after ~200-300s of continuous LLM output generation
