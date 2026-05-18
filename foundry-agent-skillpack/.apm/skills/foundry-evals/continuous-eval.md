# Continuous Evaluation

Sampling live agent responses with selected evaluators. Runs as long as the rule exists and the agent receives traffic.

## What you get

- A row per evaluated response in the Monitor dashboard.
- A `report_url` per eval run (linked to the originating trace in App Insights).
- Hourly throughput cap (default 100/hour, raise via `max_hourly_runs`).

## Declaration

In `agent-capabilities.yaml`:

```yaml
evals:
  continuous:
    enabled: true
    sample_rate: 0.20            # 0..1.0 — fraction of responses to evaluate
    max_hourly_runs: 100         # platform default
    judge_model: gpt-5.4-mini-1  # any deployment in the project
    evaluators:                  # explicit, OR derived from role + capabilities — see evaluator-catalog.md
      - id: relevance
      - id: task_adherence
      - id: indirect_attack
    redact_score_properties: false  # set true to suppress reasoning text in stored results
```

## SDK shape

```python
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    EvaluationRule, EvaluationRuleEventType,
    EvaluationRuleFilter, ContinuousEvaluationRuleAction,
)
from azure.identity import DefaultAzureCredential

client = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())

rule = EvaluationRule(
    name=f"continuous-eval-{AGENT_NAME}",
    event_type=EvaluationRuleEventType.RESPONSE_COMPLETED,
    filter=EvaluationRuleFilter(agent_name=AGENT_NAME),
    actions=[ContinuousEvaluationRuleAction(eval_id=EVAL_OBJECT_ID)],
    enabled=True,
)
client.evaluation_rules.create_or_update(rule_name=rule.name, rule=rule)
```

The wrapper script [scripts/ensure_continuous_eval.py](scripts/ensure_continuous_eval.py) handles:
1. Eval object create-or-fetch (so the rule has a stable `eval_id`).
2. Built-in vs custom evaluator routing.
3. Idempotent rule create-or-update by name.
4. Role preflight (`Azure AI User` on project).

## Verification

Generate traffic, then:

```python
runs = openai_client.evals.runs.list(eval_id=EVAL_OBJECT_ID, order="desc", limit=10)
for r in runs.data:
    print(r.status, r.report_url)
```

Or in the portal: agent → **Monitor** tab → eval charts populate within a few minutes after traffic.

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Rule exists but no runs | Sample rate too low + low traffic | Bump `sample_rate` or generate test traffic |
| 403 on rule create | Caller lacks `Azure AI User` on project | Run [foundry-roles/scripts/preflight-role.sh](../foundry-roles/scripts/preflight-role.sh) |
| `evaluator not found` | Custom evaluator referenced before registration | Register via Custom Evaluators API first; see [evaluator-catalog.md](evaluator-catalog.md) |
| Hourly cap hit | `max_hourly_runs` too low for traffic level | Increase, or accept the cap and trust sampling |
| Empty reasoning in results | `redact_score_properties: true` | Toggle off if you need explanations |

## Cost notes

Each evaluated response = one judge-model call. Budget per evaluator-call ≈ judge model price × prompt+response token count. With `gpt-5.4-mini` judge and 5 evaluators × 100 evals/hour, expect ~$0.50–$2/hour depending on response length. Right-size `sample_rate` accordingly.
