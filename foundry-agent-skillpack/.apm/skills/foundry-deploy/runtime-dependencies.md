# Runtime Dependencies — Caller vs Container

Two distinct dependency surfaces. Mixing them is the most common brownfield onboarding mistake.

> Validity: 2026-05-14. Pinned versions track the foundry-samples reference + the skillpack's own convergent lifecycle scripts. The daily docs-scan workflow (planned, TD-9 sibling) flags upstream bumps.

## Caller-side dependencies

What runs on **your laptop** (or in CI) when the skillpack invokes convergent lifecycle scripts. Install once per developer machine / CI runner.

```bash
# Foundry control-plane SDK — used by /setup-evals wrappers and /audit-drift
pip install "azure-ai-projects>=2.0.0,<3"

# IF you use the source-code (zip) deploy path (preview), bump the floor:
# project.beta.agents.create_version_from_code / download_code require >=2.2.0
# and a client built with allow_preview=True. See foundry-deploy/code-deploy.md.
# pip install "azure-ai-projects>=2.2.0,<3"

# Identity (avoid 1.26.0bX betas)
pip install "azure-identity>=1.19.0,<1.26.0a0"

# YAML loader (used by every skillpack wrapper that reads agent-capabilities.yaml)
pip install pyyaml

# HTTP client for Purview-DLP-runtime-style preflight (only if you'll use it)
pip install httpx
```

These are NOT shipped in the agent's container.

## Container-side dependencies

What ships **inside the Docker image** that Foundry runs. Lives in `agents/<name>/requirements.txt`. The two starter templates already include the right base; the table below tells you what to add per declared capability.

### Base set (always present)

The two templates already include their base set:

| Template | Base packages |
|---|---|
| agent-framework | `agent-framework>=1.2.2`, `agent-framework-foundry-hosting==1.0.0a260429`, `azure-identity<1.26.0a0` |
| LangGraph BYO | `azure-ai-agentserver-responses==1.0.0b5`, `azure-ai-agentserver-core==2.0.0b3`, `azure-identity>=1.19.0,<1.26.0a0`, `langgraph==1.1.8`, `langgraph-prebuilt==1.0.10`, `langchain-core==1.3.0`, `langchain-azure-ai[opentelemetry]>=1.2.3` |

### Add per declared capability

Look at your `agent-capabilities.yaml`. For each block declared, append the matching packages to your `requirements.txt`:

| Capability declaration | Add to `requirements.txt` | Notes |
|---|---|---|
| `guardrails.layers` includes `middleware` (Layer 1) | (none — uses `agent-framework` already in base) | The vendored `guardrails.py` imports `AgentMiddleware` from `agent-framework`. |
| `guardrails.layers` includes `content_safety` (Layer 2) | `azure-ai-contentsafety>=1.0.0` | Layer 1 middleware calls it lazily; install only if you set `AZURE_CONTENT_SAFETY_ENDPOINT`. |
| `guardrails.layers` includes `purview_dlp` (Layer 1.5) | `httpx>=0.27`, `opentelemetry-api>=1.27` | The vendored `purview_dlp_middleware.py` calls Purview API via httpx; OTel for spans. |
| **Telemetry (always recommended)** | `azure-monitor-opentelemetry>=1.7` | Auto-injects + auto-instruments. Foundry runtime sets `APPLICATIONINSIGHTS_CONNECTION_STRING`; the package picks it up. NOT auto-included by `agent-framework` today. |
| `knowledge.sources[].kind == ai_search_direct` (direct SDK calls in your code) | `azure-search-documents>=11.5` | Only if you instantiate `SearchClient` yourself; if you use the Foundry `ai_search` tool, no client lib needed. |
| `knowledge.sources[].kind == foundry_iq` | (none — uses MCP tool; no client lib in container) | |
| `knowledge.sources[].kind in {file_search_basic, file_search_standard}` | (none) | Built-in tool; no extra dep. |
| `knowledge.sources[].kind == blob_via_indexer` | (none in container) | The indexer runs server-side. Add `azure-storage-blob` only if your tool functions list/read blobs directly. |
| `knowledge.sources[].kind == fabric_direct_delta` | `deltalake>=0.18` | Direct Delta read from OneLake. |
| `persistence.store == cosmos` (planned, TD-14) | `azure-cosmos>=4.7` | (not yet implemented) |
| `persistence.store == redis` (planned, TD-14) | `redis>=5.0` | (not yet implemented) |

### Reserved env vars (the runtime auto-injects; do NOT re-pin packages for these)

The Foundry hosted runtime auto-injects these — your container code reads from `os.environ`:

| Env var | Auto-injected | Used by |
|---|---|---|
| `FOUNDRY_PROJECT_ENDPOINT` | Yes | `FoundryChatClient`, MCP tool connections |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Yes | `azure-monitor-opentelemetry` |
| `AGENT_SESSION_ID` (per-request) | Yes | Session-state helpers |
| `MODEL_DEPLOYMENT_NAME` | Set via `agent.yaml environment_variables` | Your agent code |

Never declare reserved-prefix vars (`FOUNDRY_*`, `AGENT_*`, `APPLICATIONINSIGHTS_*`) in `agent.yaml environment_variables` — the platform rejects them.

## Common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleNotFoundError: azure_ai_projects` when running `/setup-evals` | Treated caller-side dep as container-side | Install on the *caller* (laptop / CI runner), not in the agent image |
| Agent runs but no spans in App Insights | Missing `azure-monitor-opentelemetry` in container `requirements.txt` | Add it; redeploy |
| `purview_dlp_middleware` import fails in container | Missing `httpx` in container `requirements.txt` | Add `httpx>=0.27` to the agent's requirements; rebuild |
| `SearchClient` not found | Code uses direct SDK but `azure-search-documents` not in container | Add it; OR refactor to use the Foundry `ai_search` tool (no SDK in container) |
| Image bloats to >2GB | Installed all optional deps "just in case" | Install only what `agent-capabilities.yaml` declares; lean image = faster cold start |

## How to update your existing `requirements.txt`

The skillpack does **NOT** auto-mutate `requirements.txt` — that's user code. The recommended pattern:

1. Read `agent-capabilities.yaml`.
2. Cross-reference the table above.
3. Append the matching lines manually.
4. Run `/prepare-deploy` — its Track H3 gate validates the resulting `requirements.txt`.

Or use the planned `inject-requirements.sh` helper (TD-16) which prints the lines to append, never mutates.

## Cross-skill references

- Layer 1 middleware deps → [foundry-guardrails/middleware.md](../foundry-guardrails/middleware.md)
- Layer 1.5 Purview DLP deps → [foundry-guardrails/purview-dlp.md](../foundry-guardrails/purview-dlp.md)
- Layer 2 Content Safety deps → [foundry-guardrails/content-safety.md](../foundry-guardrails/content-safety.md)
- Caller-side SDK pins for `/setup-evals` → [foundry-evals/SKILL.md](../foundry-evals/SKILL.md)
- Caller-side SDK pins for `/audit-drift` → reads `azure-ai-projects` directly; same pin
- Template starting points → [scaffold.md](scaffold.md)
