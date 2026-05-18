---
description: Verify a Foundry agent deployed via `azd up` is working — invoke endpoint, check tool & guardrail spans, run per-capability post-deploy gates from agent-capabilities.yaml
input:
  - agent_name: "Agent name as deployed (matches `agent.yaml` name field)"
  - test_query: "A simple test message to send to the agent"
  - agent_path: "Path to the agent folder (optional — enables per-capability verification)"
mcp:
  - azure
  - foundry
---

# Verify Agent: ${input:agent_name}

Post-`azd up` smoke test. Use **foundry-observability** and **foundry-failure-modes**. Reads / writes durable per-agent state via [agent_status.py](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/agent_status.py) (schema: [agent-status-schema.md](../../apm_modules/_local/foundry-agent-skillpack/.apm/skills/foundry-deploy/agent-status-schema.md)).

## Step −1 — Drift check

If `${input:agent_path}` is provided, fail-fast on capability drift since the last `/configure-rbac`:

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py drift \
  --agent-path ${input:agent_path}
```

Exit code:
- `0` — no drift (or no baseline yet, e.g. first run). Continue.
- `1` — **DRIFT DETECTED**. Print the drift summary to the user. Ask: "Re-run `/prepare-deploy` and `/configure-rbac` first, or proceed knowing the verify result may not match declared state? [r/p]". Default `r`.
- `2` — capabilities or status file missing. Print why. Continue (best-effort smoke test).

## Step 0 — Discover endpoint

Prefer:
```bash
azd ai agent show
```

Capture: `project_endpoint`, `instance_identity.principal_id`, `blueprint.principal_id`. If `azd` is not initialized in the cwd, fall back to `azure foundryextensions` MCP discovery.

```bash
EP=<project_endpoint>
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
```

**Stamp `deploy` block** so future runs / `/troubleshoot` know the running version:

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section deploy \
  --json '{"version":"<vN>","image_tag":"<tag>","endpoint":"<EP>","deployed_at":"<now>"}'
```

## Step 1 — Invoke

### Hosted (container) agent
```bash
curl -X POST "$EP/agents/${input:agent_name}/endpoint/protocols/openai/responses?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Foundry-Features: HostedAgents=V1Preview" \
  -d '{
    "input": [{"role":"user","content":[{"type":"input_text","text":"${input:test_query}"}]}],
    "stream": false, "store": false
  }'
```

Or: `azd ai agent invoke "${input:test_query}"`

### Prompt agent
Same endpoint shape; the `model` field comes from the agent definition, not the request.

## Step 2 — Interpret response

| Response | Verdict | Next |
|---|---|---|
| `status: completed`, non-empty `output` | ✅ Model + agent wired | Step 3 |
| `403` | ❌ RBAC | Run `/configure-rbac`, wait 5–15 min for propagation, retry |
| `status: failed` ImageError | ❌ ACR pull | Project MI lacks `Container Registry Repository Reader` on ACR; `/configure-rbac` |
| `status: completed` empty output | ⚠️ Sub-agent / model mismatch | foundry-failure-modes lookup |
| `invalid_payload` re: tool URL | ❌ MCP `${VAR}` not expanded at deploy | Re-deploy with the env var set on the agent version |

## Step 3 — Tool spans (App Insights / KQL)

```kql
dependencies
| where cloud_RoleName == "${input:agent_name}"
| where name startswith "execute_tool"
| project timestamp, name, customDimensions
| order by timestamp desc | take 5
```

- Spans + `gen_ai.tool.call.arguments` populated → ✅ tools instrumented
- No spans → check `ENABLE_INSTRUMENTATION=true` on the agent version
- Spans but no args → check `ENABLE_SENSITIVE_DATA=true`

## Step 4 — Guardrail spans (hosted only, if guardrails skill applied)

```kql
dependencies
| where cloud_RoleName == "${input:agent_name}"
| where name startswith "guardrail."
| take 5
```

If guardrails were not configured, skip this step.

## Step 5 — Report

```
Agent:        ${input:agent_name}
Kind:         <hosted|prompt>
Endpoint:     ✅
Model:        ✅/❌
Tools:        ✅/❌  (N execute_tool spans in last 5 min)
Guardrails:   ✅/❌  (or N/A)
Traces:       ✅/❌
```

For each ❌, link the matching entry in **foundry-failure-modes** and the one-line fix.

## Step 6 — Per-capability post-deploy verification

Load `${input:agent_path}/agent-capabilities.yaml` if `agent_path` is provided (else skip this step — base smoke test only). For each declared block, run the **Verify (Phase C)** section of the matching skill:

| Manifest block | Verify section |
|---|---|
| `toolbox` | KQL: at least one `execute_tool` span per `server_label` in last 10 min |
| `fabric` | **foundry-fabric** § "Verify (Phase C)" — successes vs 403s on Fabric tool calls |
| `workiq_teams` | **foundry-teams-workiq** § "Verification — Post-deploy gate" — Graph beta inventory + Teams app status |
| `guardrails` | **foundry-guardrails** § "Verify (Phase C)" — spans + known-blocked sample |
| `purview` | **foundry-purview** § "Verify (Phase C)" — audit query (allow up to 30 min lag) |

Append to the report:
```
Capability verification:
  toolbox      ✅ (microsoft_learn: 4 spans, all 200)
  knowledge    ✅ (hr-policies: knowledge_base_retrieve span, citation present; kb-direct: 2 search spans)
  fabric       ⚠  (1 span, 0 successes; check workspace role)
  guardrails   ✅ (5 guardrail.middleware spans, blocked sample refused)
  purview      ⏳ (no audit yet — retry in 25 min)
  workiq_teams ❌  (not in Agent 365 inventory — complete M365 admin registration)
```

## Step 7 — Stamp `verify` block

Write the per-capability outcomes + overall verdict so the next `/audit-drift` / `/troubleshoot` invocation has a baseline:

```bash
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path ${input:agent_path} \
  --section verify \
  --json '{
    "last_run_at":"<now>",
    "last_run_status":"<pass|partial|fail>",
    "endpoint_reachable":true,
    "model_responding":true,
    "tool_spans_present":<bool>,
    "guardrail_spans_present":<bool>,
    "smoke_query_response_id":"<resp_id>",
    "capability_results":{
      "toolbox":{"verdict":"pass","detail":"..."},
      "guardrails":{"verdict":"pass","detail":"..."}
    }
  }'
```
