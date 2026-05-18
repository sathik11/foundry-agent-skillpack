---
description: Plan a Foundry agent end-to-end — fork between scaffolding new code or wrapping an existing codebase, then pick the right pattern
input:
  - agent_name: "Name for the agent (kebab-case, e.g. learn-agent)"
  - description: "One-line description of what this agent does and which tools/data it needs"
---

# Plan Agent: ${input:agent_name}

You are a Foundry Agent Engineer. Use the **foundry-patterns** skill.

## Step 0 — Fork: existing code or scaffold new?

Ask the user **once**:

> Do you have existing Python code (FastAPI/Flask/agent_framework/LangChain/etc.) to deploy as a Foundry hosted agent, or should I scaffold a new agent from scratch?

- **Existing code** → go to Track A (wrap).
- **New / scaffold** → go to Track B (scaffold).
- **Prompt agent** (no code, Foundry-managed) → go to Track C (definition-only).

## Track A — Wrap existing code

1. Inspect the user's repo. Identify entrypoint, framework, port, auth model.
2. Confirm with the user. Then minimally adapt:
   - Replace HTTP server with `ResponsesHostServer(agent).run()` if not already on `agent-framework`. Otherwise wrap their existing handler as a tool inside an `Agent`.
   - Ensure `EXPOSE 8088` (or document the override) and `default_options={"store": False}`.
   - Pin `agent-framework>=1.2.2` and `agent-framework-foundry-hosting==1.0.0a260429` in `requirements.txt` / `pyproject.toml`.
   - Replace any hard-coded credentials with `DefaultAzureCredential()` and read `FOUNDRY_PROJECT_ENDPOINT`/`MODEL_DEPLOYMENT_NAME` from env (auto-injected by Foundry).
3. Skip directly to `/prepare-deploy`.

## Track B — Scaffold new hosted agent

1. **Pick the pattern** from "${input:description}" using **foundry-patterns**:
   - Custom Python logic only → Pattern 1a (Custom Tools)
   - Deterministic logic that can short-circuit the LLM → Pattern 1c (Middleware)
   - All data via Foundry Toolbox MCP → Pattern 1b/1g
   - External MCP server (Microsoft Learn, GitHub, custom) → Pattern 1a + `client.get_mcp_tool(...)` (see **foundry-deploy** [external-mcp.md](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-deploy/external-mcp.md))
   Confirm with the user before generating files.
2. **Copy templates** from `foundry-deploy/templates/` and substitute placeholders:
   ```bash
   AGENT=agents/${input:agent_name}
   mkdir -p "$AGENT"
   cp .agents/skills/foundry-deploy/templates/agent.yaml.template       "$AGENT/agent.yaml"
   cp .agents/skills/foundry-deploy/templates/Dockerfile.template       "$AGENT/Dockerfile"
   cp .agents/skills/foundry-deploy/templates/main.py.template          "$AGENT/main.py"
   cp .agents/skills/foundry-deploy/templates/requirements.txt.template "$AGENT/requirements.txt"
   ```
   Then substitute `${AGENT_NAME}`, `${MODEL_DEPLOYMENT_NAME}`, `${INSTRUCTIONS}`, `${AGENT_DESCRIPTION}`, `${ACR_NAME}` in each file.
3. **Add `tools.py`** — one `@tool` stub per capability identified in the description.
4. **Write INSTRUCTIONS** based on "${input:description}": role, tool-use rules, output format.
5. If guardrails declared (Step 4): also `cp .agents/skills/foundry-guardrails/scripts/guardrails.py "$AGENT/guardrails.py"` and uncomment the middleware lines in `main.py`.

## Track C — Prompt agent (no container)

1. Create `agents/${input:agent_name}/agent-definition.yaml` with `kind: prompt`, model, tools (built-in `web_search_preview`/`code_interpreter`/`file_search`/`memory_search`, or `type: mcp` connections).
2. No Dockerfile, no ACR build. The `azd ai agent` extension still owns the deploy.

## Step 4 — Capability interview (ALL tracks)

Ask the user, one at a time, which capabilities this agent needs. Skip any the user says "no" to. Schema: `foundry-deploy/capabilities-manifest.md`.

1. **External MCP servers / Foundry Toolbox?** → collect `mcp_servers[]` (server_label, url or project_connection_id, require_approval).
2. **Microsoft Fabric workspace?** → collect `workspace_id`, items, role, access_path.
3. **Microsoft Teams + Agent 365?** → collect `bot_app_id`, `teams_mcp_connection_id`. (Use **foundry-teams-workiq** skill for the questionnaire.)
4. **Guardrails?** → default to `layers: [middleware]` for Track A/B; default to `layers: [content_safety]` for Track C (no middleware available for prompt agents).
5. **Purview / DLP?** → ask only `audit_required` and `dlp.enabled`. If user says yes to DLP, print the preview-limitation callout from **foundry-purview** Phase A and require explicit acknowledgement.
6. **Eval role?** → orchestrator | ingestion | enrichment | narrative | prompt.

Write the answers to `agents/${input:agent_name}/agent-capabilities.yaml`. Set `agent_kind` to match the track (`hosted` for A/B, `prompt` for C). Omit blocks the user said no to — omission is the default, do not write `enabled: false`.

## Step 5 — Wire only declared capabilities

Generate code/config ONLY for declared capabilities. Examples:
- If `toolbox.mcp_servers` is set in Track A/B → emit `client.get_mcp_tool(...)` per server in `main.py`.
- If `guardrails.layers` includes `middleware` → vendor `guardrails.py` and wire `GuardrailAgentMiddleware`.
- If `fabric.access_path: direct_delta` → add `deltalake` to `requirements.txt` and a `read_delta(...)` helper.
- If Track C with `toolbox.mcp_servers[]` → emit each as a `tools[]` entry in `agent-definition.yaml`.

Do NOT scaffold code for capabilities the user did not declare — the manifest is the contract.

## Next steps (printed at end)

- All tracks: "Run `/prepare-deploy agent_path=agents/${input:agent_name}` — it will read `agent-capabilities.yaml`, run per-capability preflight, and (with your confirmation) execute `azd up`."
- After deploy: "Run `/configure-rbac agent_path=agents/${input:agent_name}` — capability-aware grants will be applied for declared Fabric/Content Safety/etc."
- Then: "`/verify-agent agent_name=${input:agent_name}` runs per-capability smoke tests."

> APM scaffolds and validates. `azd up` deploys. The `azd ai agent` extension builds the image, creates the agent, and assigns the Entra Agent ID.
