# LangGraph BYO Hosted-Agent Template

A multi-turn chat agent built with **LangGraph + Azure OpenAI**, hosted on Foundry via the **Responses protocol** through the `azure-ai-agentserver-responses` adapter.

> Source-of-truth sample: [bring-your-own/responses/langgraph-chat](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/bring-your-own/responses/langgraph-chat). This template tracks that sample as of 2026-05-14.

## What this template gives you

- **Server-side conversation state** — no in-memory session store. Foundry threads turns via `previous_response_id` / `conversation`; the handler fetches history through `context.get_history()` and replays it into LangGraph each turn.
- **Streaming responses** over the Responses protocol.
- **Auto-instrumentation** of LangGraph nodes, LLM calls, and tool calls via `langchain-azure-ai[opentelemetry]` — spans flow to App Insights when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set (auto-injected in hosted Foundry).
- **Reference tools** (`get_current_time`, `calculator`) that you replace with your own.

## When to pick this template

✅ You already have LangGraph code or want LangGraph's graph-based control flow.
✅ Conversational chatbot — you want the platform to manage conversation history.
✅ Tool-calling pattern (model picks tools, ToolNode executes, route back).

❌ You're starting fresh with no LangGraph investment → use the agent-framework template (tighter Foundry integration, native session/tool wiring, full feature set).
❌ You need raw HTTP control or non-OpenAI payloads → use Invocations protocol (different adapter; same wrapping idea).
❌ You need to publish to Teams / M365 → cross-link via the Responses + Activity bridge — agent-framework path is smoother today.

## File layout

```
agents/<name>/
├── main.py                    ← handler + LangGraph definition
├── agent.yaml                 ← ContainerAgent schema (used by /prepare-deploy)
├── agent.manifest.yaml        ← used by `azd ai agent init -m`
├── Dockerfile                 ← linux/amd64, EXPOSE 8088, python main.py
├── requirements.txt           ← pinned versions (see below)
└── agent-capabilities.yaml    ← OPTIONAL — declare knowledge / guardrails / evals / network
```

## Substitution placeholders

`/plan-agent` Track B (or hand-substitution) replaces:

| Placeholder | Example |
|---|---|
| `${AGENT_NAME}` | `feedback-harvester` |
| `${AGENT_DESCRIPTION}` | "Multi-turn chat agent that…" |
| `${MODEL_ID}` | `gpt-4.1-mini` |
| `${AZURE_AI_MODEL_DEPLOYMENT_NAME}` | `gpt-4.1-mini` (deployment name in your Foundry project) |

## Local development

```bash
# 1. Set the platform-injected vars manually
export FOUNDRY_PROJECT_ENDPOINT="https://<acct>.services.ai.azure.com/api/projects/<proj>"
export AZURE_AI_MODEL_DEPLOYMENT_NAME="gpt-4.1-mini"
export APPLICATIONINSIGHTS_CONNECTION_STRING="<your-conn-str>"   # optional, for tracing locally

# 2. Authenticate
az login

# 3. Install + run
pip install -r requirements.txt
python main.py

# 4. POST a turn
curl -N -X POST http://localhost:8088/responses \
    -H "Content-Type: application/json" \
    -d '{"model": "chat", "input": "What time is it right now?", "stream": true}'

# 5. Continue the conversation by chaining previous_response_id
curl -N -X POST http://localhost:8088/responses \
    -H "Content-Type: application/json" \
    -d '{"model": "chat", "input": "What is 42 * 17?", "previous_response_id": "<ID>", "stream": true}'
```

## Deploy

Use the standard package flow — same as the agent-framework template:

```bash
/prepare-deploy agent_path=agents/<name>
azd up
/configure-rbac agent_path=agents/<name> agent_name=<name>
/verify-agent agent_name=<name> test_query="hello" agent_path=agents/<name>
/setup-evals agent_name=<name> agent_path=agents/<name>
```

The package's gates work the same against this template as against the agent-framework one — `agent.yaml` shape is identical, environment-variable rules are identical, identity model is identical.

## Image-build gotcha (Apple Silicon)

If you build locally on an ARM64 host (M1/M2/M3 Mac), force x86:

```bash
docker build --platform=linux/amd64 -t <name>:v1 .
```

Or use ACR remote build (default with `azd up`) and ignore this entirely.

## Why this template uses `langchain-azure-ai`, not `openai` directly

- `AzureAIOpenAIApiChatModel` accepts `project_endpoint` directly — same auth path as agent-framework.
- The `[opentelemetry]` extra auto-wires LangChain spans to App Insights — you get the same dashboards as agent-framework agents without any extra wiring.
- LangGraph's `bind_tools()` works with this client.

If you switch to `langchain-openai` or `openai`, you lose the auto-OTel and need to wire `azure-monitor-opentelemetry` manually + ensure node/tool spans propagate.

## Where this template stops

Replace these with your domain logic:

- `TOOLS` list — swap `get_current_time` / `calculator` for the actual tools your agent uses. Each tool is a LangChain `@tool` with a docstring the model reads.
- `_build_graph()` — extend with domain nodes, conditional edges, subgraphs.
- `instructions` (system prompt) — pass via `SystemMessage` at the start of `lc_messages` if you want a persistent persona.

The conversation-state wiring (`get_history` + `_history_to_langchain_messages`) and streaming handler are platform-correct as written; you usually don't need to touch them.

## Capability manifest

Drop an `agent-capabilities.yaml` next to `agent.yaml` if this agent uses:
- Knowledge sources (Foundry IQ, AI Search, file-search, blob-via-search) — see [foundry-knowledge](../../../foundry-knowledge/SKILL.md)
- Guardrails (Content Safety + middleware) — see [foundry-guardrails](../../../foundry-guardrails/SKILL.md)
- Continuous / scheduled / red-team evals — see [foundry-evals](../../../foundry-evals/SKILL.md)
- Non-public network class — see [foundry-prod-readiness/networking.md](../../../foundry-prod-readiness/networking.md)

Schema: [capabilities-manifest.md](../../capabilities-manifest.md).

## Cross-skill references

- Decide between this template and agent-framework → [scaffold.md](../../scaffold.md)
- Sessions vs conversations vs threads → [Microsoft Learn: Manage hosted agent sessions](https://learn.microsoft.com/azure/foundry/agents/how-to/manage-hosted-sessions)
- External MCP / APIM front-door → [external-mcp.md](../../external-mcp.md), [apim-as-mcp-frontdoor.md](../../apim-as-mcp-frontdoor.md)
- Native file-based skills inside the agent → [foundry-skills](../../../foundry-skills/SKILL.md)
- LangChain instrumentation reference → `langchain-azure-ai[opentelemetry]` upstream docs
