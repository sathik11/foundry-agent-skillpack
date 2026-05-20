---
description: Plan a Foundry agent end-to-end — fork between scaffolding new code or wrapping an existing codebase, then pick the right pattern
input:
  - agent_name: "Name for the agent (kebab-case, e.g. learn-agent)"
  - description: "One-line description of what this agent does and which tools/data it needs"
  - operator_mode: "true|false — when true (default), downstream grant scripts attempt the action first and only emit runbooks on 403. Set 'false' for SOC-monitored environments where unauthorized attempts trigger alerts. Stamped into agent-capabilities.yaml so /prepare-deploy, /configure-rbac, /setup-purview, and /publish-teams all honor it. (optional, default 'true')"
---

# Plan Agent: ${input:agent_name}

You are a Foundry Agent Engineer. Use the **foundry-patterns** skill.

> **Anti-synthesis guard.** For Steps 0a and 0b you MUST gather facts via the listed MCP tools. Do NOT shell out (`az`, `curl`, `python -c`), and do NOT echo example values from other skills, recipes, or fixture READMEs. Treat every value the user has not explicitly confirmed as unknown.

## Step 0a — Target discovery + caller-role preflight

Before touching any files, discover the deployment target and confirm the caller has the rights to plan.

1. **Subscription.** If the user did not pass `subscription=`, list subscriptions with `mcp_azure_mcp_subscription_list` and show a numbered picklist. **Wait for the user's selection.** Never auto-pick.
2. **Resource group.** Run `mcp_azure_mcp_group_list subscription=<sub>` and show a numbered picklist scoped to the chosen subscription. **Wait for selection.** If the user types a name that is not in the list, do NOT silently create it — ask for confirmation.
3. **Discover all target resources in one call.** Run:
   ```bash
   .agents/skills/foundry-deploy/scripts/discover-target.sh <subscription_id> <resource_group>
   ```
   This discovers the Foundry account, project, ACR, and model deployments — all as KEY=VALUE pairs. If `DISCOVERY_STATUS=partial`, show the user what's missing and ask how to proceed. If multiple accounts/projects exist, the script lists all and picks the first — confirm with the user.
4. **Batch role check.** Run:
   ```bash
   .agents/skills/foundry-roles/scripts/preflight-roles.sh plan-agent <subscription_id> <resource_group> <foundry_account> <project>
   ```
   If it exits non-zero, print the emitted runbook(s) and STOP. The `PREFLIGHT_MISSING` key tells you exactly which roles are missing.
5. **Stamp the manifest.** Create `agents/${input:agent_name}/agent-capabilities.yaml` if it does not exist, then write:
   - `operator_mode: ${input:operator_mode}` — at the top of the file, before `target:`. Defaults to `true` when the input is omitted. When `true`, downstream grant scripts attempt the action first and only fall back to a runbook on 403. When `false`, scripts skip the attempt and emit a runbook directly (use for SOC-monitored environments). See [`foundry-roles/operator-mode.md`](../skills/foundry-roles/operator-mode.md) for the full pattern.
   - `target:` block from the discovered values. This file is the single source of truth for sub/RG/project across the whole lifecycle — `/prepare-deploy` reads it and only re-prompts on missing fields.

✅ **Checkpoint.** `agent-capabilities.yaml` exists with a populated `target:` block. The user has confirmed the discovered values.

## Step 0b — Model selection

Auto-select the model deployment. Run:

```bash
.agents/skills/foundry-deploy/scripts/select-model.sh <subscription_id> <resource_group> <foundry_account> [<deployment_name_hint>]
```

The script auto-selects when unambiguous:
- If a hint is given and exists → uses it.
- If only one deployment exists → uses it.
- If multiple exist → picks the first agents-capable one.
- Only when `MODEL_SELECTION_METHOD=manual-needed` do you need to ask the user to choose.

Write the resulting `model:` block to `agent-capabilities.yaml` using the `MODEL_DEPLOYMENT_NAME`, `MODEL_NAME`, and `MODEL_VERSION` output.

If no deployments exist at all, fall back to the full model-selection flow in [`foundry-deploy/model-selection.md`](../skills/foundry-deploy/model-selection.md): catalog browse → deploy-with-consent (gated by `Cognitive Services Contributor` + quota check + explicit `y/N`) → runbook.

✅ **Checkpoint.** `model.deployment_name` is populated. Templates in Track B will substitute it for `${MODEL_DEPLOYMENT_NAME}`.

## Step 0c — Fork: existing code or scaffold new?

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
   - External MCP server (Microsoft Learn, GitHub, custom) → Pattern 1a + `client.get_mcp_tool(...)` (see **foundry-deploy** [external-mcp.md](../skills/foundry-deploy/external-mcp.md))
   - Multiple agents needed (orchestrator + siblings, sequential or parallel) → Pattern 2a/2b/2c. Switch to the **foundry-multi-agent** skill for sub-agent invocation, the inter-tool data buffer (>25 records / >20KB), and SSE streaming (>120s pipelines). For an end-to-end walkthrough see [Recipe 06](../../../foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/06-multi-agent-orchestration.md).
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

Write the answers to `agents/${input:agent_name}/agent-capabilities.yaml` — **merging into the existing `target:` and `model:` blocks written by Steps 0a/0b**, never overwriting them. Set `agent_kind` to match the track (`hosted` for A/B, `prompt` for C). Omit blocks the user said no to — omission is the default, do not write `enabled: false`.

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
