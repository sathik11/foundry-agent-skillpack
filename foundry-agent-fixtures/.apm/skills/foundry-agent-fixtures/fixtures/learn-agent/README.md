# learn-agent

> **Test fixture.** This agent is intentionally flawed so it can exercise the
> `/prepare-deploy` slash command. See [../../TESTING.md](../../TESTING.md) for
> the list of seeded flaws and the expected gates that catch them. Do not "fix"
> them in this repo — they're the test surface.

A minimal Foundry **hosted agent** built end-to-end via the
`foundry-agent-skillpack` APM toolkit. Its only tool is the public
[Microsoft Learn MCP server](https://learn.microsoft.com/api/mcp).

## What it is
- Pattern 1a (hosted + custom tools) with an external MCP attached via
  `FoundryChatClient.get_mcp_tool(...)`.
- One file (`main.py`), one tool, no business logic of its own.

## Layout
```
learn-agent/
├── main.py          # Agent + FoundryChatClient + ResponsesHostServer
├── requirements.txt # agent-framework, hosting alpha, azure-identity
├── Dockerfile       # python:3.12-slim, EXPOSE 8088
└── agent.yaml       # Informational (REST API is source of truth)
```

## Local dev
```bash
export FOUNDRY_PROJECT_ENDPOINT='https://agents-3iq-ncus-2.services.ai.azure.com/api/projects/proj-agents-ncus-2'
export MODEL_DEPLOYMENT_NAME='gpt-5.4-mini-1'
export PORT=8765
python -u main.py
# POST http://127.0.0.1:8765/responses
```

## Deploy
See the toolkit's `/deploy-agent` workflow. For this sandbox the resolved targets are:
- Subscription: `ME-M365CPI22725173-sathikbasha-1`
- RG: `agents-3iq`
- Foundry project: `proj-agents-ncus-2` (account `agents-3iq-ncus-2`)
- ACR: `agentscontainerregistry`
- Model: `gpt-5.4-mini-1`
