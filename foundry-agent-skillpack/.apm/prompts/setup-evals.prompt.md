---
description: Create continuous (and optionally scheduled / cloud red-team) evaluation rules for a deployed Foundry agent. Auto-selects evaluators from agent-capabilities.yaml when available.
input:
  - agent_name: "Agent name (e.g. my-agent-v3)"
  - agent_path: "Path to the agent folder (optional — reads agent-capabilities.yaml for auto-selection)"
  - agent_role: "Override role: orchestrator | ingestion | enrichment | narrative | prompt (optional)"
  - judge_model: "Override judge model deployment (optional)"
  - include_scheduled: "true|false — also create a scheduled-eval if manifest declares one (optional, default true)"
  - include_redteam: "true|false — also create a cloud red-team if manifest declares one and region is supported (optional, default true)"
mcp:
  - azure
  - foundry
---

# Setup Evals: ${input:agent_name}

Use **foundry-evals** for convergent lifecycle scripts and **foundry-roles** for role preflight.

## Step 0 — Role preflight

Check `Azure AI User` on the project. If missing, the wrapper emits a runbook and stops.

```bash
bash .agents/skills/foundry-roles/scripts/preflight-role.sh \
  "Azure AI User" "<project_arm_scope>" \
  --action setup-evals --persona DevOps \
  --why "Create continuous-eval rule for ${input:agent_name}"
```

## Step 1 — Read manifest (if available)

Load `${input:agent_path}/agent-capabilities.yaml`. The wrapper derives evaluators from `evals.role` + capabilities (see [evaluator-catalog.md](../skills/foundry-evals/evaluator-catalog.md)). Inputs override the manifest if both present.

## Step 2 — Create / update continuous eval

Preferred: convergent lifecycle script (creates if missing, updates if stale).

```bash
python .agents/skills/foundry-evals/scripts/ensure_continuous_eval.py \
  --project-endpoint <project_endpoint> \
  --project-scope    <project_arm_scope> \
  --agent-name       ${input:agent_name} \
  --agent-path       ${input:agent_path} \
  ${input:judge_model:+--judge-model ${input:judge_model}} \
  --dry-run
```

Review the printed plan, then re-run without `--dry-run` (or set `YES=1` for non-interactive).

Legacy fallback (MCP, retained for ad-hoc use without the SDK installed):

```
mcp_foundry_mcp_continuous_eval_create(
    projectEndpoint=<project_endpoint>,
    agentName="${input:agent_name}",
    evaluatorNames=[<final list>],
    deploymentName="<judge_model>",
    intervalHours=<evals.interval_hours from manifest, default 1>,
    maxTraces=<evals.max_traces from manifest, default 200>,
    scenario="standard"
)
```

## Step 3 — Optional: scheduled eval (preview)

If `${input:include_scheduled}` (default true) AND manifest declares `evals.scheduled.enabled: true`:

```bash
python .agents/skills/foundry-evals/scripts/ensure_scheduled_eval.py \
  --project-endpoint <project_endpoint> \
  --project-scope    <project_arm_scope> \
  --agent-name       ${input:agent_name} \
  --agent-path       ${input:agent_path} \
  --dry-run
```

## Step 4 — Optional: cloud red-team (preview, region-locked)

If `${input:include_redteam}` (default true) AND manifest declares `evals.redteam.enabled: true`:

```bash
python .agents/skills/foundry-evals/scripts/ensure_redteam.py \
  --project-endpoint <project_endpoint> \
  --project-scope    <project_arm_scope> \
  --project-region   <region>           # e.g. eastus2
  --agent-name       ${input:agent_name} \
  --agent-path       ${input:agent_path} \
  --dry-run
```

The wrapper hard-fails preflight with the supported region list if the project's region is unsupported. In that case, fall back to PyRIT-in-CI — see [foundry-guardrails/redteam-evals.md](../skills/foundry-guardrails/redteam-evals.md).

## Step 5 — Verify

- Continuous eval: portal → agent → **Monitor** tab. Charts populate within minutes after the agent receives traffic.
- Scheduled eval: portal → agent → **Evaluation** tab. First run fires per cron.
- Red-team: portal → **Evaluation** → **AI red teaming** tab.

Programmatic verification:

```python
runs = openai_client.evals.runs.list(eval_id=<EVAL_ID>, order="desc", limit=10)
for r in runs.data:
    print(r.status, r.report_url)
```

## Step 6 — Explain behavior

- First continuous-eval run fires after the next sampled response, not immediately.
- "No trace data" failures are normal if the agent had no invocations in the window.
- Quality score drops may indicate model drift; cross-reference with [foundry-observability](../skills/foundry-observability/SKILL.md) KQL.
- `indirect_attack > 0` means adversarial inputs reached the agent.
- If `purview.audit_required: true` and `pii_detection` was added: cross-reference Purview Audit hits with eval failures.
- Red-team: ASR per (risk × strategy) cell is in the run's `report_url`. Aggregate ASR > `pass_threshold.max_attack_success_rate` will block publish via `/verify-agent`.

## Step 7 — Optional: fire one-off eval

To verify immediately without waiting for the hourly schedule:

```
mcp_foundry_mcp_evaluation_agent_batch_eval_create(
    agentName="${input:agent_name}",
    inputData=[{"query": "test query 1"}, {"query": "test query 2"}],
    runName="manual-${input:agent_name}-$(date +%s)"
)
```
