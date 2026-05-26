---
name: foundry-conventions
description: Coding standards and conventions for Foundry hosted agent development
---

# Foundry Agent Coding Conventions

## Scope boundary — what this skillpack does NOT handle

Deterministic per-tool-call policy enforcement (deny / allow / require_approval at runtime) is **out of scope** for this skillpack. For that, use [Microsoft Agent Governance Toolkit (AGT)](https://github.com/microsoft/agent-governance-toolkit) inside your agent container — it wraps tool functions and raises `GovernanceDenied` on disallowed actions. This skillpack owns deploy + lifecycle orchestration; AGT owns runtime enforcement. They are complementary layers, intended to be used together. First-class declarative integration lands in v0.24 (TD-29).

## SDK

- Use `agent-framework>=1.2.2` + `agent-framework-foundry-hosting==1.0.0a260429`
- Install with `pip install --pre` (hosting is alpha)
- Entrypoint: `FoundryChatClient` + `Agent` + `ResponsesHostServer(agent).run()`
- No `asyncio`, no `from_agent_framework`

## Tools

- Every tool: `@tool(approval_mode="never_require")`
- Arguments: `Annotated[T, Field(description="...")]`
- Return type: always `str` (use `json.dumps()`)
- Docstring required (becomes tool description in traces)

## Build Context

- Each agent folder is self-contained — no imports from `backend.*` or `agents.shared.*`
- Vendor `guardrails.py` into each agent folder (identical copies, different constructor args)
- Bake reference data into `./data/` directory

## Environment Variables

- Reserved prefixes (400 if set): `FOUNDRY_*`, `AGENT_*`, `APPLICATIONINSIGHTS_*`
- Use a project-specific prefix: `MYPROJECT_*`, `ACME_*`, etc.
- Always set: `ENABLE_INSTRUMENTATION=true`, `ENABLE_SENSITIVE_DATA=true`
- Platform auto-injects: `FOUNDRY_PROJECT_ENDPOINT`, `APPLICATIONINSIGHTS_CONNECTION_STRING`

## Docker

- Base: `python:3.12-slim`
- Port: `8088`
- CMD: `python main.py`
- Tags: timestamped (`$(date +%Y%m%d%H%M)`), never `latest`

## API

- Version: `api-version=v1`
- Header: `Foundry-Features: HostedAgents=V1Preview`
- Auth scope: `https://ai.azure.com/.default`
- Versions are immutable — POST new, never PATCH
- Env vars are full-replace — deploy script must include ALL vars

## Deploy Boundary (APM ↔ azd)

This package's prompts MUST NOT run `az acr build` or POST to `/agents/{name}/versions`. Image build, agent create, version create, and Entra Agent ID assignment are owned by `azd up` + the `azd ai agent` extension. APM's job is to leave the project in an azd-ready state and run `apm audit`. `/prepare-deploy` may execute `azd up` only with explicit user confirmation.

## Bicep

Do NOT hand-author the Bicep templates under `./infra/`. The `azd ai agent` extension scaffolds them on first `azd init`/`azd up`. APM's role is limited to validating the parameters: `ENABLE_HOSTED_AGENTS=true`, `ENABLE_CAPABILITY_HOST=false` (must be false in refreshed preview), `ENABLE_MONITORING=true`.

## Error Handling

- Tools: return `json.dumps({"status": "failed", "error": "..."})` — never raise
- Sub-agent calls: retry 5x with exponential backoff (2s/4s/8s/8s)
- NL2SQL: always have a deterministic fallback path
- Payloads: truncate to 30 records max before passing to sub-agents
