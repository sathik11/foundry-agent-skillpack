# langgraph-chat-sample

> Clean, deploys-cleanly LangGraph BYO hosted agent. Companion to `learn-agent`
> (which is deliberately flawed to exercise gate failures).

## What this fixture proves

End-to-end success path for a LangGraph BYO hosted agent:

1. **`/prepare-deploy`** — every gate passes (no flaws to surface).
2. **`azd up`** — image builds, agent version reaches `active`.
3. **`/configure-rbac`** — Phase 1 + Phase 2 grants apply; no Phase 3 grants needed (no external resources declared).
4. **`/verify-agent`** — endpoint returns content, OTel spans flow, no drift.
5. **`/setup-evals`** — continuous eval rule created with `relevance` + `task_adherence` + `indirect_attack`.

Use this when you want to **validate the package itself** against a real Foundry project, or as the starting template for any new clean LangGraph agent.

## What's intentionally missing

- No knowledge sources (no `knowledge.sources[]` block) — keeps the smoke test fast and avoids tenant-specific dependencies.
- No `guardrails` block — Layer 1 (middleware) is documented in `foundry-guardrails`; add it if you fork this fixture.
- No `redteam` block — cloud red-team is region-locked; add it only if your project is in a supported region.

To extend, see [foundry-deploy/capabilities-manifest.md](../../../../../foundry-agent-skillpack/.apm/skills/foundry-deploy/capabilities-manifest.md) for the full schema.

## How to run

Copy this folder into your test workspace, then from your workspace root:

```bash
cp -r .agents/skills/foundry-agent-playbook/samples/langgraph-chat-sample agents/langgraph-chat-sample

/prepare-deploy agent_path=agents/langgraph-chat-sample
azd up
/configure-rbac agent_path=agents/langgraph-chat-sample agent_name=langgraph-chat-sample
/verify-agent agent_name=langgraph-chat-sample test_query="What time is it?" agent_path=agents/langgraph-chat-sample
/setup-evals agent_name=langgraph-chat-sample agent_path=agents/langgraph-chat-sample
```

## Expected output

After `/verify-agent`:

```
Agent:        langgraph-chat-sample
Kind:         Hosted (container)
Endpoint:     ✅
Model:        ✅
Tools:        ✅  (1 execute_tool span: get_current_time)
Guardrails:   N/A (no guardrails capability declared)
Traces:       ✅
```

After `/setup-evals` (dry-run):

```
Plan:
  rule_name:        continuous-eval-langgraph-chat-sample
  sample_rate:      1.0
  evaluators:       relevance, task_adherence, indirect_attack
  judge_model:      gpt-4.1-mini
```

## Local dev (no Foundry)

```bash
export FOUNDRY_PROJECT_ENDPOINT="https://<acct>.services.ai.azure.com/api/projects/<proj>"
export AZURE_AI_MODEL_DEPLOYMENT_NAME="gpt-4.1-mini"
az login
pip install -r requirements.txt
python main.py
# curl -N -X POST http://localhost:8088/responses -H "Content-Type: application/json" \
#      -d '{"input": "What is 42 * 17?", "stream": true}'
```

## Cleanup

```bash
azd down --purge
```

## Validity

Pinned versions valid as of 2026-05-14. Bump after re-validating against [foundry-samples bring-your-own/responses/langgraph-chat](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/bring-your-own/responses/langgraph-chat).
