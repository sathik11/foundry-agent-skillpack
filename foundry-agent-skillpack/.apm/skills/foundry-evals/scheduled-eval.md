# Scheduled Evaluation (preview)

Periodic evaluation against a fixed benchmark dataset. Use to detect regression between agent versions.

> Status: public preview. SDK surface stable enough to wrap, but expect minor parameter renames before GA.

## When to use this vs continuous eval

| Question | Use |
|---|---|
| "Are we regressing on a held-out test set?" | **Scheduled** |
| "What does live traffic look like right now?" | **Continuous** |
| "Did last night's deploy break a known case?" | **Scheduled** (after every deploy) |
| "Are users hitting jailbreaks in production?" | **Continuous** + alerts |

Both can coexist. Scheduled gives you *known answers vs current agent*; continuous gives you *current agent vs evolving traffic*.

## Declaration

```yaml
evals:
  scheduled:
    enabled: true
    cron: "0 2 * * *"            # daily 02:00 UTC — or RFC-5545 RRULE if your team prefers
    timezone: UTC
    dataset:
      kind: jsonl                # jsonl | dataset_id (registered Foundry dataset)
      path: ./eval/regression-set.jsonl   # relative to agent_path
      # OR:
      # dataset_id: my-regression-v3
    target:
      type: azure_ai_agent       # agent_name + version come from azd context
      version: latest            # or pin to a specific version
    evaluators:
      - id: task_adherence
      - id: groundedness
      - id: tool_call_accuracy   # only if toolbox / fabric capabilities declared
    pass_threshold:              # optional — used by /verify-agent to gate publishes
      task_adherence: 4.0
      groundedness: 4.0
```

## SDK shape (`ProjectsSchedule` + `EvaluationScheduleTask` + `RecurrenceTrigger`)

```python
from azure.ai.projects.models import (
    ProjectsSchedule, RecurrenceTrigger, EvaluationScheduleTask, AzureAIAgentTarget,
)

trigger = RecurrenceTrigger(
    frequency="day", interval=1, schedule={"hours": [2], "minutes": [0]},
    time_zone="UTC",
)

task = EvaluationScheduleTask(
    target=AzureAIAgentTarget(name=AGENT_NAME, version="latest"),
    eval_id=EVAL_OBJECT_ID,            # references the eval object that holds the dataset + evaluators
)

schedule = ProjectsSchedule(
    name=f"scheduled-eval-{AGENT_NAME}",
    trigger=trigger,
    task=task,
    enabled=True,
)
client.schedules.create_or_update(name=schedule.name, schedule=schedule)
```

## Dataset handling

Two paths:

1. **JSONL in repo** (`dataset.kind: jsonl`) — wrapper uploads as a Foundry dataset on each run, versioned by file hash. Good for small (<1MB) regression sets that should be PR-reviewed.
2. **Foundry dataset id** (`dataset.kind: dataset_id`) — references an already-registered dataset. Good for large sets curated outside this repo (e.g., from production traces via `mcp_foundry_mcp_evaluation_dataset_create`).

## Result interpretation

- `pass_threshold` is enforced by [`/verify-agent`](../../prompts/verify-agent.prompt.md) when publishing a new version. Below threshold = block.
- A run that errors (not below threshold) is logged but does not block — eval infrastructure failures shouldn't gate deploy.
- `report_url` opens the same UI as continuous eval; per-row breakdown.
