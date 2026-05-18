# Scaffold: Hosted Agent

Two template families:

| Template | When | Files |
|---|---|---|
| **agent-framework** (default) | Starting fresh / using AutoGen / Semantic Kernel | [templates/](templates/) (4 files) |
| **langgraph-byo** | Already using LangGraph | [templates/langgraph-byo/](templates/langgraph-byo/) (6 files) |

## agent-framework template

```
agents/<name>-v3/
├── Dockerfile           # python:3.12-slim, EXPOSE 8088, CMD python main.py
├── agent.yaml           # Informational only (REST API is source of truth)
├── main.py              # Agent + FoundryChatClient + ResponsesHostServer
├── requirements.txt     # agent-framework>=1.2.2, agent-framework-foundry-hosting==1.0.0a260429
├── tools.py             # @tool(approval_mode="never_require") functions
├── guardrails.py        # Vendored middleware (copy per agent — see ../foundry-guardrails/scripts/guardrails.py)
└── data/                # Optional baked-in reference data
```

Templates live in [templates/](templates/):
- [agent.yaml.template](templates/agent.yaml.template)
- [Dockerfile.template](templates/Dockerfile.template)
- [main.py.template](templates/main.py.template)
- [requirements.txt.template](templates/requirements.txt.template)

`/plan-agent` Track B copies these and substitutes `${AGENT_NAME}`, `${MODEL_DEPLOYMENT_NAME}`, `${INSTRUCTIONS}`.

## langgraph-byo template

```
agents/<name>/
├── main.py                    # ResponsesAgentServerHost + LangGraph (chatbot ↔ tools)
├── agent.yaml                 # ContainerAgent schema (matches agent-framework)
├── agent.manifest.yaml        # azd ai agent init -m
├── Dockerfile                 # linux/amd64; copies repo → user_agent/
├── requirements.txt           # azure-ai-agentserver-responses + langgraph + langchain-azure-ai
└── README.md                  # When to use; placeholders; deploy flow; gotchas
```

Templates live in [templates/langgraph-byo/](templates/langgraph-byo/). Same `${AGENT_NAME}` substitution; adds `${MODEL_ID}` and `${AGENT_DESCRIPTION}`. Read the [template README](templates/langgraph-byo/README.md) for substitution + local-dev steps.

## Tool Rules

- `@tool(approval_mode="never_require")` — hosted agents run unattended
- `Annotated[T, Field(description=...)]` — Pydantic hints required
- Tools must return `str` — use `json.dumps()` for structured data
- No `backend.*` or `agents.shared.*` imports — build context is the agent folder

## Local Dev

```bash
export FOUNDRY_PROJECT_ENDPOINT='https://...'
export MODEL_DEPLOYMENT_NAME='gpt-5.4-mini-1'
export PORT=8765
python -u main.py
# POST http://127.0.0.1:8765/responses
```
